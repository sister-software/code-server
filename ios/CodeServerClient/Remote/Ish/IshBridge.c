#include "IshBridge.h"
#include <string.h>
#include <stdlib.h>
#include <resolv.h>
#include <netdb.h>
#include <signal.h>
#include <unistd.h>
#include <sys/ucontext.h>

// iSH core headers (GPLv3). Header search path includes the iSH source root +
// build-ios. Ported/trimmed from app/AppDelegate.m (boot), app/Terminal.m (tty
// driver) and app/TerminalViewController.m (per-terminal pty spawn).
#include "misc.h"
#include "kernel/init.h"
#include "kernel/fs.h"
#include "kernel/calls.h"
#include "kernel/task.h"
#include "kernel/errno.h"
#include "fs/tty.h"
#include "fs/devices.h"
#include "fs/dev.h"
#include "fs/path.h"
#include "fs/stat.h"

#define ISH_S_IFCHR 0x2000

// ish-arm64 has no create_some_device_nodes() helper; the app (AppDelegate.m)
// creates the device nodes inline. Replicate the essential ones (console/tty/pts
// + null/zero/random) so programs that need them work.
static void create_device_nodes(void) {
    for (int i = 1; i <= 7; i++) {
        char p[16];
        snprintf(p, sizeof(p), "/dev/tty%d", i);
        generic_mknodat(AT_PWD, p, ISH_S_IFCHR | 0666, dev_make(TTY_CONSOLE_MAJOR, i));
    }
    generic_mknodat(AT_PWD, "/dev/tty", ISH_S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR));
    generic_mknodat(AT_PWD, "/dev/console", ISH_S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_CONSOLE_MINOR));
    generic_mknodat(AT_PWD, "/dev/ptmx", ISH_S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR));
    generic_mknodat(AT_PWD, "/dev/null", ISH_S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_NULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/zero", ISH_S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_ZERO_MINOR));
    generic_mknodat(AT_PWD, "/dev/full", ISH_S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_FULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/random", ISH_S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_RANDOM_MINOR));
    generic_mknodat(AT_PWD, "/dev/urandom", ISH_S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_URANDOM_MINOR));
    generic_mkdirat(AT_PWD, "/dev/pts", 0755);
}

extern struct tty *pty_open_fake(struct tty_driver *driver);

#define MAX_TERMS 32

static ish_output_cb g_output;
static int g_booted;
static int g_pending_id = -1;            // id assigned to the next tty created

static struct {
    int id;
    struct tty *tty;
} g_terms[MAX_TERMS];

static void term_record(int id, struct tty *tty) {
    for (int i = 0; i < MAX_TERMS; i++) {
        if (g_terms[i].tty == NULL) { g_terms[i].id = id; g_terms[i].tty = tty; return; }
    }
}
static struct tty *term_tty(int id) {
    for (int i = 0; i < MAX_TERMS; i++)
        if (g_terms[i].tty != NULL && g_terms[i].id == id) return g_terms[i].tty;
    return NULL;
}
static void term_forget(struct tty *tty) {
    for (int i = 0; i < MAX_TERMS; i++)
        if (g_terms[i].tty == tty) { g_terms[i].tty = NULL; g_terms[i].id = 0; }
}

// --- tty driver: shared by the console and every pseudo-terminal -------------

static int ish_tty_init(struct tty *tty) {
    int id = g_pending_id;
    tty->data = (void *) (intptr_t) id;
    term_record(id, tty);
    return 0;
}

static int ish_tty_write(struct tty *tty, const void *buf, size_t len, bool blocking) {
    (void) blocking;
    if (g_output) g_output((int) (intptr_t) tty->data, (const char *) buf, (int) len);
    return (int) len;
}

static void ish_tty_cleanup(struct tty *tty) {
    int id = (int) (intptr_t) tty->data;
    term_forget(tty);
    if (g_output) g_output(id, NULL, 0); // signal exit
}

static struct tty_driver_ops ish_tty_ops = {
    .init = ish_tty_init,
    .write = ish_tty_write,
    .cleanup = ish_tty_cleanup,
};
DEFINE_TTY_DRIVER(ish_console_driver, &ish_tty_ops, TTY_CONSOLE_MAJOR, 64);
static struct tty_driver ish_pty_driver = { .ops = &ish_tty_ops };

// --- DNS: copy the host's resolvers into the guest's /etc/resolv.conf --------

