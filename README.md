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
- **Consistent scrolling.** Lists, settings, help, commit messages, tabs, and terminal scrollback share the Diff's compact overlay scrollbars, which brighten while scrolling and fade when idle.
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

The **v1.4.2 development version (22, not released)** adds a native three-state **Select Matching** checkbox, including collapsed Worktrees. Confirming reviewed Fetch clears accepted selections; cancelling or failing admission retains them. Successful manual results collapse after five seconds; failures retain review/retry actions.

**Settings → Git → Automatic Remote Checks** is off by default and independent of local watching. Opt in to connect to configured remotes while GitPier is active: current repository every 15 minutes (10/30/60 also available), other workspace repositories approximately every 45 minutes, at most two Fetches in staggered batches. You can limit the scope or exclude the current repository. Checks use only the upstream remote, share matching Worktree targets, back off 5–60 minutes after failures, and stop automatic authentication retries until you run Fetch manually. Background authentication uses existing noninteractive credentials; unknown/custom helpers and SSH commands may require manual Fetch. Working files, Index, branches, tags and pruning remain under your control.

Local scans stay offline. Dashboard distinguishes matching tracking references from a freshly verified remote, with remote/local times and failures in tooltips. Fetch indicates checking/overdue/failure states; Pull and Push show nonzero counts and warn about divergence or missing upstream. Automatic refresh of tracking counts preserves drafts, Diff tabs and repository pages.

**Workspace Search** searches names, paths, organizations, branches and remote names, plus tracked file paths and commit messages/hashes on demand. Choose all/current organization/current repository/selected repositories; results open the repository, existing Diff/file history or commit detail. Git queries are cancellable and paged, with bounded results and output; no source-content index or third-party upload is used. **⌘⇧P** opens Quick Open with recent/favorite repositories and organization matching, arrow navigation, Return and Esc; terminal focus retains its keys. The Universal DMG is the current stable download; release validation is recorded in the [development guide](docs/development.md#v140-release-validation--2026-10-15).

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

## Security & privacy

Git operations run on your Mac. Managed HTTPS tokens are stored in macOS Keychain; workspace metadata and drafts are saved locally. GitPier has no repository-upload or analytics service. Remote operations communicate with the Git remotes you choose. Git hooks, credential helpers, and terminal commands execute with your user permissions and can access the network.

Commit review preserves the external Index and partial staging. Destructive operations require confirmation. GitPier does not automatically modify global Git, SSH, or shell configuration. See [security guidance](SECURITY.md) before sharing logs or reporting credential issues.

## Contributing

Bug reports and pull requests are welcome in the public repository. Please read [CONTRIBUTING.md](CONTRIBUTING.md), use a disposable repository to reproduce Git issues, and remove private data from attachments.

## License

GitPier is licensed under the [MIT License](LICENSE). Copyright (c) 2026 Heisenberg2024.

Third-party components retain their own licenses; see [third-party notices](THIRD_PARTY_NOTICES.md).
