#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_root="$PWD"
configuration="${CONFIGURATION:-release}"
task_config="${GITPIER_TEST_RELEASE_CONFIG:-Sources/GitPier/Resources/ReleaseConfiguration.json}"
bundle_id="${BUNDLE_IDENTIFIER:-$(python3 Scripts/release_metadata.py --config "$task_config" --field bundleIdentifier)}"
if [[ ! "$bundle_id" =~ ^[a-zA-Z][a-zA-Z0-9-]*(\.[a-zA-Z][a-zA-Z0-9-]*)+$ ]]; then
  echo "Invalid BUNDLE_IDENTIFIER" >&2; exit 1
fi
export CLANG_MODULE_CACHE_PATH="$task_root/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_root/.cache/swift"
# Regenerate every icon surface from the canonical PNG before SwiftPM copies resources.
swift Scripts/generate-branding.swift
swift build --build-system native --disable-sandbox --cache-path "$task_root/.cache/swiftpm" -c "$configuration" --product GitPier
task_bin="$(swift build --build-system native --disable-sandbox --cache-path "$task_root/.cache/swiftpm" -c "$configuration" --show-bin-path)"
mkdir -p "$task_root/dist"
task_stage="$(mktemp -d "$task_root/.cache/app-build.XXXXXX")"
trap 'rm -rf "$task_stage"' EXIT
task_app="$task_stage/GitPier.app"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
cp "$task_bin/GitPier" "$task_app/Contents/MacOS/GitPier"
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
  for task_arch in arm64 x86_64; do
    swift build --build-system native --disable-sandbox --cache-path "$task_root/.cache/swiftpm" -c "$configuration" --arch "$task_arch" --product GitPier
  done
  task_arm_bin="$(swift build --build-system native --disable-sandbox --cache-path "$task_root/.cache/swiftpm" -c "$configuration" --arch arm64 --show-bin-path)"
  task_intel_bin="$(swift build --build-system native --disable-sandbox --cache-path "$task_root/.cache/swiftpm" -c "$configuration" --arch x86_64 --show-bin-path)"
  lipo -create "$task_arm_bin/GitPier" "$task_intel_bin/GitPier" -output "$task_app/Contents/MacOS/GitPier"
fi
# AppResources resolves packaged resources inside Contents/Resources, with SwiftPM fallback for development.
for task_bundle in "$task_bin"/*.bundle; do
  [[ -d "$task_bundle" ]] || continue
  task_name="$(basename "$task_bundle")"
  rm -rf "$task_app/Contents/Resources/$task_name"
  cp -R "$task_bundle" "$task_app/Contents/Resources/$task_name"
  rm -rf "$task_app/$task_name"
done
cp "$task_config" "$task_app/Contents/Resources/GitPier_GitPier.bundle/ReleaseConfiguration.json"
task_icons="$task_root/.cache/GitPier.iconset"
rm -rf "$task_icons"
mkdir -p "$task_icons"
for task_size in 16 32 128 256 512; do
  cp "Resources/Assets.xcassets/AppIcon.appiconset/icon_${task_size}x${task_size}@1x.png" "$task_icons/icon_${task_size}x${task_size}.png"
  cp "Resources/Assets.xcassets/AppIcon.appiconset/icon_${task_size}x${task_size}@2x.png" "$task_icons/icon_${task_size}x${task_size}@2x.png"
done
task_icon_hash="$(shasum -a 256 Resources/Branding/gitpier-icon-1024.png | cut -c 1-12)"
task_icon_name="GitPier-$task_icon_hash.icns"
for task_old_icon in "$task_app/Contents/Resources"/GitPier*.icns; do
  [[ -f "$task_old_icon" ]] || continue
  rm "$task_old_icon"
done
iconutil -c icns "$task_icons" -o "$task_app/Contents/Resources/$task_icon_name"
BUNDLE_IDENTIFIER="$bundle_id" python3 Scripts/release_metadata.py --config "$task_config" --plist "$task_app/Contents/Info.plist" --icon "$task_icon_name"
# ditto preserves Sparkle's versioned links, helpers, XPC executables and permissions.
task_framework="$task_root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$task_framework" ]] || { echo "Sparkle framework was not resolved" >&2; exit 1; }
mkdir -p "$task_app/Contents/Frameworks"
ditto "$task_framework" "$task_app/Contents/Frameworks/Sparkle.framework"
python3 Scripts/sign-bundle.py "$task_app" "${CODE_SIGN_IDENTITY:--}"

cp Resources/Branding/branding-guide.md "$task_app/Contents/Resources/"
cp THIRD_PARTY_NOTICES.md "$task_app/Contents/Resources/"
cp LICENSE "$task_app/Contents/Resources/"
rm -rf "$task_app/Contents/Resources/Licenses"
cp -R Resources/Licenses "$task_app/Contents/Resources/Licenses"
codesign --force --sign "${CODE_SIGN_IDENTITY:--}" "$task_app"
codesign --verify --deep --strict "$task_app"
python3 Scripts/verify-bundle.py "$task_app" --config "$task_config" "${UNIVERSAL:-0}"
touch "$task_app"
rm -rf "$task_root/dist/GitPier.app"
mv "$task_app" "$task_root/dist/GitPier.app"
task_app="$task_root/dist/GitPier.app"
printf 'Built %s\n' "$task_app"
