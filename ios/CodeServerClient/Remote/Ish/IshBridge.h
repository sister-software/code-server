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

// --- Guest filesystem access (for mounting the Alpine fs into the editor) ----
// All paths are absolute guest paths. Require the guest to be booted (a
// terminal opened at least once). Return 0 / <0 on the int-returning ops.

int ish_is_booted(void);

// stat: is_dir=1 for directories; size/mtime filled. Returns 0 or <0.
int ish_fs_stat(const char *path, int *is_dir, long *size, long *mtime);

// list: returns a malloc'd, newline-separated "<d|f> <name>" listing (skips
// . and ..), or NULL. Free with ish_free.
char *ish_fs_list(const char *path);

// read: returns malloc'd file bytes (sets *len), or NULL. Free with ish_free.
void *ish_fs_read(const char *path, int *len);

int ish_fs_write(const char *path, const void *buf, int len);
int ish_fs_mkdir(const char *path);
int ish_fs_delete(const char *path);            // file or empty dir
int ish_fs_rename(const char *from, const char *to);

void ish_free(void *p);
