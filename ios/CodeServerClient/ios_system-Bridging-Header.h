// Bridging header for ios_system — exposes the per-thread stdio
// FILE pointers and the ios_system() entrypoint to Swift.
//
// ios_system uses __thread globals (thread_stdin / thread_stdout /
// thread_stderr) so each pthread gets its own I/O redirects.
// Setting these before calling ios_system() in a pthread routes
// the command's output to our pipes.

#include <stdio.h>
#import <Foundation/Foundation.h>

// One-time setup of ios_system's command table / environment. Must run before
// any ios_system() call or commands won't resolve.
extern void initializeEnvironment(void);

// Enables the full command set (the extraCommandsDictionary). Dev build, so on.
extern bool sideLoading;

extern int ios_system(const char *command);

extern __thread FILE *thread_stdin;
extern __thread FILE *thread_stdout;
extern __thread FILE *thread_stderr;

// Per-session stream routing — the correct way to capture a command's output
// (setting the __thread globals alone leaves output on the app's real stdout).
extern void ios_switchSession(const void *sessionid);
extern void ios_closeSession(const void *sessionid);
extern void ios_setContext(const void *context);
extern void ios_setStreams(FILE *_stdin, FILE *_stdout, FILE *_stderr);
extern void ios_setWindowSize(int width, int height, const void *sessionId);
extern void ios_settty(FILE *_tty);   // mark the streams as a tty (interactive programs)
extern int ios_kill(void);            // interrupt the running command (Ctrl-C)
