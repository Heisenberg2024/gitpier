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

For the v1.3 workflows, run `GITPIER_UI_ACCEPTANCE_SCOPE=version130 Scripts/ui-acceptance.sh`. Rebase tests exercise typed plans, native conflicts, restart/message recovery, hooks/signing rejection and stale HEAD/Index/todo/file protection in disposable repositories. Hosted screenshots supplement actual visible GUI interaction; they do not establish real drag or confirmation behavior. Native Git may require an explicit recovery commit after a signing/hook failure; keep its diagnosis, use the repository terminal or reviewed Abort, and never disable signing to make acceptance pass.

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

Before release, the 1.3.0 (19) source passed 201 Core tests with zero failures/skips and ten release-tool gates. The original full native UI/PTY regression and the v1.3 workflow scope passed; the added visible P1 panel was compiled and checked again through `Scripts/ui-acceptance.sh`. Actual CUA inspection covered Patch import/export, the explicitly marked LFS interface fixture and Submodules at 960×640 in English/Chinese and light/dark, with native Diff, OID/gitlink details, rule/Add sheets and default-cancel confirmations. A native Patch save produced the expected 225-byte fixture. Read-only inspection and cancelled confirmations retained the fixture's staged configuration/gitlink and working files.

`UNIVERSAL=1 Scripts/build-app.sh` passed on the final source, including both architectures, Sparkle helpers and deep signatures. A new local HFS+/ULFO DMG passed `Scripts/package-dmg.sh` structural/signature checks; all 109 mounted bundle files/links matched the current application. Finder displayed the actual application icon, Applications link, background, arrow and bilingual instructions. That earlier image was a local review artifact without production EdDSA signing. No commit, push, tag or Release was created at that checkpoint. Subsequent Swift 6.1 compatibility and release checks are recorded below; real LFS server downloads, physical Rebase drag behavior, Intel/macOS 14 device runs and production update/Gatekeeper acceptance remain outside this local evidence.

Additional interface/update fixes passed the full UI/PTY suite and the v1.1 updater lifecycle scope, followed by a current Universal rebuild. Visible inspection checked aligned Rebase controls, functional menus without attached indicators, and the complete About content at the fixed 760×580 Settings size in both languages/appearances. A temporary-key signed loopback Feed offered build 21 to build 20 automatically despite a freshly seeded last-check date; disabling automatic checks persisted across restart with no Feed request, and manual checking still offered the update. Both dialogs were dismissed without downloading/installing. The test application, server, preference domain, runtime and disposable key files were cleaned; the production install and preferences were read only. The earlier local DMG predates these additional interface changes and must not be distributed as the current candidate.

The visible v1.3 inspector accepts `GITPIER_UI_ACCEPTANCE_INTERACTIVE_PAGE=rebase` for the clean linear fixture and `about` for 760×580 Settings. These are optional isolated acceptance entries; normal launches and the default full suite retain the same workflow.

### v1.3.0 release validation — 2026-10-15

