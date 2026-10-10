# Development

## Requirements

- macOS 14 or later; Xcode 16 or later with a Swift 6 toolchain and command-line tools.
- System Git, SSH, and an installed shell.
- Swift Package Manager; commit `Package.resolved` for reproducible application dependencies.

## Build and test

Run these scripts from the repository root:

```bash
Scripts/build-app.sh
Scripts/test.sh
```

The build script produces `dist/GitPier.app` for the current architecture. `CONFIGURATION=debug` selects a Debug build. `UNIVERSAL=1 Scripts/package-release.sh` creates a local arm64 + x86_64 archive and SHA256 file. `BUNDLE_IDENTIFIER` and `CODE_SIGN_IDENTITY` can set an owner-controlled bundle ID and signing identity. The default ID is an example and the default signature is ad-hoc; packaging does not notarize or publish anything.

Scripts keep build caches in `.cache` and use SwiftPM's native build engine. The engine may report a deprecation warning on newer toolchains. Do not bypass hooks, signing, or transport verification to work around build or Git failures.

Core tests create temporary Git repositories. Keychain tests use synthetic entries and remove them. Native UI / PTY acceptance requires a logged-in macOS session:

```bash
Scripts/ui-acceptance.sh
```

Captures and execution records default to `.cache/ui-acceptance`. `Scripts/performance.sh` generates a marked disposable workload and writes measurements to `.cache/performance/latest`. These results are local artifacts, not public compatibility guarantees.

## Product images

`Scripts/product-screenshots.sh` builds the Debug application and captures its existing native components using isolated, temporary demonstration repositories. This entry point is compiled only in Debug builds. It uses no real accounts or remotes, displays relative fixture paths, and uses a controlled shell prompt. Inspect every image before publishing it. Only the four approved PNGs belong in `docs/screenshots`.

`Resources/Branding/gitpier-icon-1024.png` is the canonical raster icon, with transparency outside its rounded tile. `Scripts/generate-branding.swift` derives the AppIcon sizes and SwiftPM resource from it; it does not recreate earlier vector concepts. Both image workflows call `Scripts/strip-png-metadata.py` to remove text, EXIF, and timestamps while preserving pixels and color profiles.

## Public file boundary

Keep source, tests, package manifests and lockfile, reviewed resources, build scripts, CI, and public documentation. `.gitignore` excludes build output, local app configuration, secret-bearing files, caches, and internal notes under `.local`. Review environment examples individually. `PROJECT_MEMORY.md` is local working guidance and is intentionally excluded; `AGENTS.md` contains portable contributor guidance.

Before publishing, inspect both current files and Git history with a local secret scanner. Ignore rules do not remove previously tracked files or secrets from history. Do not rewrite history or publish without the owner's authorization. GitPier uses the [MIT License](../LICENSE); retain the [third-party notices](../THIRD_PARTY_NOTICES.md) and dependency license texts when distributing the application. GitPier's copyright holder is Heisenberg2024 (2026); keep LICENSE and the build script's copyright metadata consistent. Distribution identity, Developer ID signing, notarization, and public release still require the owner's authorization.
