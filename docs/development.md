# Development

## Requirements

- macOS 14 or later; Xcode 16 or later with a Swift 6 toolchain and command-line tools.
- System Git, SSH, and an installed shell.
- Git LFS is optional for the LFS page. Install/configure it separately; GitPier never installs the tool, global filters or repository hooks. No new SwiftPM dependency is introduced.
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

For the v1.3 development workflows, run `GITPIER_UI_ACCEPTANCE_SCOPE=version130 Scripts/ui-acceptance.sh`. Rebase tests exercise typed plans, native conflicts, restart/message recovery, hooks/signing rejection and stale HEAD/Index/todo/file protection in disposable repositories. Hosted screenshots supplement actual visible GUI interaction; they do not establish real drag or confirmation behavior. Native Git may require an explicit recovery commit after a signing/hook failure; keep its diagnosis, use the repository terminal or reviewed Abort, and never disable signing to make acceptance pass.

The temporary DMG structural test uses a unique staging directory, volume and mount point. Only an exact `hdiutil: create failed - Resource busy` retries (three attempts; one/two-second delays). Every attempt emits its complete log, uses a different image path, and other failures stop immediately. Cleanup detaches only its own mount, preserves the directory if detach fails, and never forces a detach or restarts DiskImages services. `python3 Scripts/test-release-tools.py` includes four offline retry gates. A successful original-commit CI rerun establishes environment evidence only; new local source still needs its own CI after an owner-authorized commit/push.

The v1.3 scope also renders Patch import/export, LFS rules/files and Submodule list/review/Add in both languages and appearances using temporary repositories. Installed LFS interfaces use a clearly identified, network-disabled command fixture when the host lacks Git LFS; this does not establish real LFS server/credential/download acceptance. Submodule fixtures use only temporary local origins with file transport enabled for the fixture process. Native previews and write actions check preserved HEAD/Index and reuse DiffTable.

For visible P1 inspection, set `GITPIER_UI_ACCEPTANCE_INTERACTIVE_V130=1` and `GITPIER_UI_ACCEPTANCE_INTERACTIVE_PAGE=advanced` with a separately identified Debug bundle via `GITPIER_UI_ACCEPTANCE_EXECUTABLE`. The isolated panel exposes fixture, language and appearance selectors at 960×640, including a clearly labeled network-disabled LFS interface. Finish by creating `finish-gui` in the output directory; the process restores its settings, quits and cleans the temporary repositories. Normal application Settings scenes are not registered by the standalone acceptance runner; use these dedicated selectors instead.

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

Maintain production versions only in `Sources/GitPier/Resources/ReleaseConfiguration.json`; increase `build` for every distributed build. Keep the production bundle identifier stable. Empty `publicEDKey` means updates are disabled and production release signing refuses to run.

```bash
Scripts/test.sh
python3 Scripts/test-release-tools.py
UNIVERSAL=1 Scripts/build-app.sh
Scripts/package-dmg.sh
task_version="$(python3 Scripts/release_metadata.py --field version)"
Scripts/verify-dmg.sh "dist/GitPier-${task_version}-macos-universal.dmg"
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
task_version="$(python3 Scripts/release_metadata.py --field version)"
Scripts/sign-release.sh "dist/GitPier-${task_version}-macos-universal.dmg" reviewed-release-notes.md
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
task_version="$(python3 Scripts/release_metadata.py --field version)"
gh release create "v${task_version}" --draft --target "$APPROVED_COMMIT_SHA" --title "GitPier v${task_version}" --notes-file "$REVIEWED_NOTES_FILE" "dist/GitPier-${task_version}-macos-universal.dmg" "dist/GitPier-${task_version}-macos-universal.dmg.sha256" dist/appcast.xml
```

`APPROVED_COMMIT_SHA` and `REVIEWED_NOTES_FILE` must identify the owner's approved commit and final notes. This command is documentation, not an automatic publishing step; verify draft assets and CI before separately approving publication.

## v1.2.0 professional workflows

Released v1.2.0, build 18, is based on v1.1.0 (1827818). The original 98 Core tests and six release-tool gates remain intact. Worktree identification/opening, commit details, DiffTable, literal paths, reviewed destructive actions and per-working-tree state already existed; the new pages reuse them.

| Capability | v1.1.0 baseline | v1.2.0 implementation |
| --- | --- | --- |
| Reflog | No dedicated page/query | Native paged HEAD/local-branch log, filters, details, fixed-object recovery branch, reviewed soft/mixed reset |
| Worktrees | Identify/open linked repositories | List/create/register, lock/unlock, guarded remove, moved-linked-tree repair, shared metadata queue |
| Branch comparison | Commit/parent Diff | Local/remote-tracking ref pairs, merge bases, unique counts/paged commits, tip or three-point file Diff |
| Blame | File history and commit Diff | Working/historical text, per-line attribution, commit/file details, rename attribution and bounded paging |

Run the complete suite with `Scripts/test.sh`, `python3 Scripts/test-release-tools.py`, and `Scripts/ui-acceptance.sh .cache/ui-acceptance/v120`. The workflow-only GUI entry is `GITPIER_UI_ACCEPTANCE_SCOPE=version120 Scripts/ui-acceptance.sh .cache/ui-acceptance/v120-workflows`. All writes and resets in these workflows use disposable repositories. The visible GUI mode sets `GITPIER_UI_ACCEPTANCE_INTERACTIVE_WORKFLOWS=1`, uses an independently identified application through `GITPIER_UI_ACCEPTANCE_EXECUTABLE`, supports `GITPIER_UI_ACCEPTANCE_LANGUAGE=zh-Hans` / `GITPIER_UI_ACCEPTANCE_APPEARANCE=light` for isolated initial settings, and waits for a `finish-gui` marker in its output directory after manual interactions. Use an isolated workspace and application identity; never launch this mode with a normal user's workspace. Offscreen view bitmaps do not prove full SwiftUI visuals or mouse interaction.

