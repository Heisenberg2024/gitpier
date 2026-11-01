# Branch Health visualization — 2026-11-01

## Semantic appearance refinement — implementation and acceptance plan

The follow-up visual pass extends the existing `BranchSyncPresentation` and native badges. It keeps Git queries, sync-state calculation, freshness, workflow risk levels, layout and version configuration unchanged. No additional appearance framework or image assets are needed.

- [x] Pin the shared sync symbols in the existing native Branch Health acceptance and observe the old synced symbol fail.
- [x] Centralize dynamic icon colors in the existing presentation layer: synced/merged green, ahead primary text, behind blue, diverged orange, unknown/no upstream secondary text. Add a separate merge presentation for analyzed/unexamined/unknown ancestry with the existing localized wording.
- [x] Apply the mapping to Branches, Dashboard, Context Workflow badges and tracking-related network action indicators, preserving workflow and Fetch warning priority.
- [x] Extend existing native acceptance for all sync/merge symbols, text accessibility, dynamic colors, English/Chinese, light/dark, increased contrast and narrow windows. Use disposable local repositories only.
- [x] Build through `Scripts/build-app.sh` to an isolated output, run focused `Scripts/test.sh` regressions and `Scripts/ui-acceptance.sh`, inspect final native captures, and record exact limitations and preserved inputs.

Review focus: missing upstream is neutral; unknown never inherits divergence's orange; current checkout uses a filled check distinct from sync; an unexamined merge cannot look merged; remote freshness and genuine conflict/error warnings retain their own semantics.

### Current symbol and semantic color mapping

| State | SF Symbol | SwiftUI color |
| --- | --- | --- |
| Synced / 已同步 | `checkmark.circle` | `.green` |
| Ahead / 领先 | `arrow.up.circle` | `.primary` (adaptive text) |
| Behind / 落后 | `arrow.down.circle` | `.blue` |
| Diverged / 已分叉 | `arrow.triangle.branch` | `.orange` |
| Merged into selected target / 已合并至目标 | `arrow.triangle.merge` | `.green` |
| Unknown / 状态未知 | `questionmark.circle` | `.secondary` |
| No upstream / 未设置上游 | `link.badge.plus` | `.secondary` |

`BranchSyncPresentation` owns sync symbols, dynamic colors, localized titles/counts, VoiceOver descriptions and tracking-related Pull/Push icon tints. `BranchSyncBadge` renders that mapping in Branches, Dashboard and Context Workflow; ordinary text/counts remain secondary. Network arrows remain action symbols. Workflow headings, conflict/error priorities, remote freshness and the Dashboard summary cards keep their existing appearance and behavior.

`BranchMergePresentation` in the same file owns the independent target-containment label and icon. Unmerged uses a neutral branch symbol, unproven ancestry a neutral question mark, and unexamined ancestry a neutral dashed circle. An old true result without an analyzed target cannot display green. The existing filled mint `checkmark.circle.fill` continues to mean current checkout. The branch fact group explicitly contains its separately labeled sync/merge accessibility elements.

All symbols were checked against Apple's installed `CoreGlyphs.bundle` availability catalog: the circular check/arrows/question mark date to macOS 10.15; branch/merge/link-plus/dashed-circle date to macOS 11.0. They therefore meet the macOS 14 API floor. Runtime `NSImage(systemSymbolName:)` availability is also asserted in native acceptance. Evidence: `.cache/branch-health-appearance-20261101/symbol-availability.json`. No image assets, dependencies or fixed RGB values were added.

### Files changed in this visual pass

| Files | Purpose |
| --- | --- |
| `Sources/GitPier/BranchHealthView.swift` | Extend the existing sync presentation/badge; add independent merge presentation and accessible fact grouping |
| `Sources/GitPier/RemoteCheckViews.swift` | Reuse the shared semantic colors for tracking-related network action icons; retain Fetch warning priority and action behavior |
| `Sources/GitPier/BranchHealthAcceptance.swift` | Extend the existing disposable native scope with symbol/color/merge assertions, all six Dashboard/Context scenarios, real contrast observation and viewport bounds |
| `README.md`, `README.zh-CN.md`, `CHANGELOG.md`, this report | Keep the public English/Chinese appearance descriptions and exact validation scope aligned |
| Local ignored `PROJECT_MEMORY.md` | Record the shared visual contract, current verification and remaining acceptance boundary |

