# Architecture

GitPier is a native macOS application. SwiftUI composes the workspace and presentations; AppKit handles native lists, menus, text/Diff rendering, scrolling, windows, and application lifecycle. Installed Git remains the Git engine.

## Modules

| Module | Responsibility |
| --- | --- |
| `Sources/GitPier` | Application state, repository sessions, Dashboard, review flows, native presentations, terminal integration, settings, and updater coordination. |
| `Sources/GitPierCore` | Git execution and models, reviewed state, workspace scheduling, authentication, hosting APIs, credential storage, CLI requests, and task metadata. |
| `Sources/PTYSupport` | Native PTY/process support used by the terminal. |
| `Sources/GitPierCLI` | Standalone navigation launcher, packaged as `Contents/Helpers/gitpier`. It does not expose Git writes or arbitrary shell execution. |
| `Tests/GitPierCoreTests` | Core and real-Git regression tests using disposable repositories and controlled transports. |

`AppStore` owns workspace configuration, repository selection, shared hosting sessions, and operation observation. `RepositoryModel` holds each repository's current status, review state, operation recovery, layout, and terminal sessions. `RepositoryWorkspace` routes Commit, History, Branches, Reflog, Worktrees, comparison, conflicts, LFS, submodules, hosting, and settings pages.

## Git execution and reviewed state

Git commands belong in `GitPierCore/GitService.swift` and use `Process` argument arrays with literal pathspecs. `GitServiceRegistry` resolves canonical working-tree identities; writes share a service actor and explicit queue for that working tree. The workspace budget bounds cross-repository work. Do not introduce a second write path or a shell-based Git dispatcher.

Status and Diff reads produce reviewable snapshots. File-selection checkboxes are independent of the Git Index. Commit paths preserve partial staging and external Index content, validate the reviewed HEAD/branch/Index and selected content, and retain hooks and signing. External changes invalidate review rather than authorizing a broader commit. Diff requests are bounded and stale results must not replace the current selection.

Commit & Push tracks the local commit separately from remote transfer. A failed, cancelled, or unverified Push does not imply that the local commit failed or that the server received nothing. Recovery keeps the original source/destination and explicitly verifies or reviews another Push; it does not repeat Commit or Merge.

## Workflows and limits

- Conflict editing supports UTF-8 text up to 1 MiB, with Current, Incoming, Base preview, and an editable Result. Binary/large files use whole-file choices; symlink, submodule, and file-type conflicts require external tools. Save/continue rechecks reviewed state.
- Interactive rebase operates on supported linear histories up to 200 commits. Ordered cherry-pick reviews 1–200 commits and refuses merge commits rather than guessing a mainline. Merge revert requires an explicit parent. Native recovery keeps Continue/Skip/Abort separate from ordinary writes.
- Blame supports bounded UTF-8 files up to 4 MiB with 400-line pages. Diff, search, API, and history reads also have bounded loading rather than unlimited file/network reads.
- Branch Health is a local observation of upstream, ahead/behind, activity, Worktree occupancy, and optional ancestry against a selected branch. It does not fetch or establish that an inactive branch is safe to delete.
- Dashboard local scanning, optional automatic Fetch, and local watching are separate. Automatic Fetch is off by default, updates tracking references only, and preserves files/Index and browsing state; it does not merge, push, prune, or fetch tags.
- Task Workspaces bind metadata to owned or associated Worktrees. Removal checks ownership and current state; unknown/dirty directories are preserved. Optional Codex sessions use the user's external executable and permissions, not an embedded model or sandbox.

## Hosting and credentials

Hosting API accounts support GitHub.com, GitLab, and Gitea through provider-specific adapters. Account metadata, OAuth configuration, refresh/session management, and credential backends are separate from native Git transport credentials. Tokens pass through the shared token manager; APIs do not independently read credential files.

New hosting accounts default to Local Encrypted Vault; legacy Keychain accounts retain their mode. Scope expansion, storage migration, and credential cleanup are explicit user actions. See [Security](../SECURITY.md#credential-storage) and [hosting setup](development.md#hosting-setup).

Remote review anchors bind to stable account/repository/request identities and exact commit versions. Supported writes validate permissions, revision, and patch coordinates again before sending. A durable review-operation journal stores minimal intent/receipt metadata before mutation; it excludes comment bodies, tokens, and code. Unknown results survive restart without automatic replay. Provider capabilities differ; unsupported operations remain in the browser.

## Terminal, UI, and persistence

SwiftTerm renders terminal sessions backed by `PTYSupport`. Sessions run the user's shell and jobs in repository context; hiding a terminal keeps sessions running, while closing one terminates its process group. The terminal is not a security sandbox.

Application-owned scroll areas share `UnifiedScrollbars`, `OverlayScrollbars`, and `OverlayScrollThumb`: compact rounded overlay thumbs on both axes, common activity/fade and accessibility behavior, viewport clipping, and no reserved native gutter. Diff side placement and the terminal's shared adapter remain deliberate exceptions within that shared implementation. System file choosers stay native.

Preferences and workspace metadata use local persistence; repository page selection is session state and opening a repository defaults to Commit. Runtime diagnostics and operation history are bounded in-memory records; durable review-recovery and disconnect metadata have separate lifecycles. Native presentation roots apply the shared appearance to avoid mismatched theme and scrollbar behavior.

## Dependencies and distribution

SwiftTerm supplies terminal rendering; Sparkle supplies updater validation, replacement, and helper services. SwiftPM pins exact dependency versions in `Package.resolved`. Bundled file icons retain their manifest and license. See [third-party notices](../THIRD_PARTY_NOTICES.md).

`Scripts/build-app.sh` assembles the app, CLI, resources, legal files, and Sparkle helpers, then signs and verifies the bundle. `ReleaseConfiguration.json` is the version/build/Bundle ID/feed/public-key source. Universal DMG packaging and signed update metadata are independent of Apple Developer ID signing/notarization. Current packages are ad-hoc signed. See [Development](development.md#packaging-and-updates) for entry points and [Security](../SECURITY.md#updates-and-distribution) for trust limits.
