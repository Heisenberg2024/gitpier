#include "PTYSupport.h"
#include <libproc.h>
#include <signal.h>
#include <stdlib.h>
#include <unistd.h>

// Only the controlling session created by our PTY, never the application's own session.
void gitpier_hangup_session(pid_t leader) {
    if (leader <= 1 || getsid(leader) != leader || getsid(0) == leader) return;
    int count = proc_listallpids(NULL, 0);
    if (count <= 0) return;
    pid_t *pids = calloc((size_t)count + 32, sizeof(pid_t));
    if (!pids) return;
    int actual = proc_listallpids(pids, (count + 32) * (int)sizeof(pid_t));
    for (int i = 0; i < actual; i++) {
        pid_t pid = pids[i];
        if (pid > 1 && pid != getpid() && getsid(pid) == leader) kill(pid, SIGHUP);
    }
    free(pids);
}

void gitpier_signal_process_tree(pid_t root, int signal_number) {
    if (root <= 1 || root == getpid()) return;
    int count = proc_listallpids(NULL, 0);
    if (count <= 0) return;
    pid_t *pids = calloc((size_t)count + 32, sizeof(pid_t));
    struct proc_bsdinfo *infos = calloc((size_t)count + 32, sizeof(struct proc_bsdinfo));
    if (!pids || !infos) { free(pids); free(infos); return; }
    int actual = proc_listallpids(pids, (count + 32) * (int)sizeof(pid_t));
    for (int i = 0; i < actual; i++) proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &infos[i], sizeof(struct proc_bsdinfo));
    for (int i = 0; i < actual; i++) {
        pid_t candidate = pids[i], parent = (pid_t)infos[i].pbi_ppid;
        if (candidate <= 1 || candidate == root || candidate == getpid()) continue;
        int related = 0;
        for (int hop = 0; hop < 128 && parent > 1; hop++) {
            if (parent == root) { related = 1; break; }
            pid_t next = 0;
            for (int j = 0; j < actual; j++) if (pids[j] == parent) { next = (pid_t)infos[j].pbi_ppid; break; }
            if (next == parent) break;
            parent = next;
        }
        struct proc_bsdinfo current = {0};
        if (related && proc_pidinfo(candidate, PROC_PIDTBSDINFO, 0, &current, sizeof(current)) == sizeof(current)
            && current.pbi_start_tvsec == infos[i].pbi_start_tvsec && current.pbi_start_tvusec == infos[i].pbi_start_tvusec) kill(candidate, signal_number);
    }
    kill(root, signal_number);
    free(infos); free(pids);
}
