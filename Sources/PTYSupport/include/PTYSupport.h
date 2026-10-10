#ifndef GITPIER_PTY_SUPPORT_H
#define GITPIER_PTY_SUPPORT_H
#include <sys/types.h>
void gitpier_hangup_session(pid_t session_leader);
void gitpier_signal_process_tree(pid_t root, int signal_number);
#endif
