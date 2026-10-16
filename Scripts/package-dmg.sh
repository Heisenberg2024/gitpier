#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_config="${GITPIER_TEST_RELEASE_CONFIG:-Sources/GitPier/Resources/ReleaseConfiguration.json}"
task_version="$(python3 Scripts/release_metadata.py --config "$task_config" --field version)"
task_app="${1:-dist/GitPier.app}"
task_dmg="${2:-dist/GitPier-$task_version-macos-universal.dmg}"
[[ "$task_dmg" == *.dmg ]] || { echo 'Output must end in .dmg' >&2; exit 1; }
[[ ! -e "$task_dmg" ]] || { echo "Refusing to overwrite $task_dmg; choose a new output path." >&2; exit 1; }
[[ -n "$(pgrep -x Finder)" ]] || { echo 'A logged-in Finder GUI session is required for the installer layout.' >&2; exit 1; }
python3 Scripts/verify-bundle.py "$task_app" --config "$task_config" 1
task_temp="$(mktemp -d "$PWD/.cache/dmg-build.XXXXXX")"
task_mount=""
task_volume_name="GitPier-Installer-$(/usr/bin/uuidgen)"
detach_task_image() {
  local task_owned_device
  task_owned_device="$(python3 - "$task_temp/writable.dmg" <<'PY'
from pathlib import Path
import plistlib, re, subprocess, sys
expected=Path(sys.argv[1]).resolve()
images=plistlib.loads(subprocess.check_output(['hdiutil', 'info', '-plist']))['images']
owned=[image for image in images if Path(image.get('image-path', '')).resolve() == expected]
assert len(owned) <= 1
if owned:
    roots=set()
    for entity in owned[0]['system-entities']:
        if 'dev-entry' not in entity:
            continue
        match=re.fullmatch(r'(/dev/disk[0-9]+)(?:s[0-9]+)*', entity['dev-entry'])
        assert match
        roots.add(match[1])
    assert len(roots) == 1
    print(next(iter(roots)))
PY
)" || return 1
  if [[ -n "$task_owned_device" ]]; then hdiutil detach "$task_owned_device" >/dev/null; fi
}
cleanup() {
  if ! detach_task_image; then
    echo "Unable to detach this task's image; preserving $task_temp" >&2
    return
  fi
  rm -rf "$task_temp"
}
trap cleanup EXIT
mkdir -p "$task_temp/stage/.background" "$(dirname "$task_dmg")"
ditto "$task_app" "$task_temp/stage/GitPier.app"
ln -s /Applications "$task_temp/stage/Applications"
cp Resources/Installer/background.tiff "$task_temp/stage/.background/"
hdiutil create -ov -srcfolder "$task_temp/stage" -volname "$task_volume_name" -fs HFS+ -format UDRW "$task_temp/writable.dmg" >/dev/null
hdiutil attach -readwrite -nobrowse -noautoopen -plist "$task_temp/writable.dmg" > "$task_temp/mount.plist"
task_mount="$(python3 - "$task_temp/mount.plist" <<'PY'
import plistlib, sys
mounts=[e['mount-point'] for e in plistlib.load(open(sys.argv[1], 'rb'))['system-entities'] if 'mount-point' in e]
assert len(mounts)==1
print(mounts[0])
PY
)"
osascript Scripts/layout-dmg.applescript "$task_mount" "$task_volume_name"
# Finder persists .DS_Store asynchronously, exclusively inside this temporary image.
for task_attempt in {1..20}; do
  [[ -s "$task_mount/.DS_Store" ]] && break
  sleep 0.25
done
[[ -s "$task_mount/.DS_Store" ]] || { echo 'Finder did not persist the installer layout.' >&2; exit 1; }
sync
# Finder disk names are ambiguous when an older installer is open. Layout uses
# a private volume name, then restores the public name before final conversion.
# The mount path may change on rename; revalidate the image identity before detach.
diskutil renameVolume "$task_mount" GitPier >/dev/null
detach_task_image
task_mount=""
hdiutil convert "$task_temp/writable.dmg" -format ULFO -o "$task_temp/final.dmg" >/dev/null
Scripts/verify-dmg.sh "$task_temp/final.dmg"
mv "$task_temp/final.dmg" "$task_dmg"
(cd "$(dirname "$task_dmg")" && shasum -a 256 "$(basename "$task_dmg")" > "$(basename "$task_dmg").sha256")
printf 'DMG ready: %s (Finder visual inspection is a separate acceptance step)\n' "$task_dmg"
