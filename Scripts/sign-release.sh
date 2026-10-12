#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_dmg="${1:?Usage: sign-release.sh final.dmg release-notes.md}"
task_notes="${2:?Provide reviewed release notes}"
task_version="$(python3 Scripts/release_metadata.py --field version)"
task_public="$(python3 Scripts/release_metadata.py --field publicEDKey)"
[[ -n "$task_public" ]] || { echo 'Production publicEDKey is missing; signing and appcast generation are disabled.' >&2; exit 1; }
[[ "$(basename "$task_dmg")" == "GitPier-$task_version-macos-universal.dmg" ]] || { echo 'Unexpected release filename' >&2; exit 1; }
[[ -f "$task_notes" ]] || { echo 'Missing release notes' >&2; exit 1; }
task_bin="$PWD/.build/artifacts/sparkle/Sparkle/bin"
task_actual_public="$("$task_bin/generate_keys" --account GitPier-production -p)"
[[ "$task_actual_public" == "$task_public" ]] || { echo 'Keychain key does not match the configured production public key.' >&2; exit 1; }
Scripts/verify-dmg.sh "$task_dmg"
task_dir="$(cd "$(dirname "$task_dmg")" && pwd)"
[[ ! -e "$task_dir/appcast.xml" ]] || { echo 'Refusing to overwrite an existing appcast.' >&2; exit 1; }
task_temp="$(mktemp -d "$PWD/.cache/release-sign.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT
cp "$task_dmg" "$task_temp/"
task_archive="$task_temp/$(basename "$task_dmg")"
cp "$task_notes" "${task_archive%.dmg}.md"
task_before="$(shasum -a 256 "$task_dmg" | cut -d ' ' -f 1)"
task_signature="$("$task_bin/sign_update" --account GitPier-production -p "$task_archive")"
CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang" swift Scripts/verify-update-signature.swift "$task_public" "$task_signature" "$task_archive"
"$task_bin/generate_appcast" --account GitPier-production --maximum-deltas 0 --embed-release-notes \
  --download-url-prefix "https://github.com/Heisenberg2024/gitpier/releases/download/v$task_version/" \
  --full-release-notes-url "https://github.com/Heisenberg2024/gitpier/releases/tag/v$task_version" "$task_temp"
"$task_bin/sign_update" --account GitPier-production --verify "$task_temp/appcast.xml"
python3 Scripts/verify-release.py "$task_archive" "$task_temp/appcast.xml" "$task_signature"
[[ "$task_before" == "$(shasum -a 256 "$task_dmg" | cut -d ' ' -f 1)" ]] || { echo 'DMG changed during signing' >&2; exit 1; }
cp "$task_temp/appcast.xml" "$task_dir/appcast.xml"
(cd "$task_dir" && shasum -a 256 "$(basename "$task_dmg")" > "$(basename "$task_dmg").sha256")
printf 'Signed local release assets: %s\nNo release has been uploaded or published.\n' "$task_dir"
