# Changelog

## Unreleased

## 1.4.0 — 2026-10-15

- Add a memory-only workspace status service with bounded/coalesced local scans, visible/manual priority, generation-based cancellation and distinct unavailable states. Dashboard starts without full repository sessions, shows scanned/total and physical-repository counts, shared status summaries/combined filters, selection and expandable linked Worktrees while preserving organization/manual order.
- Add reviewed batch Fetch with independent persistent results, bounded execution, cancellation and reviewed retries. Revalidate repository roots, common-directory identity and remote/effective URL configuration; coordinate common metadata, deduplicate matching Worktree targets and preserve Index/worktree/FETCH_HEAD, hooks, signing and existing authentication. Make cancelled worktree/common queue waiters leave promptly. No automatic or batch Pull/Push/Reset/Rebase is added.
- Add cancellable, debounced Workspace Search across selectable repository scopes with local metadata, controlled literal tracked-path matches and bounded native commit-message/hash pagination. Results navigate to existing Diff/file history/commit details. Add native Quick Open with recent/favorite/organization matching and arrow/Return/Escape keys; ⌘⇧P excludes terminal focus. No startup history scan, source-content index, database or upload service is introduced.
- Release 1.4.0 (20) as a Universal DMG, retaining macOS 14 and the production bundle ID, update key and feed. Correct v1.3.0's released documentation; preserve historical assets and the canonical Latest installation entry. Add disposable Core/native workspace acceptance and repeatable 10/50/100-entry measurements with count-only process instrumentation.

## 1.3.0 — 2026-10-15

- Align Interactive Rebase drag glyphs with their action controls, hide attached menu indicators throughout the native interface, and fit About/version/update/legal/help content on one Settings page. Restore Sparkle's standard scheduled-update alerts and perform an opt-in background check at launch without changing its subsequent schedule or automatic-download policy.
- Keep recursive Submodule inspection actor-isolated with a Sendable traversal state for Swift 6.1 compatibility; preserve depth-first order, read-only state and top-level-only queries.
- Extract typed String summaries from Rebase and Submodule views to avoid Swift 6.1 type-check timeouts while retaining displayed content, bindings and operation confirmations.
- Add file/hunk/selected-line/commit/range Patch export and distinct Git Diff / format-patch email formats. Preview affected files in native Diff, check applicability and review Working Tree versus Index imports independently. Freeze affected file/Index state, reject traversal/metadata/nested-repository paths and unsupported mail/rename/copy/symlink/gitlink/binary-delta imports; bound encoded and decoded data.
- Add an optional Git LFS page with installed/configured detection, native JSON file/OID/download information, strict Pointer recognition, root-rule Diff review and confirmed Fetch/Pull. Preserve attributes/comments/CRLF and partial staging, leave installation/filters/hooks/history conversion to the owner, and recheck the fixed ref before protected private-Index checkout.
- Add Submodule listing with bounded nested inspection, declared/registered URLs, child/Index/parent commits and abnormal/dirty state. Review Init/Sync/Add and recorded-versus-fixed-remote checkout separately, reserve parent/child write queues, protect ignored-file collisions and other worktrees, and preserve independent Index content. Download new clones before revalidated registration; interrupted clones remain available. Deinit/removal and automatic recursive updates stay unavailable.
- Add changed-line gutter selection with Command/Shift ranges, keyboard control and separate Stage/Unstage toolbar/context actions in the shared native Diff. Bind selection to repository/file/comparison/revision/Index and clear it on refresh; preserve normal code copying and visible-row rendering.
- Construct selected patches using aligned replacement pairs and current-Index reverse semantics, retain CRLF/no-final-newline bytes, and preserve other partial staging. Lock the real Index exclusively, run native apply checks against a private copy, revalidate state and atomically publish; failures/cancellation retain Index/worktree/foreign locks. Restrict complex file metadata, filters, encodings, binary/gitlink/symlink and oversized changes to existing safe actions.
- Add native Interactive Rebase plans for up to 200 linear commits with Pick/Reword/Squash/Fixup/Drop, drag/arrow ordering, editable messages and explicit history-rewrite review. Freeze the ancestor, HEAD, branch and Index; warn using local remote-tracking evidence without assuming unmarked commits are private.
- Recover native rebase metadata after restart, review Continue/Skip/Abort against Index, todo and working-file fingerprints, and route conflicts through the existing editor. Persist reviewed messages as private data, recreate fixed editor scripts per invocation and retain Git hooks/signing/reflog. Native failures remain actionable; no automatic stash, force or push occurs.
- Retry temporary DMG creation only for the exact Resource busy failure, at most three attempts with short bounded backoff, unique image paths/volume names and retained diagnostics. Limit mounting/cleanup to the task's private path and preserve a failed detach. Add four offline retry regressions and release 1.3.0 (19) as a Universal DMG with the existing production update identity, key and feed; historical releases and assets remain unchanged.