static void configure_dns(void) {
    struct __res_state res;
    if (res_ninit(&res) != 0) return;
    char conf[2048];
    size_t n = 0;
    union res_sockaddr_union servers[NI_MAXSERV];
    int found = res_getservers(&res, servers, NI_MAXSERV);
    char addr[NI_MAXHOST];
    for (int i = 0; i < found && n < sizeof(conf); i++) {
        if (servers[i].sin.sin_len == 0) continue;
        if (getnameinfo((struct sockaddr *) &servers[i].sin, servers[i].sin.sin_len,
                        addr, sizeof(addr), NULL, 0, NI_NUMERICHOST) == 0)
            n += snprintf(conf + n, sizeof(conf) - n, "nameserver %s\n", addr);
    }
    if (n == 0) n += snprintf(conf, sizeof(conf), "nameserver 1.1.1.1\nnameserver 8.8.8.8\n");

    current = pid_get_task(1);
    struct fd *fd = generic_open("/etc/resolv.conf", O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0644);
    if (!IS_ERR(fd)) {
        fd->ops->write(fd, conf, n);
        fd_close(fd);
    }
}

// --- Asbestos JIT crash handler ---------------------------------------------
//
// The arm64 Asbestos engine deliberately lets the JIT'd code take a host SIGSEGV
// on a guest page fault, then recovers in a signal handler (reconstructs the
// guest fault address, rewinds to the block start, and redirects to
// jit_crash_trampoline which returns INT_JIT_CRASH). The standalone `ish` binary
// installs this in main(); our app embeds the engine as a library and must
// install the same handler or guest faults crash the whole app (e.g. `ls`
// page-faults where `uname` doesn't). Ported from ish-arm64 main.c.
//
// Unlike main.c we only hook SIGSEGV/SIGBUS and CHAIN to the previous handler
// for non-JIT faults, so WebKit/Swift/OS crash reporting is left intact.
#if defined(__aarch64__) && defined(GUEST_ARM64)
#include "cpu-offsets.h"  // CPU_pc, CPU_segfault_addr, CPU_segfault_was_write, LOCAL_jit_exit_sp
extern __thread volatile sig_atomic_t in_jit;
extern __thread volatile uint64_t jit_saved_pc;
extern __thread volatile uint64_t jit_last_host_fault;
extern __thread volatile uint64_t jit_last_x7;
extern __thread volatile uint64_t jit_last_x10;
extern __thread volatile int jit_crash_count;
extern void jit_crash_trampoline(void);

static struct sigaction g_prev_segv, g_prev_bus;

static void ish_crash_handler(int sig, siginfo_t *info, void *ctx) {
    if ((sig == SIGSEGV || sig == SIGBUS) && in_jit) {
        ucontext_t *uc = (ucontext_t *)ctx;
        uint64_t cpu_ptr = uc->uc_mcontext->__ss.__x[1];   // _cpu is in x1
        uint64_t x7 = uc->uc_mcontext->__ss.__x[7];
        uint64_t x10 = uc->uc_mcontext->__ss.__x[10];
        uint64_t guest_addr = (x7 - x10) & 0xffffffffffffULL;
        jit_last_host_fault = (uint64_t)info->si_addr;
        jit_last_x7 = x7;
        jit_last_x10 = x10;
        jit_crash_count++;
        uint64_t esr = uc->uc_mcontext->__es.__esr;
        int was_write = (esr & 0x40) != 0;
        *(uint64_t *)(cpu_ptr + CPU_segfault_addr) = guest_addr;
        *(int *)(cpu_ptr + CPU_segfault_was_write) = was_write;
        *(uint64_t *)(cpu_ptr + CPU_pc) = (uint64_t)jit_saved_pc;
        uc->uc_mcontext->__ss.__sp = *(uint64_t *)(cpu_ptr + LOCAL_jit_exit_sp);
        uc->uc_mcontext->__ss.__pc = (uint64_t)jit_crash_trampoline;
        sigset_t unblock;
        sigemptyset(&unblock);
        sigaddset(&unblock, sig);
        sigprocmask(SIG_UNBLOCK, &unblock, NULL);
        return;  // resumes at jit_crash_trampoline
    }
    // Not a JIT fault — hand off to whatever was installed before us.
    struct sigaction *prev = (sig == SIGBUS) ? &g_prev_bus : &g_prev_segv;
    if (prev->sa_flags & SA_SIGINFO) {
        if (prev->sa_sigaction) { prev->sa_sigaction(sig, info, ctx); return; }
    } else if (prev->sa_handler == SIG_IGN) {
        return;
    } else if (prev->sa_handler && prev->sa_handler != SIG_DFL) {
        prev->sa_handler(sig);
        return;
    }
    signal(sig, SIG_DFL);  // default disposition → crash as usual
    raise(sig);
}

