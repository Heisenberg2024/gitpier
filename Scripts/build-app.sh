#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_root="$PWD"
configuration="${CONFIGURATION:-release}"
bundle_id="${BUNDLE_IDENTIFIER:-com.example.gitpier}"
if [[ ! "$bundle_id" =~ ^[a-zA-Z][a-zA-Z0-9-]*(\.[a-zA-Z][a-zA-Z0-9-]*)+$ ]]; then
  echo "Invalid BUNDLE_IDENTIFIER" >&2; exit 1
fi
export CLANG_MODULE_CACHE_PATH="$task_root/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_root/.cache/swift"
# Regenerate every icon surface from the canonical PNG before SwiftPM copies resources.
swift Scripts/generate-branding.swift
swift build --build-system native --disable-sandbox --cache-path "$task_root/.cache/swiftpm" -c "$configuration" --product GitPier
task_bin="$(swift build --build-system native --disable-sandbox --cache-path "$task_root/.cache/swiftpm" -c "$configuration" --show-bin-path)"
task_app="$task_root/dist/GitPier.app"
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
cat > "$task_app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>GitPier</string>
<key>CFBundleDisplayName</key><string>GitPier</string>
<key>CFBundleExecutable</key><string>GitPier</string>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.2</string>
<key>CFBundleVersion</key><string>13</string>
<key>CFBundleIconFile</key><string>$task_icon_name</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Copyright (c) 2026 Heisenberg2024. MIT License.</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
</dict></plist>
PLIST
cp Resources/Branding/branding-guide.md "$task_app/Contents/Resources/"
cp THIRD_PARTY_NOTICES.md "$task_app/Contents/Resources/"
cp LICENSE "$task_app/Contents/Resources/"
rm -rf "$task_app/Contents/Resources/Licenses"
cp -R Resources/Licenses "$task_app/Contents/Resources/Licenses"
codesign --force --sign "${CODE_SIGN_IDENTITY:--}" "$task_app"
codesign --verify --strict "$task_app"
touch "$task_app"
printf 'Built %s\n' "$task_app"
