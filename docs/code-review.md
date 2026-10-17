# Code review and collaboration — v1.6.0 development

This is an unreleased development feature. Released v1.5.1 validation is historical evidence; it does not verify the new write workflows. Current implementation and acceptance results are recorded in the development guide. No v1.6.0 real-service comments or approvals have been authorized or performed.

## Provider capabilities

| Operation | GitHub | GitLab | Gitea |
| --- | --- | --- | --- |
| General comment | Issue comment on the PR | MR Discussion | Issue comment; requires issue permission |
| Single-line comment | Exact commit, `line` and `side` | Diff Discussion with version triple and old/new coordinates | Browser; pending-ownership safety and actual line placement are unverified |
| Reply | Root review comment reply; issue comments have no native thread reply | Note within the original Discussion ID | Native review-comment reply only on a verified instance/API; no invented issue-comment threads |
| Local draft | Memory only | Memory only; each Discussion/Approval is an independent write | Memory only |
| Pending review | Native create and explicit submit | No verified pending-batch adapter; independent writes | Browser; create can reuse an external pending review and submit selects latest HEAD |
| Approve | Native review `APPROVE` | Independent `/approve` with SHA and `user_can_approve` | Browser; formal create may publish external pending comments |
| Request changes | Native `REQUEST_CHANGES` | No verified adapter; use Discussion or browser | Browser for the same pending-ownership safety restriction |
| Resolve/unresolve | Browser; REST thread resolution is unavailable | Native Discussion resolution when allowed | Browser until the instance's supported semantics are verified |
| Request reviewers | Additive native user requests; collaborator eligibility checked | Read-only reviewers and browser; replacement API has no concurrency condition | Additive native user requests on audited 1.27.3 API; partial changes remain uncertain until verified |
| Approval rules | Native review states; no inferred merge eligibility | Explicit read of server approval rules; edition/permission failures isolated | Native review states; no inferred merge eligibility |
| Review inbox | On-demand account-wide requested/authored open PR search | On-demand official reviews-for-me/created-by-me MR scopes | Browser; reliable account-wide inbox not enabled |
| Current branch request | Exact source repository, branch and full SHA | Exact source project, branch and full SHA | Exact source repository, branch and full SHA |
| Multiline comment | Same-side, same-hunk range, at most 200 actual lines | Not implemented; single-line or browser | Disabled with inline placement |
| Branch comparison | Existing local / remote-tracking snapshot comparison; no native platform comparison | Same local comparison | Same local comparison |

Capabilities are further restricted by current account scopes, server permissions, request state, author identity and instance version. An enabled action does not promise that an approval satisfies a project's merge rules. GitLab's approvals API exposes current user approval state rather than an individual immutable approval event ID; readback is scoped to that user, MR and verified revision. Self-approval is rejected; GitLab approval can depend on edition, policies or reauthentication. GitPier does not collect a password to bypass those restrictions.

## Review workflow

Open **More → Pull / Merge Requests**, choose the request and select **Reviews**. Conversation, review decisions and code threads retain separate types and server IDs. Comments render as selectable plain text, including Markdown source: no remote scripts, HTML, images or suggested code execute.

For supported remote files, use the line's comment control or equivalent context-menu/keyboard action. The editor shows the file, old/new side, exact line, selected code and commit. Save comments to the in-memory review draft, edit/remove them and choose Comment, Approve or Request Changes where supported. General comments and replies also require a final preview. Confirmation shows provider, instance, account, repository, PR/MR, SHA, operation and the full text to be published. Canceling does not send a write.

Drafts are bound to provider + instance + account + stable remote repository + stable request + revision. They are never reused for another account or request, automatically persisted, logged or published on close. Unsaved drafts are retained while navigating; discarding them or closing the last window requires explicit handling. A changed HEAD leaves the old draft available for review, but its old anchors cannot be submitted against the new version.

GitLab presents each Discussion and Approval as a separate write. A partial submission retains the individual published IDs and unsent draft entries. It must never be described as an atomic GitHub review.