static void install_crash_handler(void) {
    static int installed = 0;
    if (installed) return;
    installed = 1;
    static char altstack[SIGSTKSZ];
    stack_t ss = { .ss_sp = altstack, .ss_size = sizeof(altstack) };
    sigaltstack(&ss, NULL);
    struct sigaction sa = {0};
    sa.sa_sigaction = ish_crash_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, &g_prev_segv);
    sigaction(SIGBUS, &sa, &g_prev_bus);
}
#else
static void install_crash_handler(void) {}
#endif

// --- boot + spawn ------------------------------------------------------------

// Terminals run as the `operator` user: `su -l operator` is a login shell, so it
// sets HOME=/home/operator, cwd, and runs operator's login shell (zsh) which
// sources ~/.zshrc (PATH etc.). We're pid 1 / an init child (root), so no
// password is needed. Falls back to a root /bin/sh if su/operator is missing
// (e.g. an old rootfs), so a terminal always comes up.
static const char k_su_argv[] = "/bin/su\0-l\0operator\0";
static const char k_zsh_argv[] = "/bin/zsh\0-l\0";
static const char k_sh_argv[] = "/bin/sh\0-l\0";
static const char k_envp[] =
    "TERM=xterm-256color\0HOME=/home/operator\0PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0";

// do_execve returns 0 on success here (it stages the guest image; it does not
// replace this thread), so the fallback runs only if the exec couldn't happen.
//
// Boot (pid 1, root): `su -l operator` drops to operator with a login shell.
// Spawned ptys are init children that already inherit operator's creds (pid 1
// became operator via the first su), so they exec zsh DIRECTLY — running su again
// as non-root would fail ("su: must be suid to work properly"). Both fall back to
// /bin/sh. .zshrc cd's login shells to $HOME (init children don't inherit cwd).
static int exec_boot_shell(void) {
    int err = do_execve("/bin/su", 3, k_su_argv, k_envp);
    if (err < 0) err = do_execve("/bin/sh", 2, k_sh_argv, k_envp);
    return err;
}

static int exec_pty_shell(void) {
    int err = do_execve("/bin/zsh", 2, k_zsh_argv, k_envp);
    if (err < 0) err = do_execve("/bin/sh", 2, k_sh_argv, k_envp);
    return err;
}

