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
cleanup() {
  if [[ -n "$task_mount" ]]; then hdiutil detach "$task_mount" >/dev/null || true; fi
  rm -rf "$task_temp"
}
trap cleanup EXIT
mkdir -p "$task_temp/stage/.background" "$(dirname "$task_dmg")"
ditto "$task_app" "$task_temp/stage/GitPier.app"
ln -s /Applications "$task_temp/stage/Applications"
cp Resources/Installer/background.tiff "$task_temp/stage/.background/"
hdiutil create -ov -srcfolder "$task_temp/stage" -volname GitPier -fs HFS+ -format UDRW "$task_temp/writable.dmg" >/dev/null
hdiutil attach -readwrite -nobrowse -noautoopen -plist "$task_temp/writable.dmg" > "$task_temp/mount.plist"
task_mount="$(python3 - "$task_temp/mount.plist" <<'PY'
import plistlib, sys
mounts=[e['mount-point'] for e in plistlib.load(open(sys.argv[1], 'rb'))['system-entities'] if 'mount-point' in e]
assert len(mounts)==1
print(mounts[0])
PY
)"
osascript Scripts/layout-dmg.applescript "$task_mount"
# Finder persists .DS_Store asynchronously, exclusively inside this temporary image.
for task_attempt in {1..20}; do
  [[ -s "$task_mount/.DS_Store" ]] && break
  sleep 0.25
done
[[ -s "$task_mount/.DS_Store" ]] || { echo 'Finder did not persist the installer layout.' >&2; exit 1; }
sync
hdiutil detach "$task_mount" >/dev/null
task_mount=""
hdiutil convert "$task_temp/writable.dmg" -format ULFO -o "$task_temp/final.dmg" >/dev/null
Scripts/verify-dmg.sh "$task_temp/final.dmg"
mv "$task_temp/final.dmg" "$task_dmg"
(cd "$(dirname "$task_dmg")" && shasum -a 256 "$(basename "$task_dmg")" > "$(basename "$task_dmg").sha256")
printf 'DMG ready: %s (Finder visual inspection is a separate acceptance step)\n' "$task_dmg"
