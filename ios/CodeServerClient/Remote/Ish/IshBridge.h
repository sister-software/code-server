#pragma once
#include <stddef.h>

// Clean C API over the iSH x86-Linux emulator core (GPLv3 — see Vendor/ish).
// Boots an Alpine guest once; each terminal is a guest process on its own tty
// (the console for pid 1, pseudo-terminals for the rest), keyed by a caller-
// supplied id. Keeps iSH's headers out of the Swift bridging header.

// Receives console/pty output for a given terminal id (fires off the emulator
// thread it runs on).
typedef void (*ish_output_cb)(int term_id, const char *buf, int len);

void ish_set_output(ish_output_cb cb);

// Open a terminal: boots the kernel on the first call (its shell is pid 1),
// otherwise spawns a new pseudo-terminal + shell. Returns 0 on success.
int ish_open_terminal(int term_id, int cols, int rows, const char *fakefs_dir);

// Feed raw keystrokes to a terminal.
void ish_send_input(int term_id, const char *buf, int len);

// Update a terminal's window size.
void ish_set_winsize(int term_id, int cols, int rows);

// Detach a terminal (the guest shell exits on its own when it gets EOF/exit).
void ish_close_terminal(int term_id);