static int boot_kernel(const char *fakefs_dir, int first_id, int cols, int rows) {
    char source[4096];
    snprintf(source, sizeof(source), "%s/data", fakefs_dir);

    install_crash_handler();  // recover guest page faults (else `ls` etc. crash)
    int err = mount_root(&fakefs, source);
    if (err < 0) return err;
    err = become_first_process();
    if (err < 0) return err;
    create_device_nodes();
    do_mount(&procfs, "proc", "/proc", "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);
    configure_dns();

    tty_drivers[TTY_CONSOLE_MAJOR] = &ish_console_driver;
    set_console_device(TTY_CONSOLE_MAJOR, 1);
    g_pending_id = first_id;
    err = create_stdio("/dev/console", TTY_CONSOLE_MAJOR, 1);
    if (err < 0) return err;
    struct tty *tty = term_tty(first_id);
    if (tty) tty_set_winsize(tty, (struct winsize_) { .row = (word_t) rows, .col = (word_t) cols });

    err = exec_boot_shell();
    if (err < 0) return err;
    task_start(current);
    return 0;
}

static int spawn_pty(int term_id, int cols, int rows) {
    int err = become_new_init_child();
    if (err < 0) return err;
    g_pending_id = term_id;
    struct tty *tty = pty_open_fake(&ish_pty_driver);
    if (IS_ERR(tty)) return (int) PTR_ERR(tty);
    if (rows && cols) tty_set_winsize(tty, (struct winsize_) { .row = (word_t) rows, .col = (word_t) cols });

    char path[64];
    snprintf(path, sizeof(path), "/dev/pts/%d", tty->num);
    err = create_stdio(path, TTY_PSEUDO_SLAVE_MAJOR, tty->num);
    tty_release(tty);
    if (err < 0) return err;

    err = exec_pty_shell();
    if (err < 0) return err;
    task_start(current);
    return 0;
}

void ish_set_output(ish_output_cb cb) { g_output = cb; }

int ish_open_terminal(int term_id, int cols, int rows, const char *fakefs_dir) {
    if (!g_booted) {
        int err = boot_kernel(fakefs_dir, term_id, cols, rows);
        if (err < 0) return err;
        g_booted = 1;
        return 0;
    }
    return spawn_pty(term_id, cols, rows);
}

void ish_send_input(int term_id, const char *buf, int len) {
    struct tty *tty = term_tty(term_id);
    if (tty) tty_input(tty, buf, (size_t) len, 0);
}

void ish_set_winsize(int term_id, int cols, int rows) {
    struct tty *tty = term_tty(term_id);
    if (tty) tty_set_winsize(tty, (struct winsize_) { .row = (word_t) rows, .col = (word_t) cols });
}

void ish_close_terminal(int term_id) {
    // The guest shell exits on EOF; just drop our routing so output stops.
    struct tty *tty = term_tty(term_id);
    if (tty) term_forget(tty);
}

// --- Guest filesystem access -------------------------------------------------

#define ISH_S_IFMT  0xF000
#define ISH_S_IFDIR 0x4000

int ish_is_booted(void) { return g_booted; }

// Every fs op runs against pid 1's fs context on the calling (serial) thread.
static int fs_enter(void) {
    if (!g_booted) return -1;
    current = pid_get_task(1);
    return current ? 0 : -1;
}

int ish_fs_stat(const char *path, int *is_dir, long *size, long *mtime) {
    if (fs_enter() < 0) return -1;
    struct statbuf st;
    int err = generic_statat(AT_PWD, path, &st, true);
    if (err < 0) return err;
    if (is_dir) *is_dir = (st.mode & ISH_S_IFMT) == ISH_S_IFDIR ? 1 : 0;
    if (size) *size = (long) st.size;
    if (mtime) *mtime = (long) st.mtime;
    return 0;
}

char *ish_fs_list(const char *path) {
    if (fs_enter() < 0) return NULL;
    struct fd *dir = generic_open(path, 0 /*O_RDONLY*/, 0);
    if (IS_ERR(dir)) return NULL;

    size_t cap = 4096, len = 0;
    char *out = malloc(cap);
    if (!out) { fd_close(dir); return NULL; }

    struct dir_entry entry;
    while (dir->ops->readdir(dir, &entry) > 0) {
        if (strcmp(entry.name, ".") == 0 || strcmp(entry.name, "..") == 0) continue;
        char child[4096];
        snprintf(child, sizeof(child), "%s/%s", path, entry.name);
        struct statbuf st;
        char type = 'f';
        if (generic_statat(AT_PWD, child, &st, false) == 0)
            type = ((st.mode & ISH_S_IFMT) == ISH_S_IFDIR) ? 'd' : 'f';
        size_t need = strlen(entry.name) + 4;
        if (len + need >= cap) { cap *= 2; char *n = realloc(out, cap); if (!n) { free(out); fd_close(dir); return NULL; } out = n; }
        len += snprintf(out + len, cap - len, "%c %s\n", type, entry.name);
    }
    fd_close(dir);
    out[len] = '\0';
    return out;
}

void *ish_fs_read(const char *path, int *len) {
    if (len) *len = 0;
    if (fs_enter() < 0) return NULL;
    struct fd *fd = generic_open(path, 0 /*O_RDONLY*/, 0);
    if (IS_ERR(fd)) return NULL;

    size_t cap = 65536, total = 0;
    char *buf = malloc(cap);
    if (!buf) { fd_close(fd); return NULL; }
    for (;;) {
        if (total == cap) { cap *= 2; char *n = realloc(buf, cap); if (!n) { free(buf); fd_close(fd); return NULL; } buf = n; }
        ssize_t r = fd->ops->read(fd, buf + total, cap - total);
        if (r <= 0) break;
        total += (size_t) r;
    }
    fd_close(fd);
    if (len) *len = (int) total;
    return buf;
}

int ish_fs_write(const char *path, const void *buf, int len) {
    if (fs_enter() < 0) return -1;
    struct fd *fd = generic_open(path, O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0644);
    if (IS_ERR(fd)) return (int) PTR_ERR(fd);
    ssize_t w = fd->ops->write(fd, buf, (size_t) len);
    fd_close(fd);
    return w < 0 ? (int) w : 0;
}

int ish_fs_mkdir(const char *path) {
    if (fs_enter() < 0) return -1;
    return generic_mkdirat(AT_PWD, path, 0755);
}

int ish_fs_delete(const char *path) {
    if (fs_enter() < 0) return -1;
    int err = generic_unlinkat(AT_PWD, path);
    if (err == _EISDIR || err == _EPERM) err = generic_rmdirat(AT_PWD, path);
    return err;
}

int ish_fs_rename(const char *from, const char *to) {
    if (fs_enter() < 0) return -1;
    return generic_renameat(AT_PWD, from, AT_PWD, to);
}

void ish_free(void *p) { free(p); }
