# Commit file list performance implementation plan

> **For agentic workers:** Execute inline in this session. User authorization for subagents is zero; do not dispatch reviewers or implementers.

**Goal:** Fix binary Index snapshot loading and make the Commit file list scroll smoothly with 226–1000 changes.

**Architecture:** Keep RepositoryModel and all Git operations unchanged. Replace only the SwiftUI file-list document with an AppKit NSTableView that reuses native cells, while retaining the shared overlay scrollbar and the existing file-selection/context-menu callbacks.

**Tech stack:** Swift, SwiftUI, AppKit; macOS 14+; no new dependencies.

**Spec:** The owner's current requests: repair safe-loading-limit errors with the client repository and optimize its Commit-page file-list scrolling. This is an implementation choice; no visual redesign was requested.

## Constraints and review focus

- No real client staging/commit/push, global configuration changes, automatic publication or subagents.
- Keep English/Chinese strings, list/tree hierarchy, group counts/checkboxes, partial staging, first-click selection, double-click tabs, Shift/Command selection and file context menus.
- Reuse OverlayScrollbars/OverlayScrollThumb: both axes, fixed lengths, fade, clipping and pass-through; retain nested discovery elsewhere.
- Preserve per-repository scroll position and keyboard reveal after filtering/expansion.
- Avoid row reloads on unrelated model updates; recycle cells while scrolling and update only materialized cells for selection/inclusion/style changes.

## Tasks

- [x] Reproduce the binary snapshot error with real large binary fixtures; keep exact tree validation and drop binary payloads from statistics only. Two tests failed before the change and passed after it; 1010 Core tests and 112 native snapshot assertions passed.
- [x] Add `file-scroll` native acceptance in `FileScrollAcceptance.swift` and `UIAcceptance.swift`. Collect 226/1000-file list/tree frame intervals (including fixed 8 ms pacing), materialized rows, unchanged Diff reads/selection/inclusion/Index, and repeated discovery. Frozen baseline executable and JSONs live under `.cache/large-index-fix`.
- [x] Mark the known leaf file document to avoid nested-scroll discovery; ancestry-checked weak markers preserve document replacement behavior. This removes repeated discovery but measured frame intervals do not materially improve; retain it as bounded discovery, not the main performance claim.
- [x] Implement `NativeChangesList.swift`: typed group/directory/file/empty rows, reusable NSTableView cells, existing callbacks, shared overlays and scroll memory. Replace the file ScrollView in `CommitWorkspace.swift` without changing Git/model boundaries.
- [x] Extend native acceptance to assert viewport-bounded row reuse and exercise checkboxes, single/double clicks, multi-selection, keyboard reveal, group/tree collapse, filtering, resizing, themes, context menus and scroll endpoints. Demonstrate failures on the frozen baseline where applicable.
- [x] Build via `Scripts/build-app.sh`, compare the frozen baseline and final application sequentially with no overlapping build/profiler, run affected native scopes and complete UI/PTY acceptance. Reuse Core results only after matching all Core/test inputs.
- [x] Update architecture, bilingual changelog and PROJECT_MEMORY; inspect cumulative status/diff/cached/untracked files and provide the Chinese Conventional Commit text. Keep installation/restart explicit in delivery.

## Existing evidence and limits

Client's staged binary patch was 26,220,056 bytes; statistics-only patch was 775,088 bytes. Baseline controlled Debug P95 intervals: 30.31/30.72 ms at 226 files, 97.78/89.88 ms at 1000 files (list/tree, each includes 8 ms pacing). This is a fixture benchmark, not a physical touchpad FPS claim. The actual installed client's diagnostic was observed; CUA scrolling failed twice with windowNotFoundAtPosition, so subsequent performance evidence uses the native temporary fixture.

The first snapshot-only Release build was interrupted when the owner added performance scope. One native probe compile needed a mutable-property setter; copying a bare baseline executable outside its framework directory caused one loader failure; baseline warmup was corrected to finish real Diff prefetch before measuring scroll-only reads. None changed product assertions or Git safety.

Checkpoint: native cell reuse passed viewport bounds at 226/1000 files (17–18 rows), 16 additional control checks and bilingual/theme captures. The first focus patch only changed FileMouseDownView and did not cover arrows received directly by NSTableView; that attempt was removed. The common Coordinator navigation now queues row focus after reveal; the unchanged full UI keyboard assertions progressed past this case. Final full UI/PTY passed with 104 captures; the same-input follow-up passed 16 control checks with P95 13.74/13.37 ms (226 list/tree) and 16.88/16.66 ms (1000 list/tree). Final native snapshot review passed 112 assertions. Release arm64 1.8.0(30) build/signature/181 bundle entries and 284 unchanged inputs passed. The owner explicitly approved ending the live zsh session and replacement/restart. Final Release is installed at /Applications/GitPier.app (PID 72049); actual client loads 226 staged files/draft with enabled Commit, scrolls to both ends, and preserves exact HEAD/branch/Index/status plus 14 repository/draft identities. Old bundle/configuration backups remain private. One post-exit UI query relaunched the old app before replacement; it was normally exited again and process checks were used thereafter.
