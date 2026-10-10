#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_root="$PWD"
task_output="${1:-$task_root/docs/screenshots}"
mkdir -p "$task_output"
task_output="$(cd "$task_output" && pwd -P)"
task_temp="$(mktemp -d "${TMPDIR:-/tmp}/GitPier-product.XXXXXX")"
task_temp="$(cd "$task_temp" && pwd -P)"
trap 'rm -rf "$task_temp"' EXIT
printf 'GitPier product fixture\n' > "$task_temp/.gitpier-product-fixture"
mkdir -p "$task_temp/shell"
cat > "$task_temp/shell/.zshrc" <<'SHELL'
unset HISTFILE
PROMPT='%F{cyan}demo%f %F{blue}%1~%f %F{green}❯%f '
RPROMPT=''
SHELL
# Do not inherit an alternate Index, author identity, or injected Git configuration.
while IFS= read -r task_git_variable; do
  unset "$task_git_variable"
done < <(compgen -v GIT_)
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_TERMINAL_PROMPT=0
for task_name in sample-app example-api demo-dashboard sample-library; do
  task_repo="$task_temp/$task_name"
  mkdir -p "$task_repo/Sources"
  git -C "$task_repo" init -q -b main
  git -C "$task_repo" config user.name 'Demo Developer'
  git -C "$task_repo" config user.email 'demo@example.com'
  git -C "$task_repo" config commit.gpgsign false
  git -C "$task_repo" config core.hooksPath /dev/null
  git -C "$task_repo" config maintenance.auto false
  cat > "$task_repo/Sources/RepositoryView.swift" <<'SWIFT'
import SwiftUI

struct Project: Identifiable {
    let id: UUID
    let name: String
    let branch: String
}

struct RepositoryView: View {
    let projects: [Project]
    @State private var selectedProject: UUID?

    var body: some View {
        List(projects, selection: $selectedProject) { project in
            HStack(spacing: 12) {
                Image(systemName: "folder")
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                    Text(project.branch)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        }
        .navigationTitle("Projects")
    }
}
SWIFT
  printf '# Sample project\n\nA small demonstration workspace.\n' > "$task_repo/README.md"
  git -C "$task_repo" add -- Sources/RepositoryView.swift README.md
  git -C "$task_repo" commit -q -m 'feat: create project workspace'
  printf 'import SwiftUI\n\nstruct SettingsView: View {\n    var body: some View {\n        Text("Appearance follows your workspace.")\n    }\n}\n' > "$task_repo/Sources/SettingsView.swift"
  git -C "$task_repo" add -- Sources/SettingsView.swift
  git -C "$task_repo" commit -q -m 'feat: add appearance settings'
  printf '\n## Navigation\n\nSelect a project to review its changes.\n' >> "$task_repo/README.md"
  git -C "$task_repo" add -- README.md
  git -C "$task_repo" commit -q -m 'fix: clarify project selection'
  printf '\n## Getting started\n\nOpen a project and explore the workspace.\n' >> "$task_repo/README.md"
  git -C "$task_repo" add -- README.md
  git -C "$task_repo" commit -q -m 'docs: update installation guide'
  git -C "$task_repo" branch develop
  git -C "$task_repo" branch feature/ui-improvements
  python3 - "$task_repo" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
p = root / 'Sources/RepositoryView.swift'
p.write_text(p.read_text().replace('Image(systemName: "folder")', 'Image(systemName: "shippingbox")\n                    .foregroundStyle(.blue)').replace('Text(project.name)', 'Text(project.name)\n                        .font(.headline)').replace('.padding(.vertical, 6)', '.padding(.vertical, 10)').replace('.navigationTitle("Projects")', '.navigationTitle("Workspace")\n        .overlay(alignment: .bottomTrailing) {\n            Label("Up to date", systemImage: "checkmark.circle")\n                .font(.caption)\n                .foregroundStyle(.secondary)\n                .padding()\n        }'))
(root / 'Sources/NewFeature.swift').write_text('import Foundation\n\nstruct NavigationState {\n    var selectedProject: UUID?\n    var isSidebarVisible = true\n}\n')
with (root / 'README.md').open('a') as f:
    f.write('\nKeyboard navigation keeps project switching simple.\n')
PY
  if [[ "$task_name" == example-api ]]; then
    git -C "$task_repo" switch -q develop
    git -C "$task_repo" add -- README.md
  fi
  if [[ "$task_name" == demo-dashboard ]]; then
    git -C "$task_repo" switch -q feature/ui-improvements
  fi
done
export CLANG_MODULE_CACHE_PATH="$task_root/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_root/.cache/swift"
swift build --build-system native --disable-sandbox --cache-path "$task_root/.cache/swiftpm" -c debug --product GitPier
task_bin="$(swift build --build-system native --disable-sandbox --cache-path "$task_root/.cache/swiftpm" -c debug --show-bin-path)"
cd "$task_temp"
ZDOTDIR="$task_temp/shell" GITPIER_WORKSPACE_FILE="$task_temp/workspace.json" \
  "$task_bin/GitPier" --product-screenshots --output "$task_output"
python3 "$task_root/Scripts/strip-png-metadata.py" \
  "$task_output/commit-workspace.png" "$task_output/diff-viewer.png" \
  "$task_output/integrated-terminal.png" "$task_output/repository-dashboard.png"
