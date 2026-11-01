#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_root="$PWD"
task_temp="$(mktemp -d "${TMPDIR:-/tmp}/GitPier-performance.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT
python3 Scripts/performance-fixture.py "$task_temp"
if [[ -n "${GITPIER_PERFORMANCE_EXECUTABLE:-}" ]]; then
  [[ -x "$GITPIER_PERFORMANCE_EXECUTABLE" ]] || { echo 'The performance executable is missing.' >&2; exit 1; }
else
  Scripts/build-app.sh
fi
GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GITPIER_PERFORMANCE_TRACE=1 ZDOTDIR="$task_temp/shell" \
  GITPIER_WORKSPACE_FILE="$task_temp/workspace.json" \
  "${GITPIER_PERFORMANCE_EXECUTABLE:-${GITPIER_APP_OUTPUT_DIR:-$task_root/dist}/GitPier.app/Contents/MacOS/GitPier}" --performance-acceptance \
  --repository "$task_temp/repository" --output "${1:-$task_root/.cache/performance/latest}"