[v1.3.0](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.3.0) was published as Latest after owner approval of the bilingual notes. Its tag and final Universal DMG correspond to commit `b2de5bdadffecc11d8da265e6905e6126f3d4f6f`. [Same-commit CI](https://github.com/Heisenberg2024/gitpier/actions/runs/38616173476) passed 201 Core tests with zero failures/skips and ten release-tool gates on Swift 6.1.2 / macOS 15, plus application build, temporary DMG structure and archive/upload checks. Earlier runs exposed actor-isolation errors in a local async Submodule traversal and type-check timeouts in complex Rebase/Submodule Text expressions. The final source uses an actor-isolated traversal with Sendable value state and explicit String summaries; it retains scan bounds, displayed content and reviewed operations.

The final source passed the native v1.3 scope again, followed by a new Universal build and DMG. The mounted application's 109 files/links matched the built bundle, and actual Finder inspection confirmed the real icons, Applications link and bilingual background. The DMG is 12,656,672 bytes with SHA256 `a82da2522b1a95b4a744bd9a24bd5ccee9fbde5ca471ffa338ae5039677b7f76`.

The existing production EdDSA key signed the DMG and Feed; altered copies were rejected. Draft and public release bodies matched the approved notes, and all three downloaded attachments matched local sizes, hashes and signatures. Public download URLs and the canonical Latest Feed returned HTTP 200; the Feed served the signed 1.3.0 (19) item. All six historical releases, fourteen historical assets and existing tags were preserved. The user's installed application was not replaced. Real LFS server downloads, physical Rebase drag, Intel/macOS 14 device runs, quarantine/Gatekeeper and a production v1.2.0 → v1.3.0 self-update remain unverified; Developer ID signing/notarization are still absent.

### Local validation — 2026-10-14

`Scripts/test.sh` passed all 128 Core tests (the original 98 plus 30 new cases), with zero failures and zero skips in the normal macOS environment. `python3 Scripts/test-release-tools.py` passed all six existing gates. New tests use temporary Git repositories and cover recovery after reset, unavailable objects, 1,001-record reflog pagination, worktree creation/lock/removal/repair, stale reviews, ignored files, replaced-directory ownership, detached commit retention, independent Index/drafts/layouts, full-ref comparison, merge bases, rename Blame, large files and cancellation.

The final `Scripts/ui-acceptance.sh .cache/ui-acceptance/v120-full` run passed the complete native UI/PTY suite, including existing 1.0.2/1.1.0, conflict, scrollbar and terminal regressions plus the v1.2.0 workflow checks. `UNIVERSAL=1 Scripts/build-app.sh` verified both arm64/x86_64, version 1.2.0 (18), embedded Sparkle helpers and deep signatures. `Scripts/test-dmg-structure.sh` passed on that final bundle; it verifies a disposable image and does not establish a new Finder drag-install or self-update.

Visible acceptance used a separate application identity, isolated configuration and disposable repositories. Native interactions checked recovery-branch creation, worktree creation/registration/lock/unlock/removal with the affected path, independent state, both comparison semantics, Blame → commit file Diff → return, English/Chinese, light/dark and 960×640 layouts. Hosted/offscreen component snapshots are separate evidence and do not prove complete SwiftUI pixels.

Blame refuses single lines longer than 20,000 UTF-16 characters as well as files over 4 MiB, to keep native text layout bounded. Removal of external worktrees is intentionally unavailable; repair does not grant deletion ownership. Repair supports moved linked trees within the same common directory, not an automatic relocation of the whole main repository. This local validation preceded the release checks below.

### Release validation — 2026-10-14

[v1.2.0](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.2.0) was published as Latest after owner approval of the bilingual notes. Its tag and Universal DMG correspond to commit `c08d64bf81f58b8a45daaae3a71be83524180f84`. [Same-commit CI](https://github.com/Heisenberg2024/gitpier/actions/runs/38490929602) passed 128 Core tests and six release-tool gates on Swift 6.1.2 / macOS 15, plus application build, temporary DMG structure and archive/upload checks. Local packaging verified arm64/x86_64, the embedded Sparkle helpers, deep signatures, HFS+/ULFO DMG structure and the visible Finder installer layout.

The final DMG and Appcast were signed with the existing production EdDSA key. Altered archive/feed copies were rejected. Draft and public downloads of the DMG, checksum and Appcast matched the local hashes; the Latest feed served the same signed 1.2.0 (18) item. Historical release bodies, tags and attachments were preserved. Intel/macOS 14 device runs, an actual new-DMG mouse drag/install, downloaded quarantine/App Translocation, Developer ID/notarization and an end-to-end v1.1.0 → v1.2.0 production update remain unverified.

### v1.4.0 local validation and measurements — 2026-10-15

Released [v1.4.0](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.4.0) is build 20. Workspace Core regressions cover local-only status, unchanged Index bytes, branch/HEAD/upstream changes, permission/missing/invalid failures, worktree identity, request coalescing/priorities/cancellation, failed-cache backoff, reviewed Fetch/transport errors and safe shared queues, and literal Unicode/special-path, commit and scope searches. Partial-clone local queries require Git 2.43 or later because older versions ignore the lazy-fetch prohibition; ordinary repositories retain existing Git compatibility.

Run native workspace acceptance with `GITPIER_UI_ACCEPTANCE_SCOPE=version140 Scripts/ui-acceptance.sh`, or `Scripts/workspace-acceptance.sh version140` for the packaged Release app. The latter copies the existing app under a unique test bundle ID, resigns only that copy, disables production updater configuration by identity mismatch and removes its own preference domain/bundle on exit. Production application/preferences remain untouched. The full default UI/PTY suite includes the workspace scope. Optional `GITPIER_UI_ACCEPTANCE_INTERACTIVE_V140=1` keeps a disposable visible fixture open until the output directory contains `finish-gui`; use an independently identified application copy for manual inspection. Only fixture repositories are cloned/changed.

For repeatable Release measurements, first build with `UNIVERSAL=1 Scripts/build-app.sh`, then run:

```bash
Scripts/workspace-acceptance.sh workspace-performance .cache/performance/workspace
```

The harness creates 10/50/100 physical repositories, one linked Worktree and two unavailable entries, 10,000 untracked files and 1,000 commits per clone. It records native Dashboard readiness before scanning finishes, local scan/refresh duration, organization switching during refresh, direct Git process launch peaks, failure isolation and main-loop lag. Readiness uses a fresh AppStore/cache in a warmed native process and excludes fixture creation/process launch; RSS is process-wide cumulative `ru_maxrss`. Counters store no arguments, paths or search text. Measurements and screenshots remain local/ignored; do not infer improvement percentages, physical Intel/macOS 14 compatibility or production self-update from these checks.

Local validation on 2026-10-15 passed all 239 Swift tests (the original 201 plus 38 workspace cases), with zero failures/skips, and all ten release-tool gates. The complete native UI/PTY suite passed in SwiftPM and again through the separately identified Universal Release copy, including v1.1/v1.2/v1.3/v1.4 workflows. Visible Release inspection checked Dashboard filters/worktree collapse, readable Fetch review/cancellation, actual Quick Open keys with terminal exclusion, scoped tracked-path search and file-history navigation. FSEvents notification-only semantics survived configuration saves until explicit refresh.

Release measurements on macOS 27.0.1, Apple silicon with 14 logical CPUs and Apple Git 2.54.0 used exactly 10/50/100 physical repositories, plus one linked Worktree and two unavailable entries per case. Each clone had 1,000 commits; one repository had 10,000 untracked files. One sample per case, with fresh store/cache in a warmed visible native process:

| Physical repositories / entries | Dashboard ready (ms) | Local scan (ms) | Refresh (ms) | Direct Git peak | Peak process RSS (MiB) | Organization layout during refresh (ms) | Heartbeat excess p95 / max (ms) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10 / 13 | 240.21 | 628.49 | 337.30 | 3 | 193.36 | 50.63 | 30.26 / 33.51 |
| 50 / 53 | 316.51 | 1585.71 | 1434.69 | 3 | 221.05 | 94.22 | 31.00 / 74.54 |
| 100 / 103 | 595.25 | 3177.58 | 2412.19 | 3 | 247.36 | 104.81 | 25.22 / 94.53 |

Full RepositoryModel refresh count was zero in every scan case; the unavailable entries did not block the remaining repositories. Deliberate missing-remote Fetch failed independently in 57.93/59.18/61.64 ms. Organization timing measures a programmatic scope change followed by native layout/yield, not a physical-click latency; heartbeat values measure scheduling excess over a 10 ms probe. Direct Git counters exclude helpers launched internally by Git. No previous-version performance baseline was measured, so no percentage improvement is claimed.

The final 1.4.0 (20) Universal bundle, Sparkle helpers and deep signatures passed. A local HFS+/ULFO DMG passed structure/signature checks; 109 mounted bundle files/links and permissions matched the built app. Actual Finder inspection confirmed the real GitPier icon, Applications link, background, arrow and bilingual instructions. That earlier candidate was not production EdDSA signed or published; final release validation is recorded below. A temporary-key signed loopback update completed build 20 → 21, installation/relaunch and responsive startup under a separate test identity; repository settings/selection/draft and Index bytes were preserved. The workspace JSON was normally reserialized with default fields. Altered Feed and invalid archive signatures were rejected; the test app/runtime/private key/preferences/server were cleaned. Production preferences/configuration and historical local packages/appcast fingerprints stayed unchanged.

Earlier verification exposed a dictionary exclusivity conflict, actor closure isolation-checker limitations and stale configuration/cache edges; these were repaired and rerun. Acceptance-only issues included an unsigned outer test-app copy, an initial-foreground-refresh timestamp race and an offscreen accessibility tree containing only scrollbars. The wrapper now signs the outer copy and benchmarks visible windows after activation; failed checkpoints are not counted as passing measurements. Intel/macOS 14 device runs, real LFS service downloads, physical Rebase dragging, downloaded quarantine/Gatekeeper, real Applications drag installation and production self-update remain outside this local evidence. Developer ID/notarization are still absent.

### v1.4.0 release validation — 2026-10-15

[v1.4.0](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.4.0) was published as Latest after owner approval of the revised English-first bilingual notes. The tag and final Universal DMG correspond to commit `51a1cd958f0b9a47e7d1b12486edcd94cc6b4ef6`. [Same-commit CI](https://github.com/Heisenberg2024/gitpier/actions/runs/38676352614) passed 239 Core tests with zero failures and ten release-tool gates on Swift 6.1.2, plus application build, temporary DMG structure and archive/upload checks.

The final source was rebuilt through `UNIVERSAL=1 Scripts/build-app.sh`; all 141 recorded build inputs matched the approved clean commit. The application and Sparkle helpers passed both-architecture/deep-signature checks. The HFS+/ULFO DMG passed structural verification; its 109 bundle files/links and permissions matched the built app, and actual Finder inspection confirmed the real icons, Applications link, arrow and bilingual instructions. The DMG is 13,637,970 bytes with SHA256 `5bd51482569e8d28dcd325e294a670133239c7686018ca80c8adc985c34a0fbd`.

The existing production EdDSA key signed the DMG and Appcast, with the bundle ID, public key and feed URL unchanged. The signed feed embeds the approved notes byte-for-byte; altered archive/feed copies were rejected. Draft metadata, server digests and all three downloaded attachments matched the approved body and local bytes/hashes/signatures before publication. After publication, the three public downloads and canonical Latest Feed returned HTTP 200 and matched the same assets; feed/archive signatures verified again. All seven historical releases, seventeen historical assets and existing tags were preserved; the user's installed application, preferences and workspace were unchanged. Intel/macOS 14 device runs, real LFS service downloads, physical Rebase dragging, downloaded quarantine/Gatekeeper, real Applications drag installation and a production self-update remain unverified. Developer ID signing and Apple notarization are still absent.

### Post-release CI SIGPIPE repair — v1.4.1

The documentation-only commit `5c57c15` changed six Markdown files. Its [CI run](https://github.com/Heisenberg2024/gitpier/actions/runs/38679465508) and the [v1.4.0 tag run](https://github.com/Heisenberg2024/gitpier/actions/runs/38678738243) both exited with signal 13 during `testSelectedLinesNativePatchCheckFailurePreservesIndex`. The same source had passed its earlier CI run; the later failures exposed an existing timing-dependent process-I/O defect. The test intentionally rejects a Git patch without reading stdin. An asynchronous `FileHandle` write to the closed pipe could deliver SIGPIPE before Swift could handle its EPIPE error.

`ProcessRunner` now sets Darwin's `F_SETNOSIGPIPE` on the parent stdin write descriptor before launch, without changing the application-wide signal disposition or child/hook behavior. `ProcessRunnerTests.testClosedStdinDoesNotTerminateRunner` launches a disposable XCTest child with the default terminating SIGPIPE policy, so the regression cannot kill the parent suite. It reproduces exit 13 before the fix and covers early/partial input rejection, preserved exit diagnostics, normal byte delivery, timeout/cancellation and the unchanged signal policy after the fix. Do not suppress SIGPIPE globally or skip the failing test. The published v1.4.0 tag and assets are unchanged; this source fix passed [same-commit CI](https://github.com/Heisenberg2024/gitpier/actions/runs/38681026772) and is included in v1.4.1.

Local validation on Swift 6.4 passed all 240 Core tests (239 existing plus the isolated regression) with zero failures/skips, including the original patch-check rejection, and all ten release-tool gates. The regression failed with child exit 13 before the fix and passed afterward. These local results do not replace Swift 6.1.2 CI on the final pushed revision.

### Dashboard visual redesign — v1.4.1

`DashboardView.swift` composes a centered workspace (1320pt content limit), five snapshot-backed metrics, a responsive search/filter/sort toolbar and a lazy repository list. `DashboardRepositoryRow.swift` shares column geometry with the headings; narrow windows put the branch under the name and omit update timestamps. The independent checkbox, worktree disclosure and open button preserve their separate actions. Selection is shown in a reserved footer, including selected entries outside the search/filter results. Failures expose the full redacted diagnostic and a local-refresh action.

`GitPierCore/WorkspaceListing.swift` computes the organization-scoped summary, metadata search, existing AND filters, stable sorting and visible worktree projection once per Dashboard update. Collapsing changes only displayed rows; matching IDs/counts and Select Matches still include hidden worktrees. If filters remove the main worktree, the first matching member remains visible. It introduces no Git queries, persistence or collection/Fetch changes. Dashboard and sidebar share the existing native editor/favorite/organization menu actions.

Run `Scripts/test.sh`, `UNIVERSAL=1 Scripts/build-app.sh`, then `Scripts/workspace-acceptance.sh dashboard .cache/dashboard-redesign/final` for the focused native check. It creates eight real disposable entries including three related worktrees, modified/staged/ahead/behind/conflict/no-upstream/missing states. It renders both languages and light/dark appearances at 960×640, 1200×800, 1440×900, 1600×1000 and 1920×1080, with separate selection/collapse/error/empty/scanning captures and native interaction checks. `GITPIER_DASHBOARD_INTERACTIVE=1` leaves this isolated window open until its output directory contains `finish-gui`, for physical mouse/keyboard inspection. Use `workspace-acceptance.sh full` for the complete native UI/PTY suite, and `workspace-acceptance.sh workspace-performance` for 10/50/100-repository checks. Keep GUI runs serial. The wrapper copies the app to a unique runtime identity, re-signs it and removes only its own preferences/copy on exit; it cannot start production updating. No version change or publication is part of this redesign.

Local validation on 2026-10-15 passed 245 Core tests (including five new listing regressions) with zero failures/skips, ten release-tool gates, the focused Dashboard suite and the complete native UI/PTY suite through a separately identified Universal Release copy. Thirty native fixture screenshots cover the five sizes, both languages/appearances and selection/conflict/unavailable/worktree/empty/scanning states. CUA additionally checked actual keyboard search, independent selection, retained selections outside results, sorting, reviewed Fetch/cancel, empty organization, Clone access, native Favorite count updates and wheel scrolling to the last row. The column heading is pinned inside the same scroll layout as rows; horizontal content margins are zero, and its opaque background prevents scrolling text from bleeding through.

The 10/50/100-physical-repository Release checks (plus one linked Worktree and two unavailable entries) recorded readiness of 232.27/421.57/635.33 ms and scans of 587.73/1735.52/2835.01 ms. Direct Git peak remained three and full repository-session refreshes remained zero. These are single samples in a warmed process with empty per-case caches, excluding fixture/process launch; they do not establish a percentage improvement. The Universal slices, deep bundle signatures and final temporary DMG structure passed. Physical drag attempts did not trigger in either Dashboard or the existing sidebar, so physical dragging remains for manual confirmation; shared drag/drop code is unchanged and order/persistence regressions passed. The Dashboard changes, including the final path spacing, subsequently passed [same-commit CI](https://github.com/Heisenberg2024/gitpier/actions/runs/38714258115) at `033d054`. Intel/macOS 14 hardware runs remain unverified. Version 1.4.1 uses build 21 and the existing production identity, update key and feed; publication requires the complete release revision to pass CI.

### Automatic remote checks — v1.4.2 development

The development app is 1.4.2 (22); no 1.4.2 tag or public release has been created. Automatic checks default off, independent of local file watching. The selected repository uses 10/15/30/60 minutes (15 by default); other workspace repositories use 45 minutes, with at most two Fetches and 30-second workspace admission spacing. Startup/foreground/navigation only request an eligibility evaluation. Failures use 5/10/20/40/60-minute backoff while respecting a recent successful check; authentication requires manual recovery. The scheduler uses monotonic deadlines in-process and versioned, atomically written metadata across restarts.

Fetch targets retain the existing common-directory/remote/full-config/effective-URL/filesystem identity. Automatic Fetch allows standard tracking refspecs only, skips Mirror, foreign VCS/upload-pack helpers and custom SSH commands, and forbids tags, Prune, recursive submodule fetching, automatic maintenance and interactive prompts. Keychain reads prohibit interaction and the osxkeychain replacement matches HTTPS, default Git authentication type and the exact port. Native manual Fetch keeps its original command semantics; metadata excludes remotes skipped by either `skipFetchAll` or `skipDefaultUpdate`. Neither failed nor cancelled checks erase previous tracking counts. Running cancellations refresh snapshots because Git may already have committed refs before cancellation.

Local snapshot collection time and remote success/attempt/eligibility time are distinct. Per-attempt and snapshot uptimes reject older completions and cached data. Automatic tracking refreshes preserve drafts, Diff tabs, selection, history and Worktree pages; busy sessions keep the newest pending tracking snapshot. Zero/zero is described literally as matching tracking references, with a separate remote-check state/time, since a custom manual refspec may not cover every upstream.

Run the following against disposable fixtures, keeping GUI runs serial:

```sh
Scripts/test.sh
python3 Scripts/test-release-tools.py
UNIVERSAL=1 Scripts/build-app.sh
Scripts/workspace-acceptance.sh version142 .cache/v142/remote-checks
Scripts/workspace-acceptance.sh full .cache/v142/full
Scripts/workspace-acceptance.sh version140 .cache/v142/workspace
Scripts/workspace-acceptance.sh dashboard .cache/v142/dashboard
Scripts/workspace-acceptance.sh workspace-performance .cache/v142/performance
Scripts/test-dmg-structure.sh
```

The 1.4.2 scope exercises native tri-state selection, partial queue acceptance/cancellation, real local-bare automatic Fetch and Worktree deduplication, enabled restart without duplicate Fetch, corrupt metadata preservation, a committed reference-transaction Hook cancelled after refs changed, timestamp/result ordering, toolbar running/disabled/count/divergence/no-upstream states, failure retention/backoff and shared metadata removal. It captures English/Chinese and light/dark layouts at 960/1440 widths plus Git settings.

When macOS foreground activation or other desktop work interrupts the opt-in network check, use a fresh output directory and `GITPIER_UI_ACCEPTANCE_INTERACTIVE_FOREGROUND=1`. The fixture pauses at `ready-automatic` and `ready-cancellation`; physically click only the uniquely identified disposable test window, then create the corresponding `continue-automatic` / `continue-cancellation` file in that output directory. This does not bypass `NSApp.isActive` or scheduling/backoff. Never operate the normal production GitPier window. Disabled SwiftUI buttons may be absent from AX: the running capture and absence of an enabled Fetch action are the acceptance criteria.

Final local validation passed 276 Core tests (all 245 existing cases plus 31 new cases), with zero failures/skips, and all ten release-tool gates. The final Universal Release app passed both architectures, embedded Sparkle helpers and deep signatures. Separately identified copies passed the complete native UI/PTY regression, v1.4 workspace scope, Dashboard scope and v1.4.2 scope. The latter produced 24 captures; actual CUA activation verified both foreground checks, and native interaction verified mixed/all/none selection. Dashboard regression produced 30 captures across both languages/appearances and five window sizes. All remote fixtures were disposable local bare repositories or controlled transports; no repeated requests used real GitHub repositories or accounts.

Release measurements used Apple silicon, 14 logical CPUs, macOS 27.0.1 and one sample per case. Each case contained the specified physical repositories, one linked Worktree and two unavailable entries; every clone had 1,000 commits and one repository had 10,000 untracked files. Readiness uses an empty per-case store/cache in a warmed visible process and excludes fixture creation and process launch.

| Physical repositories / entries | Dashboard ready (ms) | Local scan (ms) | Refresh (ms) | Initial Git launches / peak | Full session refreshes | Peak process RSS (MiB) | Heartbeat excess p95 / max (ms) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10 / 13 | 231.42 | 913.82 | 732.62 | 137 / 3 | 0 | 197.84 | 12.08 / 37.21 |
| 50 / 53 | 415.24 | 2662.77 | 2418.60 | 657 / 3 | 0 | 226.72 | 12.33 / 85.90 |
| 100 / 103 | 642.41 | 5329.82 | 4373.29 | 1307 / 3 | 0 | 254.92 | 12.85 / 110.90 |

Local scans include additional local upstream/configuration identity queries when an upstream exists; no-upstream repositories retain the existing six-query budget. No scan activated a full RepositoryModel session or calculated Diff/history. Unavailable entries remained isolated. Explicit missing-remote Fetch failed independently in 114.01/87.16/66.23 ms. Automatic checks were off during performance scans; the v1.4.2 network trace separately verified zero Fetch before opt-in, one Fetch for two shared Worktrees, no repeat on rapid lifecycle events or enabled reopen, and preserved failure backoff. Process counts cover direct Git launches, not internally launched helpers; RSS is cumulative process high water. These samples do not establish a percentage improvement.

The final bundle passed the temporary DMG structural/signature test. Production Bundle ID, macOS 14 minimum, Sparkle feed and EdDSA public key match the v1.4.1 baseline. No production app, global Git/SSH/shell configuration, historical release asset, tag or public release was changed. This local validation does not establish same-commit Swift 6.1 CI, Intel/macOS 14 device acceptance, real private-server authentication, new Finder drag installation, production self-update or Gatekeeper/notarization acceptance. Developer ID signing and notarization were not requested.
