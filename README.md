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
- **v1.1.0 development.** Native paged full-history queries add message, hash, author, date and branch filters. Stash previews reuse the file list and side-by-side Diff.
- **Persistent history review.** History uses the same Diff renderer and scrollbars as the commit workspace. Resize the detail pane once per repository; click the selected commit again or press Esc to close it.
- **Editors and help.** Select your default editor from a priority-sorted list with application icons, or add custom Apps from the dropdown. The repository and commit-file context menus provide an Open in Editor submenu with application icons for one-time editor choices. The Help menu opens an offline English / Simplified Chinese guide.
- **Managed credentials.** Store HTTPS tokens in macOS Keychain and select SSH identity profiles. Existing Git helpers, SSH configuration, hooks, and commit signing remain available.

English and Simplified Chinese interfaces, light and dark themes, and system appearance are included. Repository clicks and returning to the foreground refresh current data; **⌘R** remains available. Optional file watching indicates external changes. Completion notices show the final operation result after transfer progress finishes.

Opening or selecting a repository always shows the Commit page; the current page is not persisted. Collapse or expand all organization repositories with one sidebar button.

## Screenshots


### Side-by-side Diff

![Swift changes with line numbers and hunk staging controls](docs/screenshots/diff-viewer.png)

### Integrated terminal

![Repository shell with multiple terminal tabs and Git output](docs/screenshots/integrated-terminal.png)

### Repository dashboard

![Workspace dashboard containing four demonstration repositories](docs/screenshots/repository-dashboard.png)

## Installation

GitPier requires **macOS 14 or later**.

Download the current stable version from [GitHub Releases](https://github.com/Heisenberg2024/gitpier/releases/latest). **v1.1.0 is in development**: after release, its primary installer will be `GitPier-1.1.0-macos-universal.dmg`. Open the DMG, drag the real GitPier icon to Applications, and launch GitPier from Applications.

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
