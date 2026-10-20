#include "PTYSupport.h"
#include <libproc.h>
#include <signal.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <string.h>
#include <poll.h>

int gitpier_exec_task_agent(int argc, char *const argv[]) {
    if (argc != 14 || strcmp(argv[1], "--task-agent-launch")) return 126;
    char *end = NULL;
    long gate = strtol(argv[2], &end, 10);
    if (!end || *end || gate < 3 || gate > INT32_MAX) return 126;
    struct stat pipeState = {0};
    if (fstat((int)gate, &pipeState) || !S_ISFIFO(pipeState.st_mode)) return 126;
    char permission = 0; ssize_t received;
    struct pollfd ready = {(int)gate, POLLIN, 0};
    int available;
    do { available = poll(&ready, 1, 10000); } while (available < 0 && errno == EINTR);
    if (available <= 0) { close((int)gate); return 126; }
    do { received = read((int)gate, &permission, 1); } while (received < 0 && errno == EINTR);
    close((int)gate);
    if (received != 1 || permission != '1') return 126;
    uint64_t device = strtoull(argv[3], &end, 10);
    if (!end || *end) return 126;
    uint64_t inode = strtoull(argv[4], &end, 10);
    if (!end || *end || argv[5][0] != '/' || argv[6][0] != '/') return 126;
    int directory = open(argv[5], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat state = {0};
    if (directory < 0) return 126;
    int valid = fstat(directory, &state) == 0 && (uint64_t)state.st_dev == device && state.st_ino == inode;
    if (!valid || fchdir(directory)) { close(directory); return 126; }
    close(directory);
    uint64_t expected[7];
    for (int i = 0; i < 7; i++) {
        if (!argv[7+i][0] || argv[7+i][0] == '-') return 126;
        errno = 0; expected[i] = strtoull(argv[7+i], &end, 10);
        if (!end || *end || errno) return 126;
    }
    struct stat executable = {0};
    if (lstat(argv[6], &executable) || !S_ISREG(executable.st_mode) || access(argv[6], X_OK)) return 126;
    uint64_t actual[] = {(uint64_t)executable.st_dev, executable.st_ino, (uint64_t)executable.st_size,
        (uint64_t)executable.st_mtimespec.tv_sec, (uint64_t)executable.st_mtimespec.tv_nsec,
        (uint64_t)executable.st_ctimespec.tv_sec, (uint64_t)executable.st_ctimespec.tv_nsec};
    if (memcmp(expected, actual, sizeof(expected))) return 126;
    char *const arguments[] = {"codex", "--no-daemon", "--sandbox", "workspace-write", "--ask-for-approval", "on-request", NULL};
    extern char **environ;
    execve(argv[6], arguments, environ);
    return 127;
}

GitPierProcessIdentity gitpier_process_identity(pid_t pid) {
    struct proc_bsdinfo info = {0};
    GitPierProcessIdentity result = {0};
    if (pid > 1 && pid != getpid() && proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info)) {
        result.pid = pid; result.seconds = info.pbi_start_tvsec; result.microseconds = info.pbi_start_tvusec;
    }
    return result;
}
static int same_process(GitPierProcessIdentity expected) {
    GitPierProcessIdentity actual = gitpier_process_identity(expected.pid);
    return expected.pid > 1 && actual.pid == expected.pid && actual.seconds == expected.seconds && actual.microseconds == expected.microseconds;
}
int gitpier_terminate_owned_session(GitPierProcessIdentity leader) {
    if (leader.pid <= 1 || leader.pid == getpid() || getsid(0) == leader.pid) return -1;
    // A live replacement leader proves this session number is no longer ours.
    GitPierProcessIdentity currentLeader = gitpier_process_identity(leader.pid);
    if (currentLeader.pid && !same_process(leader)) return -1;
    if (!currentLeader.pid && (kill(leader.pid, 0) == 0 || errno != ESRCH)) return -1;
    int capacity = proc_listallpids(NULL, 0) + 256;
    if (capacity <= 256) return -1;
    pid_t *pids = calloc((size_t)capacity, sizeof(pid_t));
    struct proc_bsdinfo *infos = calloc((size_t)capacity, sizeof(struct proc_bsdinfo));
    GitPierProcessIdentity *owned = calloc((size_t)capacity, sizeof(GitPierProcessIdentity));
    if (!pids || !infos || !owned) { free(pids); free(infos); free(owned); return -1; }
    int count = proc_listallpids(pids, capacity * (int)sizeof(pid_t)), total = 0;
    if (count <= 0 || count >= capacity) { free(pids); free(infos); free(owned); return -1; }
    for (int i = 0; i < count; i++) proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &infos[i], sizeof(struct proc_bsdinfo));
    for (int i = 0; i < count; i++) {
        pid_t pid = pids[i], parent = (pid_t)infos[i].pbi_ppid;
        if (pid <= 1 || pid == getpid()) continue;
        int related = getsid(pid) == leader.pid;
        if (same_process(leader)) {
            for (int hop = 0; !related && hop < 128 && parent > 1; hop++) {
                if (parent == leader.pid) { related = 1; break; }
                pid_t next = 0;
                for (int j = 0; j < count; j++) if (pids[j] == parent) { next = (pid_t)infos[j].pbi_ppid; break; }
                if (next == parent) break;
                parent = next;
            }
        }
        if (!related || infos[i].pbi_start_tvsec < leader.seconds || (infos[i].pbi_start_tvsec == leader.seconds && infos[i].pbi_start_tvusec < leader.microseconds)) continue;
        owned[total++] = (GitPierProcessIdentity){pid, infos[i].pbi_start_tvsec, infos[i].pbi_start_tvusec};
    }
    free(pids); free(infos);
    int remaining = total;
    const int signals[] = {SIGHUP, SIGTERM, SIGKILL};
    for (int phase = 0; phase < 3 && remaining; phase++) {
        for (int i = total - 1; i >= 0; i--) if (same_process(owned[i])) kill(owned[i].pid, signals[phase]);
        for (int attempt = 0; attempt < 20; attempt++) {
            struct timespec interval = {0, 25000000}; nanosleep(&interval, NULL);
            remaining = 0;
            for (int i = 0; i < total; i++) {
                struct proc_bsdinfo state = {0};
                if (same_process(owned[i]) && proc_pidinfo(owned[i].pid, PROC_PIDTBSDINFO, 0, &state, sizeof(state)) == sizeof(state)
                    && state.pbi_status != 5 /* SZOMB */) remaining++;
            }
            if (!remaining) break;
        }
    }
    // Catch processes spawned by a signal handler after the initial snapshot.
    // They were never verified/signalled, so report the session as still active.
    int finalCapacity = proc_listallpids(NULL, 0) + 256;
    if (finalCapacity <= 256) { free(owned); return -1; }
    pid_t *finalPids = calloc((size_t)finalCapacity, sizeof(pid_t));
    if (!finalPids) { free(owned); return -1; }
    int finalCount = proc_listallpids(finalPids, finalCapacity * (int)sizeof(pid_t));
    if (finalCount <= 0 || finalCount >= finalCapacity) { free(finalPids); free(owned); return -1; }
    for (int i = 0; i < total; i++) {
        GitPierProcessIdentity actual = gitpier_process_identity(owned[i].pid);
        if (!actual.pid && (kill(owned[i].pid, 0) == 0 || errno != ESRCH)) remaining++;
    }
    for (int i = 0; i < finalCount; i++) {
        struct proc_bsdinfo state = {0};
        if (finalPids[i] > 1 && getsid(finalPids[i]) == leader.pid) {
            int readState = proc_pidinfo(finalPids[i], PROC_PIDTBSDINFO, 0, &state, sizeof(state));
            if (readState == sizeof(state)) { if (state.pbi_status != 5) remaining++; }
            else if (kill(finalPids[i], 0) == 0 || errno != ESRCH) remaining++;
        }
    }
    free(finalPids); free(owned); return remaining;
}

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
