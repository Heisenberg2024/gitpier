# Development

## Requirements

- macOS 14 or later; Xcode 16 or later with a Swift 6 toolchain and command-line tools.
- System Git, SSH, and an installed shell.
- Swift Package Manager; commit `Package.resolved` for reproducible application dependencies.
- Python 3.9+ for release metadata and verification (standard library only); macOS `hdiutil`, `codesign`, `osascript` and Finder for local installer acceptance.

## Build and test

Run these scripts from the repository root:

```bash
Scripts/build-app.sh
Scripts/test.sh
```

The build script produces `dist/GitPier.app` for the current architecture. `CONFIGURATION=debug` selects a Debug build. `UNIVERSAL=1 Scripts/build-app.sh` builds both architectures; `Scripts/package-release.sh --unsigned-candidate` produces a local DMG candidate with SHA256. `BUNDLE_IDENTIFIER` and `CODE_SIGN_IDENTITY` can set an owner-controlled bundle ID and signing identity. The default ID is `com.heisenberg2024.gitpier` and the default signature is ad-hoc; packaging does not notarize or publish anything.

Scripts keep build caches in `.cache` and use SwiftPM's native build engine. The engine may report a deprecation warning on newer toolchains. Do not bypass hooks, signing, or transport verification to work around build or Git failures.

Core tests create temporary Git repositories. Keychain tests use synthetic entries and remove them. Native UI / PTY acceptance requires a logged-in macOS session:

```bash
Scripts/ui-acceptance.sh
```

For the rejected-push workflow only, run `GITPIER_UI_ACCEPTANCE_SCOPE=push-recovery Scripts/ui-acceptance.sh`. It checks the English and Simplified Chinese native alert buttons, cancellation, successful merge/push and conflict resolution against disposable local remotes, and captures only the test alerts.

Use `GITPIER_UI_ACCEPTANCE_SCOPE=version110 Scripts/ui-acceptance.sh` for native update-delegate/gate registration, deferred install callbacks, cancellation of reviewed destructive actions, full-history layout, rapid stash previews and bilingual About captures.

Use `GITPIER_UI_ACCEPTANCE_SCOPE=conflicts Scripts/ui-acceptance.sh` for the built-in conflict editor. It uses disposable local remotes to verify native text input, block-choice button actions, drafts across files, save/review cancellation, protected merge commits and the original push destination. English and Simplified Chinese captures contain only the fixture window.

App-modal `NSAlert.runModal()` is separate from SwiftUI's attached sheets. Default conflict acceptance checks its alert configuration without displaying a blocking quit dialog. Set `GITPIER_UI_ACCEPTANCE_INTERACTIVE_QUIT=1` only for an interactive run and press Cancel on the actual quit alert; do not infer a successful click from a proxy button or an empty `attachedSheet`.

For scrollbar coverage only, run `GITPIER_UI_ACCEPTANCE_SCOPE=scrollbars Scripts/ui-acceptance.sh`. It checks application pages and all eight Settings tabs in both languages, native thumb dragging and fading, dynamically replaced SwiftUI scroll views, document resizing/replacement, compact viewports, Diff header clipping and terminal scrollback/alternate screens. The full UI/PT​Y acceptance also includes these checks.

Captures and execution records default to `.cache/ui-acceptance`. `Scripts/performance.sh` generates a marked disposable workload and writes measurements to `.cache/performance/latest`. These results are local artifacts, not public compatibility guarantees.

## Product images

`Scripts/product-screenshots.sh` builds the Debug application and captures its existing native components using isolated, temporary demonstration repositories. This entry point is compiled only in Debug builds. It uses no real accounts or remotes, displays relative fixture paths, and uses a controlled shell prompt. Inspect every image before publishing it. Only the four approved PNGs belong in `docs/screenshots`.

