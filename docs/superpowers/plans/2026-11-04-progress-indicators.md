# Unified operation progress implementation plan

> Execute locally in the current workspace. No subagents, staging or commits in this checkout, or external remote changes are authorized. Git acceptance uses disposable repositories and local remotes.

**Goal:** Apply the user's four screenshot requirements: a fixed native bar, the original refresh appearance, no segmented bars, and consistent treatment at every linear progress entry point.

**Initial architecture (superseded by the current correction below):** Keep the existing operation identity, cancellation and workflow reducer. Render one native small `NSProgressIndicator` in a fixed 100 × 12 pt slot (the native control's fitting height; its visible track remains small). Put footer bars at the trailing edge, with cancellation before the bar. Use actual transfer fractions when available, indeterminate progress otherwise, full progress on success and a stopped empty bar for other terminal outcomes. Reduce Motion uses a static native track when no fraction is available.

**Tech stack:** Existing SwiftUI/AppKit, macOS 14+, no new dependencies.

**Spec:** The current user request and its three attached screenshots. Small correction with one applicable approach: reuse the original native bar. Keeping segments conflicts with the request; estimated percentages would misrepresent unmeasured work.

## Constraints and review focus

- Preserve existing pending appearance changes and all Git execution/recovery behavior.
- English and Simplified Chinese; light/wide and dark/compact layouts.
- Long labels, cancellation becoming unavailable and footer metadata reappearing must not move or resize the bar.
- Refresh success must display completion even when internal workflow steps were skipped.
- Clone, Dashboard, other-repository operations and Operations Center share the native style and dimensions.
- Failed, cancelled, attention and unknown results must stop animating without implying success.
- Circular loading spinners retain their existing presentation.

## Task 1: Reproduce the presentation regression

**Files:** `Sources/GitPier/OperationProgressAcceptance.swift`, `Sources/GitPier/UIAcceptance.swift`.

- [x] Add a scoped native acceptance test for real control geometry across lifecycle states and the affected surfaces. Record screenshots and indicator frames; compare literal 100 pt width and stable geometry across state changes.
- [x] Run `GITPIER_UI_ACCEPTANCE_SCOPE=operation-progress Scripts/ui-acceptance.sh .cache/progress-indicators/red` and confirm a presentation assertion fails against the old segmented implementation.

## Task 2: Unify the native control and layout

**Files:** `OperationProgress.swift`, `CommitWorkspace.swift`, `DashboardView.swift`, `RootView.swift`, `OperationsCenter.swift`, `NativeExperienceAcceptance.swift`, both READMEs and the native-experience evidence document.

- [x] Replace segments with a shared fixed-size native bar and plain operation labels; retain actual transfer percentages and outcome semantics.
- [x] Anchor footer bars at the trailing edge and reserve cancellation space. Reserve the Clone progress row across states.
- [x] Run the new native acceptance until passing, then the existing workflow/operation presentation regressions and focused Core workflow reducer tests through the project scripts.
- [x] Build through `Scripts/build-app.sh`, review representative WindowServer screenshots, update evidence and `PROJECT_MEMORY.md`, then inspect the cumulative staged/unstaged/untracked diff and supply a Chinese Conventional Commit message without committing.

Pre-flight: Task 2 uses only Task 1's scoped acceptance route; no shared backend interfaces change. Existing appearance edits are retained. Author review is local; no independent review is claimed.

RED evidence: `.cache/progress-indicators/red-ui.log` reports `refresh-running-en-light-wide` with a 32 × 12 pt native indicator inside the segmented track. The new acceptance expects the whole 100 pt track. The first fixture attempt raced repository-page activation; waiting for its existing reads removes that test setup race.

Follow-up evidence: the Center's non-workflow transfer label previously inserted a row and moved its bar by 19 pt. A fixed header/progress row now precedes optional path/hash metadata, and native batch acceptance compares frames before/after transfer updates. WindowServer screenshots also exposed retained indeterminate rendering after switching a native control to a measured value. Recreating only when the native mode changes preserves geometry and restores the completed fill. Merely changing the order of `stopAnimation` and `isIndeterminate` did not fix the rendered track. A proposed Reduce Motion environment override was removed because SwiftUI exposes that environment value read-only; the existing system-settings acceptance owns that branch.

Complete: native progress 39 captures; presentation 43 assertions/58 captures; real temporary Commit & Push/readback/recovery; 18 focused Core cases; Universal Release 2.1.0 (35), strict signing and bundle verification. Evidence: `.cache/progress-indicators/verification-summary.json`. Representative screenshots and the cumulative pending diff, including the pre-existing sidebar correction, were reviewed locally. No independent review is claimed.

## Follow-up: distinct motion and a left repository anchor

The user further specified that refresh-like operations must bounce a theme-colored fill left/right, Push and Commit & Push must fill one continuous track from actual progress through final success, and repository progress belongs at a fixed position on the left. This supersedes the trailing repository anchor and switching back to native indeterminate mode during Push refresh.

- [x] Reproduce the old trailing position with the scoped native test.
- [x] Keep a monotonic measured transfer value across phase changes and refresh; ignore preparatory counting/compression, hold below completion until success, and do not advance on a timer. Push waits at zero until writing counters arrive. Reuse this reducer for workflow and batch records.
- [x] Render a single AppKit track with the theme accent: a reversing fill for unmeasured work, an anchored growing fill for measured work. Keep 100 × 12 pt geometry, a 6 pt visible track, static Reduce Motion handling and localized accessibility semantics.
- [x] Place the repository track before variable text at the footer's leading edge; preserve other surfaces' existing anchors.
- [x] Verify real rendered fill widths, both bounce directions, progress retention and final completion, fixed geometry, bilingual/theme layouts and real temporary Commit & Push. Build the Universal application and update both READMEs, evidence and project memory.

Follow-up complete: the old repository anchor failed native acceptance; six added workflow regressions produced 18 failures before the measured-value reducer. Final evidence covers 55 passing Core cases, 52 captures with real layer-width assertions and 18 motion samples per language, the 43-assertion/58-capture quality matrix and real temporary Commit & Push/readback/recovery. Universal Release 2.1.0 (35) passed signing and bundle verification. Evidence: `.cache/progress-indicators/followup/verification-summary.json`. Current behavior is the follow-up specification above; the earlier native-control/trailing-anchor results are historical.

## Latest correction: v2.0.0 waiting animation and fixed status-bar slot

The user reports that refresh motion is no longer visible and requests the exact v2.0.0 effect. Tag `v2.0.0` uses a small bar-style `NSProgressIndicator`, indeterminate `startAnimation`, and threaded animation. Restore that renderer only for unmeasured work. Preserve the current measured Push/Commit & Push reducer and drawing code byte-for-byte.

The screenshot's progress region becomes a fixed slot in the bottom status bar. The user's clarification explicitly forbids following the pane divider. Reserve a fixed 320 pt changes/staging column, then place the 100 pt progress track at the next column's 12 pt inset. Restore changes/staging to the far left; variable labels and panel dragging must not move the track.

- [x] Fail native acceptance against the current non-native refresh control.
- [x] Restore the v2.0.0 waiting renderer and the fixed footer columns; keep measured progress sources unchanged.
- [x] Verify actual WindowServer animation changes, fixed status/count geometry across states and pane dragging, measured fill regression, themes/languages and real temporary Commit & Push.
- [x] Rebuild the Universal app, update evidence, README and project memory, and review the cumulative pending diff without committing.

Latest verification: 60 native captures, five distinct waiting-track frames in each language, fixed +332 pt placement through divider movement, and unchanged measured fill. Four measured-progress source fingerprints match the saved baseline. Temporary Commit & Push passed. The first quality run failed to produce one Sheet screenshot after 27 captures; cause unconfirmed, no product change made for that failure. An unchanged-binary retry passed all 43 assertions/58 captures. Universal Release 2.1.0 (35), deep signing and bundle verification passed. Evidence: `.cache/progress-indicators/v200/verification-summary.json`. The normal old application instance remains running and needs reopening to load the new build.

## Current correction: refresh completion and responsive repository track

The latest screenshot shows a completed refresh. The running system animation is already present, but success switches it to a full measured bar for five seconds. The user explicitly chose to hide the refresh track after completion while retaining the icon, summary and reserved space. Mark repository refresh/opening as waiting presentation at its source; preserve measured workflows, including their internal refresh phase and full successful fill.

Match the red box by extending the repository track leftward: a 210 pt track at a fixed +222 pt footer offset on wide windows. Adapt only its length to the available window width, down to 100 pt on compact windows. Keep counts at the far left and keep the progress anchor independent of pane dividers, titles and lifecycle states. Other progress surfaces retain their 100 pt width.

- [x] Reproduce the completed-refresh full-bar regression in native acceptance.
- [x] Add explicit waiting presentation, hide terminal waiting tracks without collapsing their slot, and support the wider responsive repository track.
- [x] Verify real refresh completion, rendered waiting motion, measured fill at both widths, caption/count stability, pane dragging and window resizing; run affected native regressions.
- [x] Build the Universal application, inspect representative screenshots, update bilingual documentation and project memory, and review the cumulative pending diff without committing.

Current verification: 66 native captures, 43 presentation assertions/58 captures and real temporary Commit & Push/readback/recovery passed. Completed refresh has no progress control and retains its summary position. The 210/126.5 pt tracks keep the +222 pt footer offset across pane moves and window resize/restore. Core/Center fingerprints and normalized drawing source match the saved baseline; 55 Core results are reused. Universal Release 2.1.0 (35), deep signing and bundle verification passed. Preparation-to-verification 617.89 seconds; overlapping build 238.24 seconds; 0 subagents. Evidence: `.cache/progress-indicators/responsive/verification-summary.json`. Project memory consolidates the superseded progress entries and documents the explicit waiting mode and responsive footer layout. No staging, commit, push, installation or publication was performed.
