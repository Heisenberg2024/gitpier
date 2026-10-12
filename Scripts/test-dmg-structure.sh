#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Deliberately a temporary structural fixture, never a formal installer without Finder layout.
task_temp="$(mktemp -d "$PWD/.cache/dmg-structure-test.XXXXXX")"
task_mount=""
cleanup() {
  if [[ -n "$task_mount" ]]; then hdiutil detach "$task_mount" >/dev/null || true; fi
  rm -rf "$task_temp"
}
trap cleanup EXIT
mkdir -p "$task_temp/stage/.background"
ditto dist/GitPier.app "$task_temp/stage/GitPier.app"
ln -s /Applications "$task_temp/stage/Applications"
cp Resources/Installer/background.tiff "$task_temp/stage/.background/"
hdiutil create -srcfolder "$task_temp/stage" -volname 'GitPier Structure Test' -fs HFS+ -format ULFO "$task_temp/fixture.dmg" >/dev/null
hdiutil verify "$task_temp/fixture.dmg" >/dev/null
hdiutil attach -readonly -nobrowse -noautoopen -plist "$task_temp/fixture.dmg" > "$task_temp/mount.plist"
task_mount="$(python3 - "$task_temp/mount.plist" <<'PY'
import plistlib,sys
p=[e['mount-point'] for e in plistlib.load(open(sys.argv[1],'rb'))['system-entities'] if 'mount-point' in e]
assert len(p)==1
print(p[0])
PY
)"
[[ -L "$task_mount/Applications" && "$(readlink "$task_mount/Applications")" == /Applications ]]
[[ -s "$task_mount/.background/background.tiff" ]]
python3 Scripts/verify-bundle.py "$task_mount/GitPier.app"
hdiutil detach "$task_mount" >/dev/null
task_mount=""
printf 'Temporary DMG structure passed. Finder visuals, drag installation and self-update are separate GUI checks.\n'
