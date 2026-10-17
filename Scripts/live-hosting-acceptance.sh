#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_base="$PWD/.cache/v151/oauth-live"
mkdir -p "$task_base"
chmod 700 "$task_base"
if [[ $# == 0 ]]; then
  task_root="$(mktemp -d "$task_base/run-XXXXXXXX")"
  task_suffix="$(basename "$task_root" | tr '[:upper:]' '[:lower:]')"
  task_identifier="com.heisenberg2024.gitpier.workspace-test.live-$task_suffix"
  [[ -x dist/GitPier.app/Contents/MacOS/GitPier ]] || { echo 'Build the final application first.' >&2; exit 1; }
  ditto dist/GitPier.app "$task_root/GitPierOAuthAcceptance.app"
  python3 - "$task_root/GitPierOAuthAcceptance.app/Contents/Info.plist" "$task_identifier" <<'PY'
import plistlib,sys
path,identifier=sys.argv[1:]
with open(path,'rb') as stream: value=plistlib.load(stream)
value['CFBundleIdentifier']=identifier
value['CFBundleName']='GitPier Isolated OAuth Acceptance'
value['CFBundleDisplayName']='GitPier Isolated OAuth Acceptance'
with open(path,'wb') as stream: plistlib.dump(value,stream)
PY
  python3 Scripts/sign-bundle.py "$task_root/GitPierOAuthAcceptance.app" -
  codesign --force --sign - "$task_root/GitPierOAuthAcceptance.app"
  codesign --verify --deep --strict "$task_root/GitPierOAuthAcceptance.app"
  printf '%s\n' "$task_identifier" > "$task_root/bundle-id.txt"
else
  task_root="$(cd "$1" && pwd)"
  [[ "$task_root" == "$task_base"/run-* && -f "$task_root/bundle-id.txt" ]] || { echo 'Use an existing isolated run directory from this workflow.' >&2; exit 1; }
fi
[[ ! -e "$task_root/finish" ]] || { echo 'This acceptance run is finished. Start a fresh run.' >&2; exit 1; }
printf 'Isolated OAuth application: %s\n' "$task_root"
# Persistent across full process exits; no production workspace, preferences or credential items are used.
# This does not register or replace the gitpier:// default handler.
GITPIER_WORKSPACE_FILE="$task_root/workspace.json" GITPIER_UI_ACCEPTANCE_SCOPE=hosting-live \
  "$task_root/GitPierOAuthAcceptance.app/Contents/MacOS/GitPier" --ui-acceptance
