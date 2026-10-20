#ifndef GITPIER_PTY_SUPPORT_H
#define GITPIER_PTY_SUPPORT_H
#include <sys/types.h>
#include <stdint.h>
typedef struct {
    pid_t pid;
    uint64_t seconds;
    uint64_t microseconds;
} GitPierProcessIdentity;
GitPierProcessIdentity gitpier_process_identity(pid_t pid);
// Bounded cleanup of a verified PTY session and currently attached descendants.
// Returns remaining verified processes; never signals a reused PID.
int gitpier_terminate_owned_session(GitPierProcessIdentity identity);
// Internal argv entry point: gated foreground exec after descriptor-bound cwd validation.
int gitpier_exec_task_agent(int argc, char *const argv[]);
void gitpier_hangup_session(pid_t session_leader);
void gitpier_signal_process_tree(pid_t root, int signal_number);
#endif