## 1.2.0 — 2026-10-14

- Add a native Reflog page for HEAD/local branches, operation/description filters, bounded pagination, commit details and non-destructive recovery branches. Missing objects report their recovery limit; explicit soft/mixed reset retains the existing review boundary.
- Add Worktree listing, existing/new-branch creation, workspace registration, editor/terminal opening, lock/unlock, reviewed safe removal and moved-linked-tree metadata repair. Protect the main repository, unknown directories, modified/untracked/ignored files, locks, drafts and sessions; serialize shared metadata writes and preserve per-tree IDs/state.
- Add read-only local/remote-tracking branch comparisons with fixed tips, merge bases, accurate unique counts, paged commits and shared file Diff. Distinguish direct tip comparison from merge-base three-point semantics; handle ambiguous/unrelated bases explicitly.
- Add working/historical Git Blame with per-line author/date/hash, rename attribution, uncommitted-line handling, commit/file navigation, hash copy, cancellation and bounded 400-line pages for UTF-8 files up to 4 MiB.
- Keep new interfaces in the existing native navigation with English/Chinese, light/dark appearances, code styling and scrollbars. Separate creation-sheet and Blame presentation state; rebind services/watchers/terminals after a moved worktree repair without granting ownership of external trees.
- Retain the original 98 Core tests and six release-tool gates; add 30 temporary-repository regressions and extend native UI/PTY acceptance. Release 1.2.0 (build 18) as a Universal DMG with the existing production identity, key and feed.
- Correct v1.1.0 documentation to released status and use GitHub Latest Release installation links. Historical releases and the production update identity remain unchanged.

## 1.1.0 — 2026-10-12

- Fix clearing explicit Push URLs, retain additional fetch/push destinations and credentials, and reject stale remote edits.
- Add native paged full-history queries for message, hash, author, date, current branch or all local/remote branches, alongside loaded-commit filtering.
- Preview stash files and untracked changes in the shared side-by-side Diff; cancel stale reads and reject removed stash entries.
- Report conflict operations as requiring attention and protect all ongoing Git/clone work from quit or update restart.
- Bind local rewrite/abort confirmations to reviewed HEAD, Index and operation state; use a fixed remote lease and immutable local commit for force-push. Reject stale untracked deletion after external staging.
- Add a 720 × 420-point Retina DMG installer background, real Applications symlink and verified Finder layout; package HFS+ / LZFSE images and validate the mounted bundle/signatures.
- Share one Sparkle standard updater between About and the menu, with opt-in checks, user-confirmed installation, signed feeds and archive validation before extraction. Preserve workspace/drafts through relaunch and protect Git/terminal/conflict lifecycles.
- Add Keychain key-initialization/backup, DMG signing, public-key signature/Appcast validation and isolated update acceptance tools. Complete a disposable-key self-update and reject altered feeds/packages and failed downloads; production signing uses the owner's dedicated Keychain account.
- Update bilingual installation/development/security documentation, retain historical releases, include Sparkle's full licenses, and add CI metadata/temporary-image checks with permission-preserving development archives.
- Centralize version/build/release identity; build and verify the embedded Sparkle 2.10.0 framework, helpers, links and universal slices. Configure the production update public key and provide encrypted private-key backup verification; candidates with missing keys still disable updates.

## 1.0.3 — 2026-10-12

- Add a native conflict-resolution page with Current/Incoming/Base previews, editable results, per-block Current/Incoming/Both choices, file-owned drafts and explicit save/stage confirmation.
- Warn before discarding unsaved conflict drafts on last-window close or quit; retain the approved push destination and offer another merge if the remote advances during recovery.
- Match the discard-draft alert to the application theme and icon, use readable neutral buttons and make Cancel the default Return action.
- Protect external file, Index, branch and operation changes; retain partial staging, file permissions and CRLF. Offer whole-version/deletion choices for binary or large regular files, and preserve unsupported file-type/submodule conflicts for external resolution.
- Review and complete merge commits through the existing private Index, hooks and signing checks, then continue the original merge-and-push destination. Open new conflicts in the editor and disable continuation/push until files are resolved.

- Offer Merge & Push after a single current-branch push is rejected because remote commits are missing locally. Fetch the actual push destination, explicitly merge after confirmation, and push only after success; preserve local commits, partial staging and conflict state.
- Keep authentication and server-policy failures in the existing error flow, and distinguish pending merge or failed recovery from completed operations in English and Simplified Chinese.
- Share the Diff's 6-point overlay scrollbars across lists, settings forms, help, commit messages, tab strips and terminal scrollback; retain fixed 150-point vertical / 56-point horizontal thumbs, small-viewport clipping, native dragging and idle fading.
- Preserve native SwiftUI scrolling, list virtualization, per-repository scroll positions, Diff vertical synchronization and Index-left placement; hide thumbs when content fits and keep operating-system file choosers unchanged.
- Update the local application and universal archive to 1.0.3 (build 16).

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
