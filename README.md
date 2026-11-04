<p align="center">
  <img src="Resources/Branding/gitpier-icon-1024.png" width="112" alt="GitPier application icon">
</p>
<h1 align="center">GitPier</h1>
<p align="center">
  <strong>Native Git Client for macOS</strong><br>
  All Your Repositories. One Workspace.
</p>
<p align="center">English · <a href="README.zh-CN.md">简体中文</a></p>

GitPier brings repository management, change review, commits, and an integrated terminal into one focused macOS workspace. Built with Swift, SwiftUI, and AppKit, it works with your local repositories and installed Git.

![Commit workspace with tracked and untracked changes, side-by-side Diff, and terminal](docs/screenshots/commit-workspace.png)

## Native workflow and visual refinements — v2.2.0

[v2.2.0 (36)](https://github.com/Heisenberg2024/gitpier/releases/tag/v2.2.0) is the current **Latest** release. It adds recognizable file type icons, continuous Commit & Push progress, synchronized two-axis Diff scrolling and a top-left reset when switching files. Dashboard alignment, settings sidebars, credential-source explanations, background notification sound and Codex CLI discovery are refined. Quick Open uses ⌘K; the primary sidebar retains its opaque background.

Released from `15db897` after exact-source full CI, Tag validation, Universal DMG and production Sparkle signature/asset/public-download checks. See the [changelog](CHANGELOG.md), [native validation and remaining limits](docs/v2.2.0-native-experience.md) and [publication evidence](docs/development.md#v220-publication--2026-11-05). The application remains ad-hoc signed; Developer ID and Apple notarization are separate future work.

## Push recovery and workspace performance — v2.1.0

[v2.1.0 (35)](https://github.com/Heisenberg2024/gitpier/releases/tag/v2.1.0) introduced Push recovery and workspace performance improvements. Operations Center retains unresolved checkpoints, offers full-hash copying and History navigation, and explicitly verifies a saved single-branch Push against its original remote reference. A retry reviews and rechecks the original source/target and never creates another commit. Context advice highlights earlier unverified results.

Dashboard scans reuse metadata within each collection, coalesce refresh notifications and reuse remote-check presentation within each render. Push preflight reuses observations only within a validation phase and retains fresh checks at every boundary. The [performance follow-up](docs/v2.1.0-performance.md) records matched comparisons and their limits. The standalone `Marketing/hero-demo/` package has been removed from the current tree. See the [development plan](docs/v2.1.0-plan.md), [validation and remaining limits](docs/v2.1.0-testing.md) and [publication evidence](docs/development.md#v210-publication--2026-11-03).

## Stability and performance — v2.0.1

[v2.0.1 (34)](https://github.com/Heisenberg2024/gitpier/releases/tag/v2.0.1) introduced maintenance fixes for repository refresh and interrupted Git operations. Repository refresh avoids repeated Git queries while retaining final consistency checks. Interrupted commits retain their diagnostics and require verification when completion is uncertain; recovery Push keeps its commit and destination without repeating Commit or Merge.

The Universal installer supports macOS 14 or later. See [release validation and remaining limits](docs/v2.0.1-testing.md) and [publication evidence](docs/development.md#v201-publication--2026-11-02). Developer ID signing and Apple notarization remain separate future work.

## Product quality and native experience — v2.0.0

v2.0.0 strengthens reviewed Index snapshots, preserves local Commit success through later Push failures or cancellation, and bounds rapid Diff reads using the existing workspace budget. Native refinements cover History selection and keyboard navigation, meaningful operation states, per-operation diagnostics and language-aware dates. Dashboard scheduling is measured against reproducible large inventories.

Released [v2.0.0 (33)](https://github.com/Heisenberg2024/gitpier/releases/tag/v2.0.0) as **Latest** on 2026-11-02 from `b99f72f`. Same-source Swift 6.1.2 CI passed 1,065 Core tests with zero failures/errors/skips; Universal packaging, production update signatures, asset readbacks and public downloads/Latest Feed were verified. See [publication evidence and limits](docs/development.md#v200-publication--2026-11-02).

The [roadmap](ROADMAP.md), [implementation record](docs/v2.0.0-plan.md) and [quality validation](docs/v2.0.0-testing.md) retain measured tradeoffs and unverified coverage. Developer ID and Apple notarization remain a separate future milestone.

## Features

- **Multi-repository management.** Switch between repositories and worktrees, organize projects into collections, and drag repositories to save their order in the sidebar and organization pages. Opening a repository from an organization adds it to that organization.
- **Focused commits.** Choose changes with independent file checkboxes, review the selected content, and commit or commit and push. Preserve existing partial staging and changes staged by other tools. A bounded review shows specific Index, HEAD and branch changes; **Reviewed, Commit Later** acknowledges only that snapshot, while further changes still require review and are checked again at commit time.
- **Recognizable file types.** Source, script, configuration, document and media files use distinct bundled vector icons across file lists and Diff tabs. Ignore files share a neutral outlined circle-slash icon. Light/dark themes and the existing Colored file icons setting apply throughout; filename colors continue to show Git status.
- **Recover rejected pushes.** When the remote branch has new commits, confirm Merge & Push to fetch, merge, and retry the push. Local commits remain saved; conflicts stop the push for you to resolve. Commit or stash remaining tracked changes before merging.
- **Resolve conflicts in GitPier.** Compare Current and Incoming versions, preview the base, choose either side or both for each conflict, and edit the result. Save and mark files resolved, then review and continue the merge; a pending merge-and-push keeps its original destination. Binary and large files support whole-file choices, including deletion.
- **Finish merges with no file changes.** A pending merge stays visible across repository pages. The Commit page offers Complete Merge even with an empty file list and no draft; review the ordered parents, merge message and staged result before creating the merge commit.
- **Side-by-side Diff.** Compare changes with line numbers, syntax colors, synchronized horizontal and vertical scrolling, and subtle scrollbars. Switching files returns the Diff to the top-left. An empty Index side gives the working tree the full width. Stage, unstage, or discard supported hunks, and keep files open in Diff tabs.
- **Consistent scrolling.** Lists, settings, help, commit messages, tabs, sheets, popovers, nested editors, and terminal scrollback share the Diff's compact overlay scrollbars, which brighten while scrolling and fade when idle. The Commit file list reuses native rows to keep large change sets responsive.
- **Integrated terminal.** Run your installed shell in a real PTY, with multiple tabs, splits, and search. Each repository keeps its own sessions and working directory.
- **History and branches.** Browse the commit graph and manage branches, remotes, stashes, and tags. Fetch, pull, push, merge, and rebase using Git.
- **Revert merges with a reviewed mainline.** History → Revert lists a merge's numbered parents with their hashes and subjects. Choose the parent to use as the mainline, then confirm a new revert commit. Existing history stays intact; GitPier rechecks the working tree and Index, retains hooks/signing and conflict recovery, and does not push automatically.
- **Full history and stash previews.** Native paged full-history queries add message, hash, author, date and branch filters. Stash previews reuse the file list and side-by-side Diff.
- **Persistent history review.** History uses the same Diff renderer and scrollbars as the commit workspace. Resize the detail pane once per repository; click the selected commit again or press Esc to close it.
- **Editors and help.** Select your default editor from a priority-sorted list with application icons, or add custom Apps from the dropdown. The repository and commit-file context menus provide an Open in Editor submenu with application icons for one-time editor choices. The Help menu opens an offline English / Simplified Chinese guide.
- **Managed credentials.** Store HTTPS tokens in macOS Keychain and select SSH identity profiles. Existing Git helpers, SSH configuration, hooks, and commit signing remain available.

English and Simplified Chinese interfaces, light and dark themes, and system appearance are included. Repository clicks and returning to the foreground refresh current data; **⌘R** remains available. Optional file watching indicates external changes. Operations use one continuous progress track: repository refresh uses the system's flowing waiting animation and hides the track on completion, retaining its result icon, text and reserved space. Push and Commit & Push fill from left to right as Git reports transfer progress and finish on confirmed success. Changes and staging stay at the far left of the repository footer; its wider progress track shortens in smaller windows and keeps a fixed starting position, independent of pane dividers. Completion notices show the final operation result after transfer progress finishes.

Opening or selecting a repository always shows the Commit page; the current page is not persisted. Collapse or expand all organization repositories with one sidebar button.

## Professional workflows and repository health — v1.9.0

v1.9.0 adds an ordered review for 1–200 History commits, full commit IDs, target Worktree/branch/HEAD and the existing Diff. Cherry-pick uses Git's native sequencer; duplicate patches and empty results stop for explicit recovery, and merge commits are refused rather than guessing a mainline. Ordinary and merge Revert share a bounded confirmation and Diff entry; merge Revert still requires an explicit parent. Continue, Skip and Abort recheck the original repository and reviewed state, and confirmed writes survive page dismissal.

Branches adds read-only local health: upstream existence, ahead/behind/divergence, recent activity, occupied Worktrees and optional ancestor-based merged-into analysis against a selected existing local branch (with a validated remote-HEAD suggestion). Observation time and the last app Fetch (or Unknown) describe provenance; no Fetch or cleanup runs implicitly. Inactivity does not establish deletion safety. Branches, Dashboard and contextual guidance share typed Synced / Ahead / Behind / Diverged / No upstream / Unknown labels and accessible counts; merged, unmerged, unproven and not-analyzed ancestry remain separate. Native status symbols use green for synced/merged, adaptive primary text for ahead, blue for behind, orange for divergence and neutral gray for unknown/no upstream; checkout, sync and merge have distinct icons. Dashboard and contextual guidance retain their existing local snapshot collectors and recovery links.

Released [v1.9.0 (32)](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.9.0) as **Latest** on 2026-11-01 from `9df9364`. Exact-source Swift 6.1.2 CI passed 1056 Core tests; the Universal DMG, production update signatures and public downloads/Latest Feed were verified. See [publication evidence and limits](docs/development.md#v190-publication--2026-11-01) and [development validation / unrun hardware and distribution checks](docs/v1.9.0-testing.md).

## Professional Git workflows — v1.2.0

Released [v1.2.0](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.2.0) adds Reflog recovery, guarded Worktree lifecycle management, arbitrary local/remote-tracking branch comparison, and Git Blame. These use native Git queries and the existing macOS panels; recovery defaults to a new branch, comparison/Blame are read-only, and unknown or dirty worktree directories cannot be deleted. Blame supports UTF-8 text up to 4 MiB with 400-line pages. See the [changelog](CHANGELOG.md) and [development validation](docs/development.md). Install from GitHub Latest Release or use Check for Updates from v1.1.0.

## Commit and repository workflows — v1.3.0

Released [v1.3.0](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.3.0) (build 19) adds Interactive Rebase with reviewed Pick/Reword/Squash/Fixup/Drop plans, commit reordering, native conflict handling and reviewed Continue/Skip/Abort recovery for linear histories of up to 200 commits. Hooks, signing, partial staging and the production update identity remain protected. Local and release validation are recorded in the [development guide](docs/development.md#v130-release-validation--2026-10-15).

Menus use compact labels without extra disclosure indicators, Rebase action controls align with the drag glyphs, and About fits on one Settings page. Opting into automatic checks enables checks at launch and on Sparkle's regular schedule, with native update reminders; downloads and installation still require confirmation.

Select individual changed lines in the Diff gutter and Stage/Unstage them while retaining other staged and working changes. Line actions support bounded regular-text modifications, CRLF and missing final newlines; complex file changes and filters retain file/hunk workflows. Refreshing or changing the file/comparison clears the selection.

Export file, hunk, selected-line, commit or endpoint-range patches; preview and check ordinary Diff patches before applying them to the Working Tree or Index as distinct targets. Commit email export uses format-patch; email import/git am, rename/copy/symlink/gitlink imports and binary deltas remain terminal workflows. Import is limited to 8 MiB / 200 files, with bounded literal binary data.

The Git LFS page detects the optional installed tool, shows rules/files/OIDs/pointers, reviews root .gitattributes edits and offers confirmed Fetch/Pull with existing credentials. It never installs LFS, filters or hooks, converts existing files, or stages rules automatically. Submodules show declared/registered URLs and HEAD/Index/parent gitlinks, offer reviewed Init/Sync/Add and separate recorded/remote commit checkout, and open children in GitPier, editors or terminals. Nested entries are read-only until their parent repository is opened. Deinit/removal and automatic recursive updates remain unavailable.

## Workspace overview — v1.4.0

Released [v1.4.0](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.4.0) (build 20) adds a local workspace overview with scanned/total counts, modified/staged/ahead/behind/conflict/unavailable/favorite filters, selection, and expandable related Worktrees. Cards use a separate memory cache and bounded background queries; opening Dashboard does not load every repository's Diff or history. Startup scans are local. Ahead/behind describes local tracking references, not a live server check; missing upstreams and unavailable repositories remain explicit. Optional external-change watching still marks data as needing refresh.

Version [v1.4.1](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.4.1) (build 21) adds a centered, adaptive layout with five clickable overview metrics, a search field and compact filter chips, aligned repository/branch/changes/sync columns, and a contextual selection bar. Metrics and filters use the same combined-match rules. Small windows keep branch information below the repository name; collapsed Worktrees remain part of matching counts and selection. Error details and refresh are available from unavailable rows. Clone, organization management and Quick Open are in the header's More menu.

Select individual entries, organization matches or all matches, then review **Fetch Selected** with each repository and remote. Selection is preserved when searching or filtering, including an explicit count outside the current results. Fetch uses bounded concurrency, deduplicates related Worktrees with matching remote configurations, preserves the working tree, Index and FETCH_HEAD, and keeps independent success/failure/cancellation results with reviewed retries. No batch Pull, Push, Reset or Rebase is added.

Released [v1.4.2](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.4.2) (build 22) adds a native three-state **Select Matching** checkbox, including collapsed Worktrees. Confirming reviewed Fetch clears accepted selections; cancelling or failing admission retains them. Successful manual results collapse after five seconds; failures retain review/retry actions.

**Settings → Git → Automatic Remote Checks** is off by default and independent of local watching. Opt in to connect to configured remotes while GitPier is active: current repository every 15 minutes (10/30/60 also available), other workspace repositories approximately every 45 minutes, at most two Fetches in staggered batches. You can limit the scope or exclude the current repository. Checks use the branch remote, or Git's default remote when no upstream is set, share matching Worktree targets, back off 5–60 minutes after failures, and pause authentication failures until a credential-change event or **Retry Automatic Check** in Git settings. Existing Git credentials, configured helpers, HTTP authentication, configured Askpass providers, SSH agents, identity files and native wallets support the first automatic Fetch without a preliminary manual Fetch. Public repositories need no saved credential. The settings show the source and capability; **Authorize Background Access** requests Keychain permission only after a user click, and **Prepare SSH Authentication** loads an identity into an agent without fetching. Git chooses authentication using its original configuration, independent of host or helper name. New terminal login and GitPier fallback login UI are disabled; configured native Askpass providers and helpers retain their authorization behavior. Working files, Index, branches, tags and pruning remain under your control.

Local scans stay offline. Dashboard distinguishes matching tracking references from a freshly verified remote, with remote/local times and failures in tooltips. Fetch indicates checking/overdue/failure states; Pull and Push show nonzero counts and warn about divergence or missing upstream. Automatic refresh of tracking counts preserves drafts, Diff tabs and repository pages.

**Released [v1.4.3](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.4.3) (build 23):** Dedicated background credential helpers suppress legacy login-Keychain authorization UI and stop for manual authentication when a secret cannot be read silently. This fixes repeated authorization requests during Automatic Fetch in v1.4.2. Until the fix is installed, affected v1.4.2 users should leave Automatic Fetch off. Manual authentication and existing credential access controls are retained.

**Released [v1.4.4](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.4.4) (build 24).** Automatic Fetch reuses native Git authentication for HTTP, HTTPS, SSH, Git and local transports across GitHub, GitLab, Gitee and other hosts. Configured named, absolute-path and shell credential helpers retain their order, URL/account/path matching and protocol responses; automatic Git requests only get, never store/erase. There is no password or Agent prerequisite before Fetch: public repositories work anonymously, and the actual server decides whether authentication is needed. SSH keeps its original commands, config, Agent, file identities, providers and native Keychain behavior. Terminal clones, GitPier clones and init/push repositories use the same flow; Clone saves an explicitly selected account before automatic checks can start. HTTP remains unencrypted and settings show a warning; GitPier-managed HTTPS Tokens still refuse HTTP. Existing credentials must be accessible to the app's Git process; an unsaved password or environment confined to another terminal session cannot be recovered. See [security boundaries](SECURITY.md) and [validation details](docs/development.md#unified-native-authentication).

**Workspace Search** searches names, paths, organizations, branches and remote names, plus tracked file paths and commit messages/hashes on demand. Choose all/current organization/current repository/selected repositories; results open the repository, existing Diff/file history or commit detail. Git queries are cancellable and paged, with bounded results and output; no source-content index or third-party upload is used. **⌘K** opens Quick Open with recent/favorite repositories and organization matching, arrow navigation, Return and Esc; terminal focus retains its keys. The Universal DMG is the current stable download. See the [publication evidence](docs/development.md#v210-publication--2026-11-03).

## Code hosting & credential storage — v1.5.0

Native Code Hosting settings add GitHub Device Flow, GitLab browser authorization with S256 PKCE, and Gitea public-client PKCE with a local loopback callback. Cards use official platform marks and open from anywhere inside the card. GitHub opens its verification page automatically; GitLab opens an ordinary default-browser tab and validates its application callback with State/PKCE, avoiding the system authentication-session prompt. PAT remains available. GitHub.com and GitLab.com public Client IDs are bundled, so ordinary users can connect without registering an application. Self-hosted instances have their own public configuration. No Client Secret or GitPier backend is required.

Connect multiple accounts and link each repository to an account and Remote. New OAuth and PAT accounts default to a Local Encrypted Vault (AES-256-GCM, independent random keys saved on this Mac), restored on demand after restart without OAuth Keychain prompts. macOS Keychain remains available per account, with explicit Verify after restart. Change the default for future accounts or confirm a per-account migration in Code Hosting settings. Refresh is merged per account and saves the complete rotated pair; saving failures are reported as session-only. Local keys and ciphertext together can recover tokens; see [credential storage and security](docs/credential-storage.md). Existing Git credentials, helpers, SSH, remotes, upstreams and Automatic Fetch remain independent.

Repository → More → Pull / Merge Requests provides paged lists, details, exact-commit CI/Pipeline, commits, read-only file diffs and reviews/comments. Create a PR/MR only after pushed-branch checks and confirmation; GitPier never auto-pushes or blindly retries uncertain creation. Dashboard adds a small connected-repository summary. Broad write scopes require explicit reauthorization. Real platform OAuth/private API acceptance results are recorded in the development guide; isolated tests do not substitute for real login. See [OAuth registration and limitations](docs/oauth-setup.md) and [development validation](docs/development.md).

## Hosting stability — v1.5.1

Disconnect stops the account session and removes its bindings before credential cleanup. Copies that macOS refuses to delete stay visible as disconnected credentials awaiting an explicit cleanup retry; they cannot restore the account after restart.

Request Overview, Commits, Files, Reviews and CI load independently on demand, with separate errors, paging, cancellation, cache and retry. Unavailable review APIs do not block files or commits, and denied CI access is shown as a permission error. Remote Diff remains read-only. See [validation and remaining real-platform checks](docs/development.md#v151-hosting-stability-validation).

## Code review & collaboration — v1.6.0

Released [v1.6.0](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.6.0) (build 27) adds confirmed comments, threaded replies and review drafts using each provider's native API semantics. Targets and line anchors bind to the exact account, repository and commit; unknown results preserve drafts and block automatic resubmission. GitHub review decisions and multiline comments, GitLab Discussions/Approval, thread resolution and approval rules, and Gitea's verified capabilities are documented in the [code review guide](docs/code-review.md). It also adds additive GitHub/Gitea reviewer requests and on-demand inbox/current-branch shortcuts. Local comparison explicitly uses this Mac's branch and remote-tracking snapshots. Gitea formal reviews and unsafe or unverified operations retain browser fallbacks. CI and fixture acceptance are recorded separately from real-service write acceptance in the [development guide](docs/development.md#v160-publication--2026-10-18).

## Review stability — v1.6.1

Released [v1.6.1](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.6.1) (build 28) saves minimal operation intent before confirmed review writes and keeps unknown results visible across restart. Bodies and code are not saved; reopening never resends a request. Inspect known receipts read-only, check the platform and explicitly acknowledge the result before a new preview. Disconnect confirms draft loss across windows. See [recovery and platform limits](docs/code-review.md) and [validation status](docs/v1.6.1-validation.md). Exact-commit Swift 6.1.2 CI passed 855 Core tests and 10 release gates; signed public downloads and the Latest update Feed were verified. Authorized test repositories have 17 verified review operations and one GitLab ordinary comment retained as Unknown; approvals and reviewer requests still lack eligible test accounts. See the validation matrix for exact scope.

## Workflow integration — v1.7.0

Released [v1.7.0](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.7.0) (build 29) adds a shared [Operations Center](docs/operations-center.md), commands in the existing **Quick Open**, and the navigation-only [GitPier CLI](docs/cli.md). Run `gitpier open . --page history` to return from a terminal to the selected app. Install/uninstall in Settings → Terminal; existing files and shell configuration are preserved. These additions retain existing Git write confirmations, credentials and Review Journal recovery. The contextual assistant includes five factual status levels, a native frosted popover and the lingering blue-outline fix. Exact-source Swift 6.1.2 CI passed 932 Core tests; independent review, signed asset readback and public downloads passed. See [publication evidence and remaining system checks](docs/development.md#v170-publication--2026-10-19).

The [contextual workflow assistant](docs/context-workflow.md) lives in a compact status button **before the repository branch name**. Neutral, suggestion, attention, warning and conflict/blocked states use distinct symbols with a stable width; incoming tracking commits alone never imply a conflict. Its native frosted popover shares one system surface across the body and arrow, dismisses with Escape/outside click/the entry, and explains the next useful step using the selected Worktree, branch, edits and Fetch snapshot. Risks take priority; ordinary review already available on the Commit page stays quiet. Comparisons open immediately and read local tracking snapshots in the background; synchronization review keeps its write button disabled until checking completes. Existing confirmations and target revalidation remain in place. A pending merge has its own status banner until completion or abort; the assistant does not run Git work automatically.

## Commit and merge reliability — v1.8.1

Released [v1.8.1](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.8.1) (build 31) on 2026-10-29. It improves scrolling in large Commit file lists, fixes loading staged binary assets, keeps empty-diff merges available for completion, and adds reviewed mainline selection when reverting merge commits. Exact-source full CI passed 1010 Core tests; Universal DMG, production update signatures and public downloads/Latest Feed passed verification. See [publication evidence and limits](docs/development.md#v181-publication--2026-10-29).

## Task Workspaces — v1.8.0

Released [v1.8.0](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.8.0) (build 30) on 2026-10-22. Exact-source Swift 6.1.2 CI and local packaging passed 993 Core tests; Universal DMG, production update signatures, asset readback and public downloads passed verification. See [publication evidence and remaining checks](docs/development.md#v180-publication--2026-10-22).

Commit confirmations compare the reviewed Index, HEAD and branch snapshots, explain actual changes and stop repeating obsolete warnings. Genuine changes still require validation, preserving partial staging, hooks and signing. Long file lists scroll within bounded confirmations while action buttons remain visible.

Detail navigation follows the initiating task, repository and page selection. Switching away rejects late opening before selection commits; successful selection remains successful when its source view closes. Repeated Open Terminal actions reuse a live task terminal. Confirmed review and archive writes keep their independent lifetime.

The [task workspace workflow](docs/task-workspaces.md) adds independent task worktrees, local baselines, explicit review and metadata-only archive. An optional installed Codex CLI starts only after confirmation in the selected worktree's existing PTY. Review includes both agent-created commits and Index/working changes. External URL requests now require confirmation before adding an unknown repository. Creation failures retain recoverable registration records. Successful task registration is separate from automatic opening: navigation failures keep the saved task and offer Open Task again. Detail refreshes never cancel confirmed review or archive writes. Optional login checks reuse the CLI environment without reading credentials; an advanced Codex Home setting supports Finder launches.

## Screenshots


### Side-by-side Diff

![Swift changes with line numbers and hunk staging controls](docs/screenshots/diff-viewer.png)

### Integrated terminal

![Repository shell with multiple terminal tabs and Git output](docs/screenshots/integrated-terminal.png)

### Repository dashboard

![Workspace dashboard containing four demonstration repositories](docs/screenshots/repository-dashboard.png)

## Installation

GitPier requires **macOS 14 or later**.

Download the current stable version from [GitHub Latest Release](https://github.com/Heisenberg2024/gitpier/releases/latest). Choose the universal DMG attached to the latest release. Open the DMG, drag the real GitPier icon to Applications, and launch GitPier from Applications.

The v1.1.0 updater uses Sparkle 2, GitHub Releases, and EdDSA-signed DMGs. Automatic checks default to off; downloads and installation require confirmation. The production public key is configured; release assets must be signed and verified before publication. v1.0.3 requires a one-time manual upgrade.

The upcoming [native experience refinement](docs/v2.2.0-native-experience.md) enables update checks by default for new installations while keeping explicit opt-outs. The stable release remains v2.1.0; downloads and installation still require confirmation.

Current builds use ad-hoc signing without Apple Developer ID or Apple notarization. Gatekeeper may show a warning on first installation. Verify the source and follow macOS's available security choices; do not disable Gatekeeper or remove quarantine attributes.


## Build from source

Use macOS with **Xcode 16 or later**, its command-line tools, **Swift 6.0 or later**, and Git. Dependencies are managed by Swift Package Manager and locked in `Package.resolved`. Open `Package.swift` in Xcode to browse the project, or build the application from the repository root:

```bash
Scripts/build-app.sh
open dist/GitPier.app
```

The script builds a Release application for the current architecture, packages resources, and applies a local ad-hoc signature. For a local universal DMG candidate containing Apple silicon and Intel binaries (requires a Finder GUI session):

```bash
Scripts/package-release.sh --unsigned-candidate
```

See [development](docs/development.md) for tests and build options, and [architecture](docs/architecture.md) for implementation details.

CI uses lightweight checks for ordinary documentation changes. Main/tag runs for the same commit reuse only proven full macOS validation; every release commit must have passed all Core, signing, bundle and DMG checks. Manual runs always perform full validation. See the [CI policy](docs/development.md#ci-validation-policy).

Full CI uses two test workers and toolchain-scoped SwiftPM build caches. Content-verified input timestamps allow unchanged sources to reuse compilation across fresh checkouts. Every test and release gate still runs on a cache hit; bounded steps and retained test diagnostics make stalled or failed runs easier to investigate.

## Security & privacy

Git operations run on your Mac. Managed HTTPS tokens are stored in macOS Keychain; workspace metadata and drafts are saved locally. GitPier has no repository-upload or analytics service. Remote operations communicate with the Git remotes you choose. Git hooks, credential helpers, and terminal commands execute with your user permissions and can access the network.

Commit review preserves the external Index and partial staging. Destructive operations require confirmation. GitPier does not automatically modify global Git, SSH, or shell configuration. See [security guidance](SECURITY.md) before sharing logs or reporting credential issues.

## Contributing

Bug reports and pull requests are welcome in the public repository. Please read [CONTRIBUTING.md](CONTRIBUTING.md), use a disposable repository to reproduce Git issues, and remove private data from attachments.

## License

GitPier is licensed under the [MIT License](LICENSE). Copyright (c) 2026 Heisenberg2024.

Third-party components retain their own licenses; see [third-party notices](THIRD_PARTY_NOTICES.md).
