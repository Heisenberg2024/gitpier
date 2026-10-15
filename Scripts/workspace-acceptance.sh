#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_mode="${1:-version140}"
case "$task_mode" in version140|full|workspace-performance) ;; *) echo 'Use version140, full or workspace-performance.' >&2; exit 1;; esac
task_output="${2:-$PWD/.cache/ui-acceptance/workspace}"
[[ -x dist/GitPier.app/Contents/MacOS/GitPier ]] || { echo 'Build GitPier.app through Scripts/build-app.sh first.' >&2; exit 1; }
mkdir -p .cache "$task_output"
task_temp="$(mktemp -d "$PWD/.cache/workspace-acceptance.XXXXXX")"
task_suffix="$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
task_bundle_id="com.heisenberg2024.gitpier.workspace-test.run-$task_suffix"
task_app="$task_temp/GitPierWorkspaceAcceptance.app"
cleanup() {
  # Only this disposable application's preference domain and bundle are removed.
  defaults delete "$task_bundle_id" >/dev/null 2>&1 || true
  rm -rf "$task_temp"
}
trap cleanup EXIT
ditto dist/GitPier.app "$task_app"
python3 - "$task_app/Contents/Info.plist" "$task_bundle_id" <<'PY'
import plistlib,sys
path,identifier=sys.argv[1:]
with open(path,'rb') as stream: info=plistlib.load(stream)
info['CFBundleIdentifier']=identifier
info['CFBundleName']='GitPier Workspace Acceptance'
info['CFBundleDisplayName']='GitPier Workspace Acceptance'
with open(path,'wb') as stream: plistlib.dump(info,stream)
PY
# Keep the original resource config, so the changed runtime identity cannot start production updating.
python3 Scripts/sign-bundle.py "$task_app" -
codesign --force --sign - "$task_app"
codesign --verify --deep --strict "$task_app"
printf '%s\n' "$task_bundle_id" > "$task_output/bundle-id.txt"
printf '%s\n' "$task_app" > "$task_output/application-path.txt"
if [[ "$task_mode" == workspace-performance ]]; then export GITPIER_PERFORMANCE_TRACE=1; fi
if [[ "$task_mode" == full ]]; then export GITPIER_UI_ACCEPTANCE_SCOPE=""; else export GITPIER_UI_ACCEPTANCE_SCOPE="$task_mode"; fi
GITPIER_UI_ACCEPTANCE_EXECUTABLE="$task_app/Contents/MacOS/GitPier" Scripts/ui-acceptance.sh "$task_output"