## Comment positions and revision checks

The existing `DiffParser` supplies real old/new file coordinates and hunk contents. UI row indices are never sent to the provider. `HostingDiffAnchor` captures paths, side, both applicable coordinates, a hunk hash, the complete patch hash, stable target identities and revision. Binary, omitted, oversized, malformed and unsafe metadata patches use a browser fallback. CRLF and missing-final-newline markers preserve their original positions.

GitHub receives `commit_id`, `path`, `line`, `side`; a validated same-side range additionally receives `start_line` and `start_side`. Ranges are rebuilt from the complete current patch and must remain within one hunk and 200 actual file lines. No deprecated `position` is generated. GitLab receives `position_type=text`, `base_sha`, `start_sha`, `head_sha`, both paths and the coordinates appropriate to added/deleted/context lines. Its version ID and SHA triple come from the actual MR diff version. A rename requires an authoritative old/new path pair and a complete supported patch.

Before each write, GitPier fetches the current target, checks stable repository/request/user IDs, state, permissions and revision, re-reads each affected patch and validates the exact anchor. It checks revision again after those reads. Changes stop the write and ask the user to refresh and reconfirm. The provider can still change concurrently with a network request: exact commit parameters and GitLab's SHA condition preserve the reviewed version where the API supports them; readback verifies the submitted identity, state and commit. No heuristic relocation occurs.

Gitea 1.27.3 accepts a fixed `commit_id` when creating a review, but its model reuses the current user's pending review, including comments created in another client. An earlier pending-list read cannot prevent unconfirmed comments from being published. GitPier therefore disables native formal review creation, approval, request-changes and pending creation/submission. The submit-pending route also chooses the latest HEAD without a SHA condition. Inline creation also needs an API that isolates confirmed pending content, plus a maintainer-authorized live placement check. Ordinary issue comments and explicit existing-thread replies remain available. Its review-comment endpoint returns a bounded whole list, not real server pagination; GitPier never repeats a fictitious next page.

## Permissions and credentials

GitHub `public_repo` permits public collaboration; `repo` is broad private-repository access. GitLab `api` is broad write/API access, not a comment-only grant. Gitea separates repository review routes (`write:repository`) from ordinary issue conversations (`write:issue`, with corresponding read access); existing repository grants are not silently expanded. PAT permissions remain platform-enforced when the token exposes no scope metadata; 403/404 do not imply successful authorization.

Reauthorize explicitly or replace a PAT after reviewing the required permissions. Gitea may reject an expanded scope set for an existing grant. GitPier preserves the active session and Local Vault, does not revoke a grant, retry a write, change OAuth registration or delete credentials to force authorization. The owner may adjust platform authorization or use a separate client/PAT.

Review operations obtain current tokens through the existing `OAuthTokenManager`; they never access Keychain or AES files directly. Storage modes, refresh, migration and account isolation retain their existing rules. A per-account private disconnect-intent journal suppresses stale active metadata on restart. If both the intent and main metadata writes fail, the current process still revokes its session and retains an explicit recovery row; persistence across restart cannot be guaranteed until a write succeeds. Credential deletion pauses in that case.

## Failure recovery

All windows share a per-target submission lock. A confirmation ticket is consumed once. Non-GET writes are never automatically retried. Definite permission/validation failures preserve the draft. Network cancellation after sending, timeout, 5xx, malformed success or failed verification may mean **Result Unknown**; do not claim that nothing was posted.

If a server ID was received, read-only reconciliation fetches that exact object and verifies its author, state and commit before accepting success. Without a server ID, body/author/time matching cannot prove uniqueness; the unknown state remains and the user checks the platform. An explicit acknowledgement after that check can unlock a new attempt. Refreshing or reopening a request within the running application does not silently unlock an uncertain target. Drafts, confirmation snapshots and uncertainty locks are process memory: closing the application warns, but crash/relaunch recovery is not a persistent review journal. A new process never automatically resends a write. Successful entries are removed individually; failed/unsent entries remain.