Local builds remain development candidates until an approved release. Production signing, asset uploads, tags and publication require owner authorization; preserve historical releases. The production Bundle ID, Sparkle 2, feed and public key are retained; never replace or regenerate the production key. Keep future changes in Unreleased until an approved release. Universal compilation does not establish Intel/macOS 14 device acceptance or notarization.

### v1.3.0 local validation — 2026-10-15

The unreleased 1.3.0 (19) source passed 201 Core tests with zero failures/skips and ten release-tool gates. The original full native UI/PTY regression and the v1.3 workflow scope passed; the added visible P1 panel was compiled and checked again through `Scripts/ui-acceptance.sh`. Actual CUA inspection covered Patch import/export, the explicitly marked LFS interface fixture and Submodules at 960×640 in English/Chinese and light/dark, with native Diff, OID/gitlink details, rule/Add sheets and default-cancel confirmations. A native Patch save produced the expected 225-byte fixture. Read-only inspection and cancelled confirmations retained the fixture's staged configuration/gitlink and working files.

`UNIVERSAL=1 Scripts/build-app.sh` passed on the final source, including both architectures, Sparkle helpers and deep signatures. A new local HFS+/ULFO DMG passed `Scripts/package-dmg.sh` structural/signature checks; all 109 mounted bundle files/links matched the current application. Finder displayed the actual application icon, Applications link, background, arrow and bilingual instructions. This image is a local review artifact without production EdDSA signing. No commit, push, tag or Release was created. New-source Swift 6.1 CI, real LFS server downloads, physical Rebase drag behavior, Intel/macOS 14 device runs and production update/Gatekeeper acceptance remain outside this local evidence.

Additional interface/update fixes passed the full UI/PTY suite and the v1.1 updater lifecycle scope, followed by a current Universal rebuild. Visible inspection checked aligned Rebase controls, functional menus without attached indicators, and the complete About content at the fixed 760×580 Settings size in both languages/appearances. A temporary-key signed loopback Feed offered build 21 to build 20 automatically despite a freshly seeded last-check date; disabling automatic checks persisted across restart with no Feed request, and manual checking still offered the update. Both dialogs were dismissed without downloading/installing. The test application, server, preference domain, runtime and disposable key files were cleaned; the production install and preferences were read only. The earlier local DMG predates these additional interface changes and must not be distributed as the current candidate.

The visible v1.3 inspector accepts `GITPIER_UI_ACCEPTANCE_INTERACTIVE_PAGE=rebase` for the clean linear fixture and `about` for 760×580 Settings. These are optional isolated acceptance entries; normal launches and the default full suite retain the same workflow.

### Local validation — 2026-10-14

`Scripts/test.sh` passed all 128 Core tests (the original 98 plus 30 new cases), with zero failures and zero skips in the normal macOS environment. `python3 Scripts/test-release-tools.py` passed all six existing gates. New tests use temporary Git repositories and cover recovery after reset, unavailable objects, 1,001-record reflog pagination, worktree creation/lock/removal/repair, stale reviews, ignored files, replaced-directory ownership, detached commit retention, independent Index/drafts/layouts, full-ref comparison, merge bases, rename Blame, large files and cancellation.

The final `Scripts/ui-acceptance.sh .cache/ui-acceptance/v120-full` run passed the complete native UI/PTY suite, including existing 1.0.2/1.1.0, conflict, scrollbar and terminal regressions plus the v1.2.0 workflow checks. `UNIVERSAL=1 Scripts/build-app.sh` verified both arm64/x86_64, version 1.2.0 (18), embedded Sparkle helpers and deep signatures. `Scripts/test-dmg-structure.sh` passed on that final bundle; it verifies a disposable image and does not establish a new Finder drag-install or self-update.

Visible acceptance used a separate application identity, isolated configuration and disposable repositories. Native interactions checked recovery-branch creation, worktree creation/registration/lock/unlock/removal with the affected path, independent state, both comparison semantics, Blame → commit file Diff → return, English/Chinese, light/dark and 960×640 layouts. Hosted/offscreen component snapshots are separate evidence and do not prove complete SwiftUI pixels.

Blame refuses single lines longer than 20,000 UTF-16 characters as well as files over 4 MiB, to keep native text layout bounded. Removal of external worktrees is intentionally unavailable; repair does not grant deletion ownership. Repair supports moved linked trees within the same common directory, not an automatic relocation of the whole main repository. This local validation preceded the release checks below.

### Release validation — 2026-10-14

[v1.2.0](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.2.0) was published as Latest after owner approval of the bilingual notes. Its tag and Universal DMG correspond to commit `c08d64bf81f58b8a45daaae3a71be83524180f84`. [Same-commit CI](https://github.com/Heisenberg2024/gitpier/actions/runs/38490929602) passed 128 Core tests and six release-tool gates on Swift 6.1.2 / macOS 15, plus application build, temporary DMG structure and archive/upload checks. Local packaging verified arm64/x86_64, the embedded Sparkle helpers, deep signatures, HFS+/ULFO DMG structure and the visible Finder installer layout.

The final DMG and Appcast were signed with the existing production EdDSA key. Altered archive/feed copies were rejected. Draft and public downloads of the DMG, checksum and Appcast matched the local hashes; the Latest feed served the same signed 1.2.0 (18) item. Historical release bodies, tags and attachments were preserved. Intel/macOS 14 device runs, an actual new-DMG mouse drag/install, downloaded quarantine/App Translocation, Developer ID/notarization and an end-to-end v1.1.0 → v1.2.0 production update remain unverified.
