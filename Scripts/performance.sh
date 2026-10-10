#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_root="$PWD"
task_temp="$(mktemp -d "${TMPDIR:-/tmp}/GitPier-performance.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT
python3 Scripts/performance-fixture.py "$task_temp"
Scripts/build-app.sh
GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GITPIER_PERFORMANCE_TRACE=1 ZDOTDIR="$task_temp/shell" \
  GITPIER_WORKSPACE_FILE="$task_temp/workspace.json" \
  "$task_root/dist/GitPier.app/Contents/MacOS/GitPier" --performance-acceptance \
  --repository "$task_temp/repository" --output "${1:-$task_root/.cache/performance/latest}"
