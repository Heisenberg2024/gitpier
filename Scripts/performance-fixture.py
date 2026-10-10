#!/usr/bin/env python3
"""Build only an empty caller-owned temporary fixture; never use a user repository."""
from pathlib import Path
import argparse
import os
import subprocess
import json

parser = argparse.ArgumentParser()
parser.add_argument("root", type=Path)
args = parser.parse_args()
base = args.root.resolve()
if any(base.iterdir()):
    raise SystemExit("Performance fixture directory must be empty")
(base / "performance-fixture.json").write_text(json.dumps({"kind": "GitPier disposable performance fixture"}))
env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null",
           GIT_AUTHOR_NAME="GitPier Performance", GIT_AUTHOR_EMAIL="performance@example.invalid",
           GIT_COMMITTER_NAME="GitPier Performance", GIT_COMMITTER_EMAIL="performance@example.invalid")

def git(repo, *argv, data=None):
    return subprocess.run(["/usr/bin/git", "-C", str(repo), *argv], input=data, env=env,
                          check=True, capture_output=True).stdout.decode().strip()

repo = base / "repository"
(repo / "Sources").mkdir(parents=True)
git(repo, "init", "-b", "main")
git(repo, "config", "user.name", "GitPier Performance")
git(repo, "config", "user.email", "performance@example.invalid")
git(repo, "config", "commit.gpgsign", "false")
git(repo, "config", "gc.auto", "0")
git(repo, "config", "maintenance.auto", "false")
for i in range(10000):
    (repo / "Sources" / f"file_{i:05}.swift").write_text(f"import Foundation\nlet value{i} = {i}\n")
large = "".join(f"let row{i} = {i}\n" for i in range(6000))
(repo / "large.swift").write_text(large)
git(repo, "add", "--", "Sources", "large.swift")
tree = git(repo, "write-tree")
parent = None
for i in range(1000):
    command = ["commit-tree", tree]
    if parent:
        command += ["-p", parent]
    parent = git(repo, *command, data=f"perf: history fixture {i}\n".encode())
git(repo, "update-ref", "refs/heads/main", parent)
remote = base / "remote.git"
subprocess.run(["/usr/bin/git", "clone", "--bare", str(repo), str(remote)], env=env,
               check=True, capture_output=True)
git(remote, "config", "gc.auto", "0")
git(remote, "config", "maintenance.auto", "false")
git(repo, "remote", "add", "origin", str(remote))
git(repo, "config", "branch.main.remote", "origin")
git(repo, "config", "branch.main.merge", "refs/heads/main")
git(repo, "fetch", "origin")
git(repo, "worktree", "add", "-b", "linked-fixture", str(base / "linked"))
for i in range(500):
    (repo / "Sources" / f"file_{i:05}.swift").write_text(f"import Foundation\nlet value{i} = {i + 1}\n")
for i in range(500):
    (repo / f"new_{i:05}.swift").write_text(f"let new{i} = true\n")
(repo / "large.swift").write_text(large.replace(" = ", " = 1 + "))
for i in range(1, 9):
    small = base / f"repo_{i}"
    small.mkdir()
    git(small, "init", "-b", "main")
    git(small, "config", "user.name", "GitPier Performance")
    git(small, "config", "user.email", "performance@example.invalid")
    git(small, "config", "commit.gpgsign", "false")
    for j in range(100):
        (small / f"file_{j:03}.txt").write_text(f"repository {i}, file {j}\n")
    git(small, "add", "--", ".")
    git(small, "commit", "-m", "fixture seed")
(base / "shell").mkdir()
(base / "shell" / ".zshrc").write_text("PROMPT='GitPier %# '\n")
print("Isolated fixture: 10,001 tracked files; 1,001 changes; 1,000 commits; 10 repositories")
