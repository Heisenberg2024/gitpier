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
task_bin=""
if [[ -n "${GITPIER_UI_ACCEPTANCE_EXECUTABLE:-}" ]]; then
  [[ -x "$GITPIER_UI_ACCEPTANCE_EXECUTABLE" ]] || { echo 'The acceptance executable is missing.' >&2; exit 1; }
else
  swift build --build-system native --disable-sandbox --cache-path "$task_root/.cache/swiftpm" --product GitPier
  task_bin="$(swift build --build-system native --disable-sandbox --cache-path "$task_root/.cache/swiftpm" --show-bin-path)"
fi
task_output="${1:-$task_root/.cache/ui-acceptance}"
if [[ "${GITPIER_UI_ACCEPTANCE_LAUNCH_BUNDLE:-0}" == 1 ]]; then
  task_executable="${GITPIER_UI_ACCEPTANCE_EXECUTABLE:?Bundle launch requires the disposable application copy}"
  task_app="${task_executable%/Contents/MacOS/GitPier}"
  task_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$task_app/Contents/Info.plist")"
  [[ "$task_id" == com.heisenberg2024.gitpier.workspace-test.* && "${GITPIER_UI_ACCEPTANCE_SCOPE:-}" == version144 ]] || { echo 'Bundle launch requires the isolated authentication fixture.' >&2; exit 1; }
  mkdir -p "$task_output"
  task_output="$(cd "$task_output" && pwd)"
  task_launch_env=(--env "ZDOTDIR=$task_temp/home" --env "GITPIER_WORKSPACE_FILE=$task_temp/workspace.json" --env GIT_CONFIG_NOSYSTEM=1 --env GIT_CONFIG_GLOBAL=/dev/null)
  for task_key in GITPIER_AUTH_ACCEPTANCE_URL GITPIER_AUTH_ACCEPTANCE_CERT GIT_SSL_CAINFO GITPIER_UI_ACCEPTANCE_SCOPE GITPIER_UI_ACCEPTANCE_INTERACTIVE_V144; do
    task_launch_env+=(--env "$task_key=${!task_key:-}")
  done
  /usr/bin/open -n -W --stdout "$task_output/launch-stdout.log" --stderr "$task_output/launch-stderr.log" "${task_launch_env[@]}" -a "$task_app" --args --ui-acceptance --repository "$task_repo" --output "$task_output"
  # Launch Services returns independently of the application exit status.
  [[ -f "$task_output/v144-results.txt" ]] || { echo 'Authentication application did not complete acceptance.' >&2; exit 1; }
else
  ZDOTDIR="$task_temp/home" GITPIER_WORKSPACE_FILE="$task_temp/workspace.json" "${GITPIER_UI_ACCEPTANCE_EXECUTABLE:-$task_bin/GitPier}" --ui-acceptance --repository "$task_repo" --output "$task_output"
fi