API data and drafts are memory-only and account-partitioned. Existing detail cache entries are invalidated only for the affected request/sections; pagination remains bounded and explicit, thread replies load on demand, and cancellation/generation checks reject late responses. Review writes do not enter `GitService`, trigger Fetch/Push, change HEAD/Index/branch or apply code suggestions.

## Collaboration shortcuts

Reviewer selection uses stable user IDs from provider-native eligible candidate APIs. The final confirmation names the reviewers and the platform notification. GitHub and the audited Gitea API add requested users while preserving existing users. GitLab's `reviewer_ids` update replaces a whole list without a compare-and-swap condition; a preceding read cannot prevent overwriting another client's concurrent edit, so GitPier offers read-only reviewers and the browser. Reviewers and approval-rule approvers remain separate concepts.

Reviewer readback verifies request/repository IDs, head/base and requested user IDs from one final PR snapshot. This proves the current requested-user state, not delivery of a notification or that the state arose solely from this HTTP request. Gitea can apply part of a multi-user request before an error: reconcile read-only, never automatically resend. If a reviewer completes a review before readback removes their request, the result can remain conservatively unknown.

The Dashboard's **Account Review Inbox** loads only after a user action, clearly covers the selected account beyond the current workspace and pages 30 entries. It caches in memory for 60 seconds, uses the existing two-permit Hosting network budget and does not scan all repositories, comments or Diffs. Search totals and incomplete results retain their platform meaning. GitHub search Issue IDs are not treated as PR IDs: opening requires an exact bound repository and number, then a fresh PR identity check. Unbound repositories open in the browser.

The current-branch shortcut reads local branch/remotes only on demand, validates the source repository/project, branch and full commit, then rechecks before navigation. Fork identity is never inferred from branch name alone. It does not push or fetch. **Compare Branches** reuses the existing read-only local workflow, including ahead/behind, commits, changed files and Diff. Remote-tracking values describe the last local Fetch; native provider-side comparison and an associated-request badge inside comparison are deferred.

GitLab Discussion Resolve/Unresolve uses the actual resolvable thread and current permission, a final confirmation and exact readback. Approval Rules loads separately, displays the server's per-rule approved flag, required count and available member information, and distinguishes unavailable/permission-required data from an empty list. A personal approval is never presented as satisfying all rules or allowing merge.