### Verification for this visual pass

Evidence: `.cache/branch-health-appearance-20261101/`. Native host: **macOS 27.0.1, arm64**. The final native runs passed on the same frozen inputs; previous results in this document remain historical.

- `Scripts/test.sh --filter 'BranchHealthTests|ContextWorkflowTests'`: **32 tests passed, zero failures** (`core-focused.log`). Core code and tests remain byte-identical to task entry; no full Core rerun is implied.
- Isolated Debug build uses `CONFIGURATION=debug`, `CODE_SIGN_IDENTITY=-`, the `com.heisenberg2024.gitpier.workspace-test.branch-health-appearance` identity and an absolute `GITPIER_APP_OUTPUT_DIR`. Standard bundle/deep signature verification passed; version remains **1.9.0 (32)**, minimum **macOS 14**. No installation over the normal application.
- The existing native scope reads the actual system contrast and confirms the SwiftUI environment via a zero-size test probe. Set `GITPIER_UI_ACCEPTANCE_HEALTH_CONTRAST=standard` or `increased` to require a particular real setting. Standard and increased runs use separate evidence directories; no production preference or fake contrast override was added. [Apple documents contrast as a read-only user setting](https://developer.apple.com/documentation/swiftui/environmentvalues/colorschemecontrast), and [high-contrast AppKit appearances follow that system setting](https://developer.apple.com/documentation/appkit/nsappearance/name-swift.struct/accessibilityhighcontrastaqua).

| Final native run | Result | Evidence |
| --- | --- | --- |
| Actual standard contrast | **420 assertions passed; 40 system-composited captures** | `native-standard-final.log`, `native-standard-final/health-results.txt` |
| Actual increased contrast | **420 assertions passed; 40 system-composited captures** | `native-contrast-final.log`, `native-contrast-final/health-results.txt` |

Each run covers English/Simplified Chinese × light/dark, Branches/Dashboard at **1440pt and 960pt** (16 captures), and actual Context Workflow content for all six local-repository scenarios at a narrow **400pt content width** (24 captures). The existing no-upstream Context guidance intentionally has no upstream-comparison badge; its guidance/actions remain intact. Both complete runs exercise the real merge-target picker/Analyze action, merged versus unmerged icons, sync counts and accessibility text, viewport bounds, late-result rejection, local Fetch provenance and fixture Index preservation. The total is **840 assertions / 80 native window captures**; `*-render.png` companions are diagnostic only. Native captures were inspected across both languages, both themes and both real contrast settings; labels/counts stay readable and no new overflow was found. Long branch names retain their existing truncation.

Selected narrow-window captures (the full index is in `verification.json`):

| Language / theme | Standard contrast | Increased contrast |
| --- | --- | --- |
| English / light | [Branches](../.cache/branch-health-appearance-20261101/native-standard-final/branches-english-light-960.png) · [Dashboard](../.cache/branch-health-appearance-20261101/native-standard-final/dashboard-english-light-960.png) · [Context](../.cache/branch-health-appearance-20261101/native-standard-final/context-english-light-3.png) | [Branches](../.cache/branch-health-appearance-20261101/native-contrast-final/branches-english-light-960-contrast.png) · [Dashboard](../.cache/branch-health-appearance-20261101/native-contrast-final/dashboard-english-light-960-contrast.png) |
| English / dark | [Branches](../.cache/branch-health-appearance-20261101/native-standard-final/branches-english-dark-960.png) · [Dashboard](../.cache/branch-health-appearance-20261101/native-standard-final/dashboard-english-dark-960.png) · [Context](../.cache/branch-health-appearance-20261101/native-standard-final/context-english-dark-2.png) | [Branches](../.cache/branch-health-appearance-20261101/native-contrast-final/branches-english-dark-960-contrast.png) · [Dashboard](../.cache/branch-health-appearance-20261101/native-contrast-final/dashboard-english-dark-960-contrast.png) |
| 简体中文 / 浅色 | [分支](../.cache/branch-health-appearance-20261101/native-standard-final/branches-simplifiedChinese-light-960.png) · [工作空间](../.cache/branch-health-appearance-20261101/native-standard-final/dashboard-simplifiedChinese-light-960.png) | [分支](../.cache/branch-health-appearance-20261101/native-contrast-final/branches-simplifiedChinese-light-960-contrast.png) · [工作空间](../.cache/branch-health-appearance-20261101/native-contrast-final/dashboard-simplifiedChinese-light-960-contrast.png) |
| 简体中文 / 深色 | [分支](../.cache/branch-health-appearance-20261101/native-standard-final/branches-simplifiedChinese-dark-960.png) · [工作空间](../.cache/branch-health-appearance-20261101/native-standard-final/dashboard-simplifiedChinese-dark-960.png) | [分支](../.cache/branch-health-appearance-20261101/native-contrast-final/branches-simplifiedChinese-dark-960-contrast.png) · [工作空间](../.cache/branch-health-appearance-20261101/native-contrast-final/dashboard-simplifiedChinese-dark-960-contrast.png) · [上下文](../.cache/branch-health-appearance-20261101/native-contrast-final/context-simplifiedChinese-dark-contrast-5.png) |

With explicit user approval, Increase Contrast was temporarily enabled for the second run and then restored to **off**. Reduce Transparency, Show Borders and Differentiate Without Color remained **off** throughout; System Settings returned to its original General page. `display-settings-restoration.json` records the restoration. No other system preference was changed.

All **312** frozen build/native source, test, script and resource inputs remained unchanged across the final runs. GitPierCore, remote/workflow logic, branch reader/cache, Dashboard layout/cards, localization JSON and version configuration are byte-identical to task entry. Staged content remains empty. Only the three listed Swift UI/acceptance files and the appearance documentation changed in this pass; the pre-existing v1.9.0 changes remain pending. No staging, commit, project Push, release, normal-app installation or production-key operation occurred.

Intermediate failures and diagnostics are retained: the old synced symbol failed the initial regression; a read-only contrast environment could not be assigned; SwiftUI parent identifiers initially covered child identifiers; Dashboard intentionally exposes a combined accessible row; the contrast probe had to preserve observation across reused views. The final driver validates the real existing accessibility structures. The system `iconutil` packaging step required approved native execution after correct, unchanged PNG dimensions were verified. No product assertion was relaxed. Final packaging evidence is `build-observer.log`; no new dependencies or parallel test framework were introduced.

Limits: no actual Intel/macOS 14 hardware runtime or complete VoiceOver session was run. Catalog/API availability and local native accessibility are verified separately. No subagents or independent external reviewer were used. Baseline to final verification was approximately **18.2 minutes**; final native runs took **99.3s / 98.1s**. Initial computer-use binding waited **163.7s**; a separate explicit user confirmation covered the temporary display setting. A near-final Goal snapshot reported **18m45s / 306,452 cumulative tokens**; input/cache/output/reasoning breakdowns and response counts are unavailable. These metrics are not subscription usage. Machine-readable results and preserved-input evidence are in `verification.json` / `validated-inputs.json`.

Cumulative pending commit text, including the earlier uncommitted v1.9.0 work, is available at `.cache/branch-health-appearance-20261101/cumulative-commit-message.txt`. Providing it does not stage or commit files.

### Local Universal Release rebuild — 2026-11-01

The maintainer subsequently requested a local build. `GIT_OPTIONAL_LOCKS=0 CODE_SIGN_IDENTITY=- UNIVERSAL=1 Scripts/build-app.sh` generated **`dist/GitPier.app` 1.9.0 (32)** with the normal application identity and minimum macOS 14. All **7 Mach-O files contain arm64/x86_64**, and standard bundle/deep strict signature checks passed with ad-hoc signing. This includes the semantic appearance refinement above.

The first Release attempt exposed a Debug-only acceptance implementation referenced by an unconditional scope entry. `UIAcceptance.swift` now wraps that Branch Health entry in the same `#if DEBUG` condition. The failing compiler output is retained in `build.log`; the final green Universal run is `build-fixed.log`. Removing only the two new directive lines reproduces the prior Debug source exactly, and the Branch Health test-entry marker is absent from the final Release executable. No product behavior or version value changed. Core/native UI tests were not repeated for this conditional-compilation fix; their earlier results remain separate evidence.

Evidence is `.cache/local-build/20261101-024015-branch-health/`, including `verification.json`, `signature.txt` and `release-guard-fix.diff`. All **314** final build-input hashes/modes match the frozen post-fix manifest. The previous app's **182 items**, including bytes, modes and symlink targets, remain verified in `previous-dist/GitPier.app`. The repository Index file bytes changed during this build interval, while its staged diff remains identical to entry (empty); the Index was not replaced or restored. The app was not installed or launched, and no commit, Push, release or production-key operation was performed. Verification took approximately **7.2 minutes** including the failed initial attempt; subagents **0**, exact response/token breakdown unavailable.

### Initial visualization pass (historical)

Scope: finish the existing v1.9.0 native UI, without changing version, publishing, pushing or modifying user repositories. Implementation and acceptance run in the current development branch; pre-existing uncommitted work and Index are preserved. No subagents are authorized.

## Audit and implementation plan

- Existing `GitService.branchHealth` inventories refs in a bounded batch, reads native tracking counts and proves merged ancestry with `for-each-ref --merged`. Shallow unproven ancestry is already unknown. The page reader checks branch/HEAD/operation/list identities before publishing.
- Branches already renders a health column, but aligned/ahead/behind lack semantic labels; merged labels omit the target. The `main` text is a placeholder, not a real selected target. Replace it with a local-branch picker and a validated remote-HEAD suggestion, never a conventional-name guess.
- Dashboard and ContextWorkflow already consume porcelain branch counts and comparison validity. Share a typed six-state mapping with Branch Health, retaining each surface's existing collector and remote provenance. Do not introduce another Git scanner or combine synchronization with merged ancestry.
- Add real isolated-repository regressions for six sync states, exact counts, main/master defaults, invalid targets, ancestry versus equivalent patches, reference updates and Fetch. Verify reader rejection of late results, navigation, refresh and target changes through the native harness.
- Reuse native compact SF Symbol labels, secondary styling for routine states and orange for divergence/unknown. Preserve Dashboard structure, shared scrollbars, localization and accessibility. Branch names truncate; status and actions retain their width.
- Run focused Core tests, the normal Core suite, and `Scripts/ui-acceptance.sh` with a dedicated health scope. Capture English/Chinese × light/dark at normal and narrow widths, inspect actual screenshots, and record limitations below.

## Results

The missing behavior was primarily presentation/mapping, plus the missing real target selector. Existing Git analysis, actor/queues, Fetch policy, authentication and Git writes remain in place.

### Model and surfaces

| Source | Shared mapping / presentation |
| --- | --- |
| Native `for-each-ref` upstream tracking | `BranchHealth.syncState` maps valid counts to Synced, Ahead, Behind or Diverged; absent binding is No upstream, missing/insufficient counts are Unknown. Malformed counts cannot default to zero. |
| Porcelain `branch.upstream` / `branch.ab` | `RepositoryStatus.syncState` and `WorkspaceSnapshot.syncState` reuse the same mapping. Detached/unborn/unavailable comparison is Unknown. |
| Branches | Right-aligned `BranchSyncBadge`, commit counts, separate merged-into target label, independent current-checkout icon; names truncate while labels/actions keep their space. |
| Dashboard | Same semantic badge in the original Sync column, including accessibility; existing local observation and Fetch metadata remain available. Stale retained snapshots explicitly say outdated. |
| ContextWorkflow | Same typed state and badge, without a second scanner. Existing conflict/unfinished-operation and Fetch-freshness priorities/action restrictions remain unchanged; normal states do not open notifications. |

Merge target options come only from existing local branches. A local `refs/remotes/<remote>/HEAD` must resolve to an existing tracking ref and have an existing local counterpart before it can suggest a target. The current upstream remote disambiguates; otherwise conflicting defaults and absent metadata leave the picker unselected. No main/master convention is guessed and no server is contacted. The core rejects a removed target explicitly, with localized error text.

Merged ancestry still uses native `--merged=<fixed target hash>`. Merged, not merged, unproven (including shallow history) and not analyzed remain distinct. Squash and Cherry-pick equivalence do not prove ancestry. Changing the target cancels its pending result and immediately hides the old merge relation. Reader cache keys include page/selection identities; results additionally bind refresh generation, HEAD/branch/operation and every local row. External-change notifications invalidate the displayed health.

### Validation

Local evidence: `.cache/branch-health-20261101/`.

| Check | Actual result / evidence |
| --- | --- |
| Normal complete Core command | `Scripts/test.sh --parallel --num-workers 2 --jobs 4 --xunit-output .cache/branch-health-20261101/core-full.xml`: **1055 cases, zero failures/errors/skips**. |
| Final added boundaries and performance | `Scripts/test.sh --filter 'BranchHealthTests\|RepositoryPerformanceTests' --jobs 4`: **17 cases passed** (`final-focused.log`), including the subsequently added ambiguous-default and squash assertions. Production Core inputs match the complete run; these additions extend test coverage. |
| Focused integration | **91 passed**, covering health/context/workspace snapshots, Fetch and remote freshness (`integration.log`). |
| Native build | `CONFIGURATION=debug GITPIER_APP_OUTPUT_DIR=<absolute isolated output> BUNDLE_IDENTIFIER=com.heisenberg2024.gitpier.workspace-test.health190 CODE_SIGN_IDENTITY=- Scripts/build-app.sh`: passed bundle/signature checks, **1.9.0 (32), arm64** (`build.log`). No installation over the user app. |
| Native health | `GITPIER_UI_ACCEPTANCE_SCOPE=branch-health GITPIER_UI_ACCEPTANCE_EXECUTABLE=<isolated app executable> Scripts/ui-acceptance.sh .cache/branch-health-20261101/native`: passed (`native.log`, `native/health-results.txt`). |
| Existing native replay / health regression | Same isolated executable with `GITPIER_UI_ACCEPTANCE_SCOPE=replay`: passed, **38 recorded result lines** (`replay.log`, `replay/replay-results.txt`), including stale-row rejection and ambiguous Unicode refs. |

Core fixtures cover aligned, Ahead 3, Behind 2, Diverged 2/4, no upstream, missing upstream, main/master/ambiguous/missing defaults, merged/unmerged/nonexistent targets, shallow uncertainty, equivalent Cherry-pick/Squash, actual local-path Fetch and ref updates. Native checks exercise the real picker/Analyze action, all six branch and Dashboard facts, current-branch ContextWorkflow, target changes, same-repository navigation, switching repositories and branches, rejected late results, local-ref refresh, actual Fetch success time and full target identity. Health analysis preserves fixture Index bytes. No real user Git repository is mutated.

Native health passed **110 assertions**. Twenty final system-composited screenshots are retained: Branches and Dashboard at **1440pt and 960pt**, English/Simplified Chinese × light/dark (16), plus actual ContextWorkflow content in all four variants (4). `*-render.png` companions and accessibility dumps are diagnostics; visual acceptance uses the system-composited images. In this initial pass, routine states used secondary text/symbols and divergence/unknown used orange; the semantic appearance refinement above supersedes those colors and symbols. Long names truncate, counts/merge labels remain readable, both themes retain their native appearance, and Chinese dates follow the selected language.

Final local screenshot index:

| Language / theme | Branches | Dashboard | ContextWorkflow |
| --- | --- | --- | --- |
| English / light | [1440](../.cache/branch-health-20261101/native/branches-english-light-1440.png) · [960](../.cache/branch-health-20261101/native/branches-english-light-960.png) | [1440](../.cache/branch-health-20261101/native/dashboard-english-light-1440.png) · [960](../.cache/branch-health-20261101/native/dashboard-english-light-960.png) | [Content](../.cache/branch-health-20261101/native/context-english-light.png) |
| English / dark | [1440](../.cache/branch-health-20261101/native/branches-english-dark-1440.png) · [960](../.cache/branch-health-20261101/native/branches-english-dark-960.png) | [1440](../.cache/branch-health-20261101/native/dashboard-english-dark-1440.png) · [960](../.cache/branch-health-20261101/native/dashboard-english-dark-960.png) | [Content](../.cache/branch-health-20261101/native/context-english-dark.png) |
| 简体中文 / 浅色 | [1440](../.cache/branch-health-20261101/native/branches-simplifiedChinese-light-1440.png) · [960](../.cache/branch-health-20261101/native/branches-simplifiedChinese-light-960.png) | [1440](../.cache/branch-health-20261101/native/dashboard-simplifiedChinese-light-1440.png) · [960](../.cache/branch-health-20261101/native/dashboard-simplifiedChinese-light-960.png) | [内容](../.cache/branch-health-20261101/native/context-simplifiedChinese-light.png) |
| 简体中文 / 深色 | [1440](../.cache/branch-health-20261101/native/branches-simplifiedChinese-dark-1440.png) · [960](../.cache/branch-health-20261101/native/branches-simplifiedChinese-dark-960.png) | [1440](../.cache/branch-health-20261101/native/dashboard-simplifiedChinese-dark-1440.png) · [960](../.cache/branch-health-20261101/native/dashboard-simplifiedChinese-dark-960.png) | [内容](../.cache/branch-health-20261101/native/context-simplifiedChinese-dark.png) |

The initial API regression failed because the shared state/default-target API was absent (`red.log`), then passed after implementation. Native fixture corrections are retained: initial window activation superseded a direct reader request; the driver then mistook SwiftUI's AX popup for `NSPopUpButton`. It now waits for the existing refresh and navigates the real accessible menu with native keyboard events. One intermediate AppKit reentrant-table warning did not recur in the final health run. Product assertions were not weakened. Visual inspection prompted full-width separators, aligned action space and localized dates, followed by fresh captures.

### Files changed in this task

| Area | Files |
| --- | --- |
| Typed state / defaults | `Sources/GitPierCore/BranchHealth.swift`, `GitService.swift`, `ContextWorkflow.swift` |
| Native presentation / reader | `Sources/GitPier/BranchHealthView.swift`, `WorkflowViews.swift`, `RemoteCheckViews.swift`, `DashboardRepositoryRow.swift`, `ContextWorkflowView.swift` |
| Localization | `Sources/GitPier/Resources/zh-Hans.json` |
| Regression / native fixtures | `Tests/GitPierCoreTests/BranchHealthTests.swift`, `Sources/GitPier/BranchHealthAcceptance.swift`, `UIAcceptance.swift` |
| Documentation | CHANGELOG, both READMEs, `docs/architecture.md`, `development.md`, `v1.9.0-testing.md`, this report; local ignored `PROJECT_MEMORY.md` updated for shared model/cache/target rules and verification |

### Limits and execution notes

- “Synced” compares locally observed tracking tips. It never promises current server equality. Missing/mismatched Fetch provenance remains Unknown, and changes require normal Refresh/Fetch according to existing settings.
- Remote defaults are inferred only from valid local remote-HEAD metadata. No implicit network lookup fills missing metadata.
- This is local arm64/macOS acceptance. No new Intel/macOS 14 hardware, real private-server authentication, production update or complete VoiceOver session is claimed. Accessibility labels/values were exercised through native accessibility elements.
- No subagent or independent external reviewer was used in this task. Git mutation/authentication/queue behavior was not redesigned.
- Version configuration is byte-identical to task entry. No staging, commit, push, release, production certificate/key access or user-global Git/shell change occurred. The staged diff remains empty. Repository Index stat-cache bytes changed during ordinary Git/build checks; its staged content remains the same. Fixture Index bytes are separately verified unchanged.
- Baseline capture to final verification took approximately **18.6 minutes**; timing and machine-readable outcomes are in `verification.json`; SwiftPM's complete Core run held the shared build directory while the next native build waited. The final Goal snapshot reports **22m 32s / 280,072 cumulative tokens** (a broader interval than the filesystem baseline). Input/cache/output/reasoning breakdowns, response counts and subscription-window metrics are unavailable; no collection service was added. Subagents: **0**. Intermediate native driver failures and their logs remain available.
