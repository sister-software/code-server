#include "IshBridge.h"
#include <string.h>
#include <stdlib.h>
#include <resolv.h>
#include <netdb.h>

// iSH core headers (GPLv3). Compiled with the iSH source root + build-ios on
// the header search path. Ported/trimmed from app/AppDelegate.m (boot) and
// app/Terminal.m (tty driver).
#include "misc.h"
#include "kernel/init.h"
#include "kernel/fs.h"
#include "kernel/calls.h"
#include "kernel/task.h"
#include "fs/tty.h"
#include "fs/devices.h"

static ish_output_cb g_output;
static struct tty *g_console;
static int g_running;

// --- tty driver: guest console I/O ------------------------------------------

static int ish_tty_init(struct tty *tty) {
    // Called under ttys_lock; releasing it matches iSH's own driver (it can
    // re-enter). We only need to capture the console tty.
    g_console = tty;
    return 0;
}

static int ish_tty_write(struct tty *tty, const void *buf, size_t len, bool blocking) {
    (void) tty; (void) blocking;
    if (g_output) g_output((const char *) buf, (int) len);
    return (int) len;
}

static void ish_tty_cleanup(struct tty *tty) {
    if (g_console == tty) g_console = NULL;
}

static struct tty_driver_ops ish_tty_ops = {
    .init = ish_tty_init,
    .write = ish_tty_write,
    .cleanup = ish_tty_cleanup,
};
DEFINE_TTY_DRIVER(ish_console_driver, &ish_tty_ops, TTY_CONSOLE_MAJOR, 64);

// --- DNS: copy the host's resolvers into the guest's /etc/resolv.conf --------
// Ported from app/AppDelegate.m -configureDns. Without it apk/curl can't
// resolve names ("temporary error").

static void configure_dns(void) {
    struct __res_state res;
    if (res_ninit(&res) != 0) return;

    char conf[2048];
    size_t n = 0;
    if (res.dnsrch[0] != NULL) {
        n += snprintf(conf + n, sizeof(conf) - n, "search");
        for (int i = 0; res.dnsrch[i] != NULL && n < sizeof(conf); i++)
            n += snprintf(conf + n, sizeof(conf) - n, " %s", res.dnsrch[i]);
        n += snprintf(conf + n, sizeof(conf) - n, "\n");
    }
    union res_sockaddr_union servers[NI_MAXSERV];
    int found = res_getservers(&res, servers, NI_MAXSERV);
    char addr[NI_MAXHOST];
    for (int i = 0; i < found && n < sizeof(conf); i++) {
        if (servers[i].sin.sin_len == 0) continue;
        if (getnameinfo((struct sockaddr *) &servers[i].sin, servers[i].sin.sin_len,
                        addr, sizeof(addr), NULL, 0, NI_NUMERICHOST) == 0)
            n += snprintf(conf + n, sizeof(conf) - n, "nameserver %s\n", addr);
    }
    // Fallback so name resolution works even if the host gave us nothing.
    if (n == 0) n += snprintf(conf, sizeof(conf), "nameserver 1.1.1.1\nnameserver 8.8.8.8\n");

    current = pid_get_task(1);
    struct fd *fd = generic_open("/etc/resolv.conf", O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0644);
    if (!IS_ERR(fd)) {
        fd->ops->write(fd, conf, n);
        fd_close(fd);
    }
}

// --- boot --------------------------------------------------------------------

int ish_boot(const char *fakefs_dir, ish_output_cb cb) {
    if (g_running) return 0;
    g_output = cb;

    // fakefs source is the data/ dir; meta.db sits beside it.
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
    err = create_stdio("/dev/console", TTY_CONSOLE_MAJOR, 1);
    if (err < 0) return err;

    // Launch a login shell. argv/envp are packed null-separated buffers.
    static const char argv[] = "/bin/sh\0-l\0";
    static const char envp[] = "TERM=xterm-256color\0HOME=/root\0PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0";
    err = do_execve("/bin/sh", 2, argv, envp);
    if (err < 0) return err;

    task_start(current);
    g_running = 1;
    return 0;
}

void ish_send_input(const char *buf, int len) {
    if (g_console) tty_input(g_console, buf, (size_t) len, 0);
}

void ish_set_winsize(int cols, int rows) {
    if (g_console) {
        struct winsize_ ws = { .row = (word_t) rows, .col = (word_t) cols, .xpixel = 0, .ypixel = 0 };
        tty_set_winsize(g_console, ws);
    }
}

int ish_is_running(void) { return g_running; }
