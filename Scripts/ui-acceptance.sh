#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_root="$PWD"
task_temp="$(mktemp -d "${TMPDIR:-/tmp}/GitPier-ui.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT
task_repo="$task_temp/repository"
mkdir -p "$task_repo/Sources" "$task_temp/home"
printf "PROMPT='GitPier %%1~ %%# '\n" > "$task_temp/home/.zshrc"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
git -C "$task_repo" init -b main
git -C "$task_repo" config user.name "GitPier Acceptance"
git -C "$task_repo" config user.email "acceptance@example.invalid"
git -C "$task_repo" config commit.gpgsign false
cat > "$task_repo/Sources/workspace.swift" <<'SWIFT'
import Foundation

struct Repository {
    let name: String
    let path: URL
}

actor Workspace {
    private var repositories: [Repository] = []

    func open(_ repository: Repository) {
        repositories.append(repository)
    }

    func refresh() async {
        for repository in repositories {
            print(repository.name)
        }
    }
}
SWIFT
printf '# Workspace\n\nAll Your Repositories. One Workspace.\n' > "$task_repo/README.md"
git -C "$task_repo" add -- Sources/workspace.swift README.md
git -C "$task_repo" commit -m "feat: create repository workspace"
git init --bare "$task_temp/remote.git"
git -C "$task_repo" remote add origin "$task_temp/remote.git"
git -C "$task_repo" push -u origin main
for task_name in ordered-one ordered-two ordered-three; do
  mkdir -p "$task_temp/$task_name"
  git -C "$task_temp/$task_name" init -b main
done
git -C "$task_repo" branch feature/terminal
python3 - "$task_repo/Sources/workspace.swift" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
p.write_text(p.read_text().replace('let path: URL','let path: URL\n    var stagedCount: Int = 0').replace('print(repository.name)', 'print("Refreshing: \\(repository.name)")\n            await synchronizeIndex(repository)')+'\n// Stage exact paths; never reset another tool\'s Index.\n')
PY
printf '\nReview the Index before committing.\n' >> "$task_repo/README.md"
printf '{"theme":"system"}\n' > "$task_repo/settings.json"
export CLANG_MODULE_CACHE_PATH="$task_root/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_root/.cache/swift"
swift build --build-system native --disable-sandbox --cache-path "$task_root/.cache/swiftpm" --product GitPier
task_bin="$(swift build --build-system native --disable-sandbox --cache-path "$task_root/.cache/swiftpm" --show-bin-path)"
ZDOTDIR="$task_temp/home" GITPIER_WORKSPACE_FILE="$task_temp/workspace.json" "${GITPIER_UI_ACCEPTANCE_EXECUTABLE:-$task_bin/GitPier}" --ui-acceptance --repository "$task_repo" --output "${1:-$task_root/.cache/ui-acceptance}"