`Resources/Branding/gitpier-icon-1024.png` is the canonical raster icon, with transparency outside its rounded tile. `Scripts/build-app.sh` regenerates the AppIcon sizes and SwiftPM resource before every build, preserving the master image's exact bytes. It creates a fresh iconset and uses a content-stamped ICNS filename in Info.plist; increment the bundle build number when replacing a packaged application. `AppResources.applicationIcon` is shared by the sidebar, Dock, and About panel, whose icon is passed explicitly. Both image workflows call `Scripts/strip-png-metadata.py` to remove text, EXIF, and timestamps from generated outputs while preserving pixels and color profiles.

## Public file boundary

Keep source, tests, package manifests and lockfile, reviewed resources, build scripts, CI, and public documentation. `.gitignore` excludes build output, local app configuration, secret-bearing files, caches, and internal notes under `.local`. Review environment examples individually. `PROJECT_MEMORY.md` is local working guidance and is intentionally excluded; `AGENTS.md` contains portable contributor guidance.

Before publishing, inspect both current files and Git history with a local secret scanner. Ignore rules do not remove previously tracked files or secrets from history. Do not rewrite history or publish without the owner's authorization. GitPier uses the [MIT License](../LICENSE); retain the [third-party notices](../THIRD_PARTY_NOTICES.md) and dependency license texts when distributing the application. GitPier's copyright holder is Heisenberg2024 (2026); keep LICENSE and the build script's copyright metadata consistent. Distribution identity, Developer ID signing, notarization, and future public releases still require the owner's authorization.

## DMG and Sparkle release preparation

The v1.1.0 work is unreleased. Maintain production versions only in `Sources/GitPier/Resources/ReleaseConfiguration.json`; increase `build` for every distributed build. Keep the production bundle identifier stable. Empty `publicEDKey` means updates are disabled and production release signing refuses to run.

```bash
Scripts/test.sh
python3 Scripts/test-release-tools.py
UNIVERSAL=1 Scripts/build-app.sh
Scripts/package-dmg.sh
Scripts/verify-dmg.sh dist/GitPier-1.1.0-macos-universal.dmg
```

`package-dmg.sh` refuses to overwrite an existing image and requires a logged-in Finder session with Automation permission. The Finder-only layout is in `Scripts/layout-dmg.applescript`: a 720 × 448-point outer window (approximately 720 × 420-point content), 104-point real icons at (190,196) and (530,196), and /Applications symlink. `Scripts/generate-installer-background.swift` regenerates `Resources/Installer/background@2x.png` and `background.tiff` using AppKit; the TIFF includes 1x/2x representations. No external assets, false icons or installer programs are used. Visually inspect the mounted Finder window separately from the structural checks and copy to an isolated installation location for launch acceptance.

Initialize the production signing key only as an explicit owner action:

```bash
Scripts/update-keys.sh init
Scripts/update-keys.sh public
Scripts/update-keys.sh export /secure/offline/location/GitPier-update-key.secret
```

Paste only the public key into `publicEDKey`. The official Sparkle tool stores the private key in the login Keychain under account `GitPier-production`. Export uses mode 0600, refuses repository paths and existing files; transfer the backup to encrypted offline storage and remove the temporary copy. Never put private key contents in command arguments, logs, source or CI. Restore with `Scripts/update-keys.sh import /secure/backup/GitPier-update-key.secret` on an owner-controlled machine and verify the public key again. Without Developer ID, losing this key can require a manually trusted replacement installation; do not assume automatic key rotation is possible.

For an encrypted local backup, create a mode-0700 directory outside the repository and invoke `swift Scripts/backup-update-key.swift create /secure/backup/GitPier-update-key.dmg "$PWD"`. It creates an AES-256 disk image, exports the seed directly into that encrypted volume, enforces mode 0600, and verifies it by read-only remount, public-key comparison and a signing proof. The image password is generated in memory and stored separately in the login Keychain under service `com.heisenberg2024.gitpier.signing-backup`; the image's `.json` sidecar identifies its account and hash without containing secrets. Verify later with the same command using `verify` instead of `create`. The tool refuses overwrite and never prints passwords or private keys. A local backup does not survive loss of the machine unless both the image and its unlock password are copied to separate secure offline storage. Use Keychain Access to retrieve the password, mount the image, and import `GitPier-update-key.secret` only on an owner-controlled recovery machine.