GitLab itself documents Request Changes in its [review interface](https://docs.gitlab.com/user/project/merge_requests/reviews/). This release does not implement that separate provider workflow; it does not claim the platform lacks it.

## Official API references

- [GitHub reviewer requests](https://docs.github.com/en/rest/pulls/review-requests), [search](https://docs.github.com/en/search-github/searching-on-github/searching-issues-and-pull-requests).
- [GitHub review comments](https://docs.github.com/en/rest/pulls/comments), [reviews](https://docs.github.com/en/rest/pulls/reviews), [issue comments](https://docs.github.com/en/rest/issues/comments).
- [GitLab Discussions](https://docs.gitlab.com/api/discussions/), [MR approvals](https://docs.gitlab.com/api/merge_request_approvals/), [MR diff versions](https://docs.gitlab.com/api/merge_requests/#list-merge-request-diff-versions).
- Gitea 1.27.3 [review router](https://github.com/go-gitea/gitea/blob/v1.27.3/routers/api/v1/repo/pull_review.go), [review service](https://github.com/go-gitea/gitea/blob/v1.27.3/services/pull/review.go), [pending reuse model](https://github.com/go-gitea/gitea/blob/v1.27.3/models/issues/review.go), [API routes](https://github.com/go-gitea/gitea/blob/v1.27.3/routers/api/v1/api.go), [granular OAuth scopes](https://docs.gitea.com/1.27/development/oauth2-provider/).

## Implementation and local regression

The new Core modules cover review models/API/submission, reviewer selection/API, approval rules, the account inbox and disconnect intent. Native integration adds review sessions/views, reviewer selection, shortcuts and inbox navigation to the existing Hosting, Diff, Dashboard and window lifecycle. Native acceptance fixtures cover review, provider, entry and disconnect paths; these UI workflows were exercised using a Debug bundle. No dependency or Git command implementation was added.

The 278 new Core tests cover 81 provider API cases, 51 anchor/submission safety cases, 29 concurrency/cache cases, 41 reviewer cases, 24 inbox/branch identity cases, 11 multiline cases, 20 approval-rule cases and 21 disconnect-intent cases. The concurrency cases include repository-path aliases sharing one stable-identity active/unknown lock. All original 494 test functions remain. One original Gitea fixture was corrected to the actual unpaginated endpoint and strengthened to check 120 items, one GET and no second-page request; the other 33 original test files remain byte-identical to the baseline.

The latest complete Core suite passed **772 tests, zero failures/skips, 264.658 seconds**, including the stable-identity lock fix, with evidence in `.cache/v160-core-full-final-v2.log`. The focused run passed **424 tests, zero failures/skips, 1.439 seconds**. All **10 release-tool gates** passed in **2.080 seconds**.

Completed native acceptance includes the original UI/PTY suite (**104 captures**), the Hosting matrix (**273 captures**), real AppleEvent delivery with a mock OAuth exchange, and the final automatic Review run (**18 WindowServer captures / 21 provider assertions**). Four JSON records verify unknown-result close/quit protection without requiring a draft body. Gitea's disabled formal-review paths are verified as zero-write fallbacks, not successful native approvals.

The complete GUI-assisted Review run separately passed with **25 WindowServer captures / 22 provider assertions**. Actual account/filter menu selections verified late-response isolation, exact inbox navigation, current-branch Find/Open and unchanged HEAD/branch/Index/worktree. Compare was mounted as the real view and checked against actual local/remote-tracking refs in both languages; its existing main navigation was not clicked. A real GitLab disclosure expansion and Load Approval Rules click caused exactly one independent read and displayed required approvals = 2 / rule not approved while personal approval was true. These fixtures use synthetic HTTP and credential stores. Capture counts are not unit-test counts.

The final Universal release bundle **1.6.0 (27), arm64 + x86_64** passed deep signature and Sparkle structure verification. All **191** frozen repository build inputs remained unchanged. The temporary DMG structure check passed. A unique local candidate DMG was packaged and verified (20,399,690 bytes); no publication, installation or production EdDSA signing occurred; Finder visuals, drag installation and an actual Sparkle update are distinct checks.

The existing HTTPS/SSH/Git/helper, Automatic Fetch, reviewed commit/partial staging, Worktree, Rebase, Patch, LFS/Submodule and OAuth/vault/migration tests passed within that full suite. The unchanged Git, token-manager, vault, OAuth and Keychain implementations retain their original boundaries. Local fixtures are not new real-server transport, grant, natural-expiry or actual operating-system Keychain-refusal acceptance. These local macOS 27.0.1 / Swift 6.4 results do not establish production installation/update, new CI, Intel hardware or macOS 14 runtime acceptance. No v1.6.0 real-service comments or approvals have been authorized or performed.

Disconnect-intent fault fixtures verify recovery behavior, not physical disk or power-loss durability. A malformed, unsupported or identity-mismatched sidecar rejects the entire Hosting metadata load and requires manual restoration; it is never silently ignored or used to delete credentials during loading. If both the intent and main metadata writes fail, memory revocation remains effective and credential deletion pauses, but persistence across restart is not guaranteed until a write succeeds.

## 简体中文

v1.6.0 尚未发布，本轮新增评论和审批未获真实测试目标授权，不能把 Fixture 或 v1.5.1 历史记录称为本轮真实服务验收。

GitHub 普通评论使用 Issue Comment，逐行评论使用准确 `commit_id + line + side`；原生 Review 支持 Comment、Approve、Request Changes 和 Pending 提交。GitLab 使用 Discussion/Note ID 与真实 Diff Version 的 Base/Start/Head SHA，新增行只发 new_line、删除行只发 old_line、上下文保留两者；Approval 是独立且带 SHA 的写入，受 `user_can_approve`、规则、套餐和重新认证要求限制，本适配器未验证 GitLab Request Changes 的独立接口，保留讨论/网页操作，不能把普通 Discussion 当成正式拒绝审批；也不伪造原子批次。

Gitea 普通对话依赖独立 Issue 权限，仓库审查按实例版本核实。1.27.3 创建 Review 虽可固定 commit_id，却会接管同账号当前 Pending，可能发布其他客户端的未确认评论；因此正式 Review、Approve、Request Changes 和 Pending 创建/提交均保留网页入口。Pending 提交还会采用最新 HEAD，缺少条件参数。逐行落点未经授权真实仓库验证前保持禁用；不以 SwiftUI 行号或其他平台参数猜测位置。Review 评论端点实际不分页，按有界完整列表读取，不重复请求伪造下一页。

草稿仅保存在内存，绑定完整账号、目标及版本，支持编辑、删除和提交前全文预览。用户明确确认后才写入；多窗口共享提交锁。每条写入前复核身份、权限、HEAD/Diff Version 和实际文件 Patch，变化则停止并重新确认，绝不自动搬移旧评论位置。成功后回读稳定 ID、作者、状态和 SHA；GitLab 逐条记录成功/失败/未发送结果。

超时、发送后取消、服务异常或回读失败显示“提交结果未知”并保留草稿，不自动重复 POST。有服务器 ID 时只读回查该对象，没有 ID 时不以正文/时间猜测成功，必须先查看平台。同一运行进程内刷新或重开请求不会解除未知结果保护。草稿、确认快照与未知锁均在进程内存，关闭会提醒；崩溃/重启后不提供持久审查恢复，也不会自动重发。

权限扩大由用户主动重新授权；GitHub repo 和 GitLab api 都是广泛权限。Gitea read/write:issue 与 repository 分开，旧 Grant 冲突时保留原会话，不自动撤销。PAT 权限由平台强制执行，不能自动提权。审查复用 OAuthTokenManager，不直接操作凭证后端；断开意图私有日志覆盖旧活动元数据，双重磁盘写入都失败时明确保留内存撤销/重试并暂停删凭证，不能承诺此时跨重启持久化成功。

正文为安全只读文本，不执行 Markdown/HTML/建议代码。评论不会修改工作文件、Index、HEAD、分支，也不会触发 Fetch/Push。

P1：GitHub 多行范围限同侧、同 Hunk、最多 200 行，提交与回读使用 start_line/start_side；GitLab/Gitea 不推断相同能力。GitHub 与已审计 Gitea API 支持确认后追加 Reviewer，并保留已有成员；GitLab 整表替换缺少并发条件，保留只读列表与网页入口。候选成员、Reviewer、Approval Rule Approver 分别按真实 API 处理。Reviewer 回读从同一份最新 PR 快照核对身份、版本和用户 ID，只证明当前请求状态，不证明通知投递；Gitea 部分成功不自动重发。

账号级审查收件箱仅主动加载，明确覆盖当前工作空间以外的账号仓库；GitHub 使用官方 PR Search，GitLab 使用官方个人 MR scope，Gitea 保留网页。每页 30 条、60 秒内存缓存，复用 Hosting 两并发预算，不扫描所有仓库或 Diff。GitHub 搜索 Issue ID 不充当 PR ID，进入详情按已绑定仓库和编号重新核实。当前分支入口按源仓库/项目、分支及完整 SHA 匹配并复核，支持 Fork 隔离，不执行 Fetch/Push。

GitLab 讨论支持有权限时确认后 Resolve/Unresolve；Approval Rules 独立按需读取服务器规则状态，权限/套餐不可用单独提示，不把个人已批准当成规则全部满足。分支比较复用原有本地/remote-tracking 只读界面，保留提交、文件、Diff 和领先/落后；明确跟踪引用来自本地快照。平台远端比较、比较页关联请求标识、GitHub GraphQL Resolve 和更广泛 Gitea 版本验证留待后续。
