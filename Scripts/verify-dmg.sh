#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_dmg="${1:?Usage: verify-dmg.sh image.dmg}"
task_config="${GITPIER_TEST_RELEASE_CONFIG:-Sources/GitPier/Resources/ReleaseConfiguration.json}"
hdiutil verify "$task_dmg"
task_temp="$(mktemp -d "$PWD/.cache/dmg-check.XXXXXX")"
task_mount=""
cleanup() {
  if [[ -n "$task_mount" ]]; then hdiutil detach "$task_mount" >/dev/null || true; fi
  rm -rf "$task_temp"
}
trap cleanup EXIT
hdiutil attach -readonly -nobrowse -noautoopen -plist "$task_dmg" > "$task_temp/mount.plist"
task_mount="$(python3 - "$task_temp/mount.plist" <<'PY'
import plistlib, sys
mounts=[e['mount-point'] for e in plistlib.load(open(sys.argv[1], 'rb'))['system-entities'] if 'mount-point' in e]
assert len(mounts)==1
print(mounts[0])
PY
)"
[[ -L "$task_mount/Applications" && "$(readlink "$task_mount/Applications")" == /Applications ]]
[[ -s "$task_mount/.background/background.tiff" && -s "$task_mount/.DS_Store" ]]
python3 - "$task_mount" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
assert {x.name for x in p.iterdir() if not x.name.startswith('.')} == {'GitPier.app', 'Applications'}, 'Unexpected installer content'
PY
python3 Scripts/verify-bundle.py "$task_mount/GitPier.app" --config "$task_config" 1
hdiutil detach "$task_mount" >/dev/null
task_mount=""
printf 'DMG structure, universal bundle and signature verified\n'
