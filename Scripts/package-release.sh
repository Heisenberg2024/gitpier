#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
Scripts/build-app.sh
task_archive="dist/GitPier-1.0.3-macos.zip"
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
  task_archive="dist/GitPier-1.0.3-macos-universal.zip"
fi
ditto -c -k --sequesterRsrc --keepParent dist/GitPier.app "$task_archive"
shasum -a 256 "$task_archive" > "$task_archive.sha256"
printf 'Local archive: %s/%s\n' "$PWD" "$task_archive"
