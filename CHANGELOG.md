# Changelog

## 1.0.2 — 2026-10-11

- Move About to the rightmost Settings tab with a centered application identity and structured version, license and privacy information.
- Detect installed editors in a stable priority order and show their native application icons in one compact dropdown; size the control to its selected title, append custom Apps above Choose Application, and use standard native submenus with application icons for one-time editor choices from repository and commit-file context menus.
- Open or select repositories on the Commit page without persisting the current page.
- Share the commit Diff renderer and scrollbar behavior with history, hide empty old sides for additions, and persist history detail height and file-list width per repository.
- Close history details by clicking the selected commit again, pressing Esc or using the close button; prevent cancelled history reads from replacing newer selections.
- Make sidebar organizations distinct with stronger headers, count badges, spacing, indented repository rows, tighter group spacing and a stateful Collapse / Expand All Organizations button.
- Replace the unavailable system help entry with a built-in English / Simplified Chinese guide and an issue-report link.
- Update the local application and archive to 1.0.2 (build 13).

## 1.0.1 — 2026-10-11

- Show final Git operation results after transfer progress ends; distinguish completed commit-and-push, missing upstream, push failure, and cancellation while preserving successful local commits.
- Refresh visible repository data when clicking a repository or returning to the foreground; preserve manual refresh and avoid racing active writes.
- Persist manual repository order within organizations and assign repositories opened from an organization to that group.
- Add subtle Diff overlay scrollbars with fixed compact thumbs, keep them inside the code viewport, and place the Index scrollbar on the left.
- Give the working tree the full Diff width when the unstaged Index side has no content.
- Remove the local-development/signing notice from the English and Simplified Chinese About text, retaining the MIT license and copyright.
- Update the About page, workspace footer, application version, and release archive to 1.0.1 (build 9).

## 1.0.0 — 2026-10-11

- Use one approved icon for the sidebar, Dock, About panel, and application package; regenerate all icon sizes during packaging and refresh the packaged icon identity.
- Native macOS workspace with repository collections, dashboard, worktrees, English and Simplified Chinese, and system/light/dark appearances.
- Reviewed commits with independent file inclusion, preservation of external and partial staging, file and hunk operations, hooks, and signing.
- Side-by-side Diff, per-repository drafts and tabs, history graph, branches, remotes, stashes, and tags.
- Integrated PTY terminal with tabs, splits, search, and per-repository sessions.
- Keychain HTTPS tokens, SSH profiles, existing Git-helper support, and Git transfer progress.
- Immediate file selection, cached Diff previews, stable pane resizing, and local-only exclusion of untracked files.
- Updated application icon and bilingual product documentation with isolated demonstration screenshots.
- Restore selection of every Settings tab and synchronize MIT copyright notices for Heisenberg2024 (2026).

GitPier is licensed under the MIT License. Public downloads are available from GitHub Releases; Developer ID signing and Apple notarization remain pending.
