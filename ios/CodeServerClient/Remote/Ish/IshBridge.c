#include "IshBridge.h"
#include <string.h>
#include <stdlib.h>
#include <resolv.h>
#include <netdb.h>

// iSH core headers (GPLv3). Header search path includes the iSH source root +
// build-ios. Ported/trimmed from app/AppDelegate.m (boot), app/Terminal.m (tty
// driver) and app/TerminalViewController.m (per-terminal pty spawn).
#include "misc.h"
#include "kernel/init.h"
#include "kernel/fs.h"
#include "kernel/calls.h"
#include "kernel/task.h"
#include "fs/tty.h"
#include "fs/devices.h"

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

// --- boot + spawn ------------------------------------------------------------

static const char k_argv[] = "/bin/sh\0-l\0";
static const char k_envp[] =
    "TERM=xterm-256color\0HOME=/root\0PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0";

static int boot_kernel(const char *fakefs_dir, int first_id, int cols, int rows) {
    char source[4096];
    snprintf(source, sizeof(source), "%s/data", fakefs_dir);

    int err = mount_root(&fakefs, source);
    if (err < 0) return err;
    err = become_first_process();
    if (err < 0) return err;
    create_some_device_nodes();
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

    err = do_execve("/bin/sh", 2, k_argv, k_envp);
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

    err = do_execve("/bin/sh", 2, k_argv, k_envp);
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
