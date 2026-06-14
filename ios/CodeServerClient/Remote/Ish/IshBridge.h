#pragma once
#include <stddef.h>

// Clean C API over the iSH x86-Linux emulator core (GPLv3 — see Vendor/ish).
// Boots an Alpine guest once and exposes a single console tty wired to the
// terminal front-end. Keeps iSH's headers out of the Swift bridging header.

typedef void (*ish_output_cb)(const char *buf, int len);

// Boot the guest from a WRITABLE fakefs directory (containing data/ + meta.db).
// `cb` receives all console output. Returns 0 on success, <0 on error.
// Safe to call once; subsequent calls are no-ops returning 0.
int ish_boot(const char *fakefs_dir, ish_output_cb cb);

// Feed raw keystrokes to the console tty.
void ish_send_input(const char *buf, int len);

// Update the console window size.
void ish_set_winsize(int cols, int rows);

// Whether the guest has booted.
int ish_is_running(void);
