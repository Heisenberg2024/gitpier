#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/disk-image-helpers.sh
# Deliberately a temporary structural fixture, never a formal installer without Finder layout.
task_temp="$(mktemp -d "$PWD/.cache/dmg-structure-test.XXXXXX")"
task_mount=""
cleanup() {
  if [[ -n "$task_mount" ]] && python3 -c 'import os,sys; sys.exit(0 if os.path.ismount(sys.argv[1]) else 1)' "$task_mount"; then
    if ! hdiutil detach "$task_mount"; then
      echo "Could not detach this task's image; preserving $task_temp for diagnosis." >&2
      return 1
    fi
  fi
  rm -rf "$task_temp"
}
trap cleanup EXIT
mkdir -p "$task_temp/stage/.background"
ditto dist/GitPier.app "$task_temp/stage/GitPier.app"
ln -s /Applications "$task_temp/stage/Applications"
cp Resources/Installer/background.tiff "$task_temp/stage/.background/"
gitpier_create_temporary_dmg "$task_temp/stage" "$task_temp/fixture.dmg" "GitPier Test ${task_temp##*.}"
hdiutil verify "$task_temp/fixture.dmg" >/dev/null
task_mount="$task_temp/mount"
mkdir "$task_mount"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$task_mount" -plist "$task_temp/fixture.dmg" > "$task_temp/mount.plist"
python3 - "$task_temp/mount.plist" "$task_mount" <<'PY'
import plistlib,sys
p=[e['mount-point'] for e in plistlib.load(open(sys.argv[1],'rb'))['system-entities'] if 'mount-point' in e]
assert p == [sys.argv[2]]
PY
[[ -L "$task_mount/Applications" && "$(readlink "$task_mount/Applications")" == /Applications ]]
[[ -s "$task_mount/.background/background.tiff" ]]
python3 Scripts/verify-bundle.py "$task_mount/GitPier.app"
hdiutil detach "$task_mount" >/dev/null
task_mount=""
printf 'Temporary DMG structure passed. Finder visuals, drag installation and self-update are separate GUI checks.\n'
