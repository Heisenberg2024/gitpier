#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_version="$(python3 Scripts/release_metadata.py --field version)"
task_candidate=0
if [[ "${1:-}" == --unsigned-candidate ]]; then
  task_candidate=1
else
  [[ -n "$(python3 Scripts/release_metadata.py --field publicEDKey)" ]] || {
    echo 'Configure the production key first, or explicitly use --unsigned-candidate for local acceptance.' >&2; exit 1;
  }
  [[ -f "${1:-}" ]] || { echo 'Usage: package-release.sh reviewed-release-notes.md | --unsigned-candidate' >&2; exit 1; }
fi
Scripts/test.sh
UNIVERSAL=1 Scripts/build-app.sh
Scripts/package-dmg.sh
if [[ "$task_candidate" == 0 ]]; then
  Scripts/sign-release.sh "dist/GitPier-$task_version-macos-universal.dmg" "$1"
else
  printf 'Local DMG candidate without a signed appcast. Do not publish this asset as a signed update.\n'
fi