After reviewing release notes and completing local acceptance:

```bash
Scripts/sign-release.sh dist/GitPier-1.1.0-macos-universal.dmg reviewed-release-notes.md
# Or perform the complete build/test/package/sign pipeline with a new output path:
Scripts/package-release.sh reviewed-release-notes.md
```

Signing validates the Keychain public key, final DMG, EdDSA signature against the embedded public key, version/length/fixed download URL, signed appcast and unchanged DMG hash. Sparkle's official `generate_appcast` embeds the reviewed notes and signs the feed. Do not edit the feed/notes or DMG after signing. Copy only the DMG, .sha256 and appcast.xml into a future GitHub draft; no private keys, test fixtures or unsigned candidates. The scripts never upload or publish.

Before release, confirm a clean approved source commit and passing CI, review the bilingual notes with the owner, create a draft only with authorization, upload all three assets and compare remote sizes/hashes. Publish only after authorization. Verify the latest feed redirects and a real old-version update after publication; retain historical ZIP releases unchanged.

## Isolated updater acceptance

The production key is not used for tests. `Scripts/serve-update-test.py` serves only a fixture directory on a random loopback port. `Scripts/prepare-update-test.py` creates separate Bundle IDs and a disposable CryptoKit Ed25519 seed under ignored `.cache/update-acceptance`; workspace location is embedded in test-only Info.plist so Sparkle relaunch cannot fall back to the user's real workspace. Runtime data and the controlled shell are created under a dedicated `/private/tmp/GitPier-update-acceptance-*` directory (recorded in `runtime-root.txt`) to avoid Documents privacy prompts during launchd relaunch; keep test repositories there too. No privacy permission is relaxed.

```bash
python3 Scripts/serve-update-test.py .cache/update-acceptance/example/server
# In another terminal, after the server starts:
python3 Scripts/prepare-update-test.py .cache/update-acceptance/example
open .cache/update-acceptance/example/installed/GitPier.app
```

Use Check for Updates in the test app, confirm installation and verify build 20 → 21, relaunch, workspace/draft preservation and framework loading. Also test invalid signed feeds, missing/invalid DMG signatures, altered archives, failed downloads, cancellation, active Git work, unsaved conflict drafts and read-only-DMG launch. Prefer isolated installation locations. When verifying /Applications, use a distinct filename plus the isolated test Bundle ID, preserve any existing GitPier.app, and remove only the verified test copy afterwards. Quit test apps, stop the loopback server, remove disposable private-key files and retain only redacted acceptance evidence. A mounted DMG or readable appcast alone does not prove a successful self-update.

CI runs unit tests, metadata/security gate tests, native bundle builds and `Scripts/test-dmg-structure.sh`, which creates and deletes a clearly temporary image without claiming Finder layout. It must not generate production keys, publish releases or claim Finder visuals / actual self-updates in a headless job.

Failure cases can be prepared with `python3 Scripts/update-test-scenario.py .cache/update-acceptance/example invalid-signature` (or `invalid-feed`, `tampered-dmg`, `download-failure`, `restore`). These commands only modify the isolated loopback fixture. AppKit/Sparkle language preferences are stored only in the application's own defaults domain and follow the selected GitPier language after restart.

Example draft creation, only after explicit authorization and source/asset review:

```bash
gh release create v1.1.0 --draft --target "$APPROVED_COMMIT_SHA" --title "GitPier v1.1.0" --notes-file "$REVIEWED_NOTES_FILE" dist/GitPier-1.1.0-macos-universal.dmg dist/GitPier-1.1.0-macos-universal.dmg.sha256 dist/appcast.xml
```

`APPROVED_COMMIT_SHA` and `REVIEWED_NOTES_FILE` must identify the owner's approved commit and final notes. This command is documentation, not an automatic publishing step; verify draft assets and CI before separately approving publication.
