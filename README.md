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

## Features

- **Multi-repository management.** Switch between repositories and worktrees, organize projects into collections, and drag repositories to save their order in the sidebar and organization pages. Opening a repository from an organization adds it to that organization.
- **Focused commits.** Choose changes with independent file checkboxes, review the selected content, and commit or commit and push. Preserve existing partial staging and changes staged by other tools.
- **Recover rejected pushes.** When the remote branch has new commits, confirm Merge & Push to fetch, merge, and retry the push. Local commits remain saved; conflicts stop the push for you to resolve. Commit or stash remaining tracked changes before merging.
- **Resolve conflicts in GitPier.** Compare Current and Incoming versions, preview the base, choose either side or both for each conflict, and edit the result. Save and mark files resolved, then review and continue the merge; a pending merge-and-push keeps its original destination. Binary and large files support whole-file choices, including deletion.
- **Side-by-side Diff.** Compare changes with line numbers, syntax colors, synchronized vertical scrolling, and subtle scrollbars. An empty Index side gives the working tree the full width. Stage, unstage, or discard supported hunks, and keep files open in Diff tabs.
- **Consistent scrolling.** Lists, settings, help, commit messages, tabs, sheets, popovers, nested editors, and terminal scrollback share the Diff's compact overlay scrollbars, which brighten while scrolling and fade when idle.
- **Integrated terminal.** Run your installed shell in a real PTY, with multiple tabs, splits, and search. Each repository keeps its own sessions and working directory.
- **History and branches.** Browse the commit graph and manage branches, remotes, stashes, and tags. Fetch, pull, push, merge, and rebase using Git.
- **Full history and stash previews.** Native paged full-history queries add message, hash, author, date and branch filters. Stash previews reuse the file list and side-by-side Diff.
- **Persistent history review.** History uses the same Diff renderer and scrollbars as the commit workspace. Resize the detail pane once per repository; click the selected commit again or press Esc to close it.
- **Editors and help.** Select your default editor from a priority-sorted list with application icons, or add custom Apps from the dropdown. The repository and commit-file context menus provide an Open in Editor submenu with application icons for one-time editor choices. The Help menu opens an offline English / Simplified Chinese guide.
- **Managed credentials.** Store HTTPS tokens in macOS Keychain and select SSH identity profiles. Existing Git helpers, SSH configuration, hooks, and commit signing remain available.

English and Simplified Chinese interfaces, light and dark themes, and system appearance are included. Repository clicks and returning to the foreground refresh current data; **⌘R** remains available. Optional file watching indicates external changes. Completion notices show the final operation result after transfer progress finishes.

Opening or selecting a repository always shows the Commit page; the current page is not persisted. Collapse or expand all organization repositories with one sidebar button.

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

**Workspace Search** searches names, paths, organizations, branches and remote names, plus tracked file paths and commit messages/hashes on demand. Choose all/current organization/current repository/selected repositories; results open the repository, existing Diff/file history or commit detail. Git queries are cancellable and paged, with bounded results and output; no source-content index or third-party upload is used. **⌘⇧P** opens Quick Open with recent/favorite repositories and organization matching, arrow navigation, Return and Esc; terminal focus retains its keys. The Universal DMG is the current stable download; release validation is recorded in the [development guide](docs/development.md#v144-release-validation--2026-10-16).

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

Released [v1.7.0](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.7.0) (build 29) adds a shared [Operations Center](docs/operations-center.md), commands in the existing **⌘⇧P Quick Open**, and the navigation-only [GitPier CLI](docs/cli.md). Run `gitpier open . --page history` to return from a terminal to the selected app. Install/uninstall in Settings → Terminal; existing files and shell configuration are preserved. These additions retain existing Git write confirmations, credentials and Review Journal recovery. The contextual assistant includes five factual status levels, a native frosted popover and the lingering blue-outline fix. Exact-source Swift 6.1.2 CI passed 932 Core tests; independent review, signed asset readback and public downloads passed. See [publication evidence and remaining system checks](docs/development.md#v170-publication--2026-10-19).

The [contextual workflow assistant](docs/context-workflow.md) lives in a compact status button **before the repository branch name**. Neutral, suggestion, attention, warning and conflict/blocked states use distinct symbols with a stable width; incoming tracking commits alone never imply a conflict. Its native frosted popover shares one system surface across the body and arrow, dismisses with Escape/outside click/the entry, and explains the next useful step using the selected Worktree, branch, edits and Fetch snapshot. Risks take priority; ordinary review already available on the Commit page stays quiet. Comparisons open immediately and read local tracking snapshots in the background; synchronization review keeps its write button disabled until checking completes. Existing confirmations and target revalidation remain in place, with no permanent banner, duplicate navigation menu or automatic Git work.

## Task Workspaces — v1.8.0 development

The [task workspace workflow](docs/task-workspaces.md) adds independent task worktrees, local baselines, explicit review and metadata-only archive. An optional installed Codex CLI starts only after confirmation in the selected worktree's existing PTY. Review includes both agent-created commits and Index/working changes. External URL requests now require confirmation before adding an unknown repository. This development version has not been published. Creation failures retain recoverable registration records. Optional login checks reuse the CLI environment without reading credentials; an advanced Codex Home setting supports Finder launches.

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

## Security & privacy

Git operations run on your Mac. Managed HTTPS tokens are stored in macOS Keychain; workspace metadata and drafts are saved locally. GitPier has no repository-upload or analytics service. Remote operations communicate with the Git remotes you choose. Git hooks, credential helpers, and terminal commands execute with your user permissions and can access the network.

Commit review preserves the external Index and partial staging. Destructive operations require confirmation. GitPier does not automatically modify global Git, SSH, or shell configuration. See [security guidance](SECURITY.md) before sharing logs or reporting credential issues.

## Contributing

Bug reports and pull requests are welcome in the public repository. Please read [CONTRIBUTING.md](CONTRIBUTING.md), use a disposable repository to reproduce Git issues, and remove private data from attachments.

## License

GitPier is licensed under the [MIT License](LICENSE). Copyright (c) 2026 Heisenberg2024.

Third-party components retain their own licenses; see [third-party notices](THIRD_PARTY_NOTICES.md).
