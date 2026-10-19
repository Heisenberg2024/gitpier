# Changelog

## 1.7.0 — 2026-10-19

### Workflow integration (29)

- Preserve concurrently replaced CLI files during uninstall and failed-install cleanup; verify tool and receipt ownership inside a private removal directory before deleting either. 卸载与安装失败清理保留并发替换的 CLI 文件；工具及收据先移入私有目录并复核归属，再执行删除。

- Restore the system popover material across its body and arrow, remove the close button, and share five factual risk levels between the stable toolbar entry and heading. 恢复主体与箭头一体的系统浮层材质，移除关闭按钮；固定宽度入口与标题共用五级真实状态，落后提交不误报冲突。

- Fix contextual comparison accepting frozen commit targets, open comparison and synchronization review immediately, and blur both popover themes without whole-window transparency. 修复上下文比较的固定提交目标，比较页和同步审查即时打开；浅深浮层统一背景模糊，不再整体降低窗口透明度。

- Remove the contextual assistant’s lingering focus ring, unify light/dark popover material, and extend Diff scrollbar coverage to independent popovers and nested scroll regions/editors. 修复上下文助手关闭后残留焦点边框，统一浅/深浮层材质，并补齐独立浮层及嵌套滚动区域/编辑器的 Diff 滚动条。

- Move contextual advice into a quiet native toolbar popover before the branch selector; reclaim content height, prioritize risk and downrank redundant Commit-page navigation. 上下文建议移入分支左侧的原生工具栏浮层，归还主体高度，优先提示风险并降低提交页重复导航的优先级。

- Add state-driven repository/Worktree advice with concrete reasons, fixed-tip comparison and revalidated existing write confirmations; replace duplicate navigation with relevant next steps. 新增仓库/工作树状态建议及原因、固定提交比较与原队列内目标复核，复用既有确认流程，替代重复导航。
- Add a shared, event-driven Operations Center with bounded memory history, accurate cancellation requests and links to existing recovery workflows and Review Journal history.
- Add a strict navigation-only CLI with native cold/hot app routing and a no-overwrite user-directory installer/uninstaller. Preserve OAuth callback and production update identities.
- Enhance the existing Quick Open with commands and recent command choices; document Developer ID/notarization planning.
- Keep completed operation cards live while the center stays open; explicitly label session-only history. Bring CLI-opened workspaces forward and move CLI controls into Terminal settings in one button row.
- 修复操作中心打开期间卡片停留旧状态，明确会话级历史；补齐 CLI 前台窗口展示，将命令行工具设置并入终端标签，三个按钮同行。
- 新增跨窗口事件驱动操作中心、有界内存历史、取消请求状态及既有恢复/审查日志入口。
- 新增仅负责导航的原生CLI、冷/热唤起及不覆盖已有文件的用户目录安装/卸载，保持OAuth和更新身份。
- 增强既有快速打开的命令和最近选择，提供Developer ID/公证实施方案。
- Published [v1.7.0](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.7.0) from `dfcd0f6`: exact-source Swift 6.1.2 CI passed 932 Core tests and 10 release gates; Tag CI reused that full run. Independent review, Universal/native acceptance, signed Draft/public assets and isolated 1.6.1 → 1.7.0 Sparkle relaunch passed. See [evidence and limits](docs/development.md#v170-publication--2026-10-19).
- 已从 `dfcd0f6` 正式发布；同源码 Swift 6.1.2 CI 通过932项Core与10项发布门控，Tag CI复用该完整运行；独立审核、Universal/原生验收、签名草稿/公开附件及隔离28→29实际Sparkle重启升级均通过，硬件与生产环境边界分别记录。

## 1.6.1 — 2026-10-18

### Review write stability (28)

- Published as [Latest](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.6.1) from `74dc071`: exact-commit Swift 6.1.2 CI passed 855 Core tests and 10 release gates. Draft asset readback, production DMG/Feed signatures, anonymous public downloads and the canonical Latest Feed passed verification.
- 已从`74dc071`正式发布为[Latest](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.6.1)；同提交Swift 6.1.2 CI通过855项Core与10项发布门控，Draft附件回读、生产DMG/Feed签名、匿名公开下载与Latest固定Feed均验证通过。
- Persist minimal, versioned operation intent before each confirmed remote review write. Retain per-item known receipts, verified outcomes and unsent items; recover possibly sent writes as Unknown after restart, with no automatic replay.
- Add a visible recovery panel, read-only inspection of known receipts, separately confirmed manual acknowledgement and explicit completed-history cleanup. Comment bodies, private code, Diff anchors and body hashes are never stored in this journal.
- Confirm account-wide review discard before disconnect, cancel pending work and prevent late responses from restoring private drafts or old sessions across windows.
- Require the confirmed review decision, complete commit SHA and stable repository/request identity during readback. Preserve an incomplete POST receipt for later checking. Keep unsafe Gitea reviews and unverified GitLab Request Changes in the browser.
- Recognize form-encoded Gitea scope-conflict callbacks without changing codes/state or exposing provider descriptions. Record maintainer-authorized live review results, including a real persisted unknown outcome, separately from fixture evidence.
- Add isolated data/update compatibility fixtures for actual v1.6.0 (27) to v1.6.1 (28). Validation and real-service authorization boundaries are recorded in [v1.6.1 validation](docs/v1.6.1-validation.md).
- 每条确认后的远端审查写入前持久化最小版本化意图，逐项保留已知结果 ID、验证成功和未发送状态；重启后将可能已发送的操作恢复为未知，不自动重发。
- 新增可见恢复面板、已知结果只读回查、单独确认后的人工核实与已完成日志主动清理；日志不保存评论正文、私有代码、Diff 位置或正文哈希。
- 断开前明确确认该账号所有窗口的审查丢弃，取消等待中的任务，阻止迟到响应恢复私有草稿或旧会话。
- 回读严格核实确认的审查决定、完整提交 SHA 及稳定仓库/请求身份；保留不完整 POST 结果 ID 供核查。Gitea 不安全审查与 GitLab 未验证的 Request Changes 继续使用网页。
- 正确识别表单编码的 Gitea Scope Conflict 回调，不改写 code/state 或展示远端描述；单独记录授权后的真实审查结果与实际跨重启未知记录。
- 新增真实 v1.6.0（27）到 v1.6.1（28）的隔离数据/更新兼容夹具；[验收记录](docs/v1.6.1-validation.md)区分自动化、真实平台与授权边界。

## 1.6.0 — 2026-10-18

### Native code review and collaboration (27)

- Add account/repository/request/revision-bound review models, exact Diff anchors, immutable submission previews and a shared submission coordinator. Check fresh permissions and versions before each write; verify returned stable IDs and preserve unknown/partial outcomes without automatic POST retries.
- Add provider-specific review adapters and native collaboration interfaces. GitLab Discussions and Approval remain independent operations; Gitea inline placement requires controlled live verification; formal review creation/pending submission stays in the browser because the API may publish another client’s pending comments or adopt newer HEAD. See [capabilities and validation limits](docs/code-review.md).
- Add confirmed GitHub multiline comments, GitLab discussion resolution and separately loaded approval rules, additive GitHub/Gitea reviewer requests, an on-demand account review inbox and exact-source current-branch shortcuts. Reuse local branch comparison with explicit tracking-snapshot provenance; keep unsafe or unverified provider actions in the browser.
- Split the review inbox into smaller native views to keep Swift 6.1 compilation bounded without changing query or navigation behavior.
- Persist per-account disconnect intent before asynchronous cleanup; suppress stale active metadata after restart and retain explicit recovery when metadata or credential cleanup fails. Preserve original OAuth, Local Vault, Keychain and Git workflows.
- 新增绑定账号、仓库、请求和版本的审查模型、准确 Diff 位置、不可变提交预览与共享提交协调器；每条写入前检查最新权限和版本，回读稳定 ID，保留未知/部分成功结果且不自动重复 POST。
- 新增各平台独立审查适配与原生协作界面。GitLab Discussion 与 Approval 分别写入；Gitea 逐行落点需受控真实验证；正式审查/Pending 接口可能发布其他客户端草稿或采用新 HEAD，保留网页操作。[能力与验收边界](docs/code-review.md)明确区分。
- 新增确认后的 GitHub 多行评论、GitLab 讨论解决与独立审批规则读取、GitHub/Gitea 追加审查者、主动加载的账号级审查收件箱和准确源身份的当前分支入口；复用并明确来源的本地分支比较，未验证或缺少安全条件的平台操作保留网页入口。
- 拆分审查收件箱原生视图，兼容 Swift 6.1 编译，保持查询与导航行为。
- 异步清理前持久化每账号断开意图，重启时抑制旧活动元数据；元数据或凭证清理失败保留主动恢复入口，保持原 OAuth、本地库、Keychain 与 Git 工作流。

## 1.5.1 — 2026-10-17

### Hosting stability and compatibility (26)

- Disconnect sessions before cleanup, journal disconnected credential copies and retain explicit retries after macOS denies deletion. Keep active Local Vault use independent from old Keychain copies.
- Load request Overview and selected detail modules independently; isolate failures, page large requests and reject stale results after selection changes. Show denied CI access explicitly and keep remote Diff read-only.
- Include ordinary GitHub request conversations and paged Gitea review comments; distinguish same-named CI sources. Reject malformed/overflowing unified Diff ranges and mismatched hunk counts while retaining a read-only raw preview.
- Finish matched OAuth error callbacks after validating origin and state instead of leaving authorization waiting. Explain Gitea grant/scope conflicts while retaining the existing session, without automatically revoking grants or retrying; reject malformed, ambiguous and foreign callbacks.
- Read Gitea branch/CI fields in their native formats, accept only its verified empty-null CI shape, and address fork sources by full repository without unsafe fallback.
- Add provider compatibility and credential lifecycle regressions; retain the production update identity, macOS 14 Universal distribution and native Git authentication.

简体中文：

- 断开先停止会话，持久记录已断开的凭证副本；macOS 拒绝删除后保留主动重试入口，旧 Keychain 副本不影响当前 Local Vault 账号。
- 概览及选中详情模块独立按需加载，隔离错误、保留大请求分页并拒绝切换后的迟到结果；CI 无权限明确显示，远端 Diff 保持只读。
- 补齐 GitHub 普通对话和 Gitea 审查评论分页，区分同名 CI 来源；拒绝畸形、溢出或计数不符的 Diff，同时保留只读原文预览。
- 校验来源与 State 后及时终结匹配的 OAuth 错误回调，避免授权一直等待；明确提示 Gitea grant/Scope 冲突，保留旧会话且不自动撤销或重试，拒绝畸形、歧义与外来回调。
- 按 Gitea 实际格式读取分支与 CI 字段，仅接受经过严格校验的合法空 CI；使用完整源仓库创建 Fork 请求，拒绝不精确降级。
- 补充平台兼容与凭证生命周期回归，保留生产更新身份、macOS 14 Universal 分发及 Git 原生认证。

## 1.5.0 — 2026-10-17

- Add native GitHub Device Flow, GitLab S256 PKCE in the ordinary browser, and Gitea v1.23+ public-client PKCE with an IPv4 loopback callback. Bundle the registered GitHub.com/GitLab.com public Client IDs, with reusable self-hosted configuration and PAT fallback; no Client Secret or backend is required.
- Default new OAuth/PAT accounts to Local Encrypted Vault: AES-256-GCM, independent per-account random keys, private separate key/ciphertext files and atomic generation commits. Retain optional macOS Keychain and legacy accounts, future-account defaults, confirmed bidirectional migration and explicit previous-copy cleanup. Document the local-key security tradeoff.
- Share lazy token sessions across windows, merge loads and refreshes, reject stale/foreign account contexts and preserve a session-only token after persistence failure. Journal migration before destination writes; cancellation and failed switching preserve the source. Reconnecting an existing user never applies the new-account storage default.
- Add multi-account repository/Remote bindings, PR/MR lists/details/commits/files/reviews, exact-SHA CI/Pipeline and read-only remote Diff. Request creation checks permissions, pushed branches, fork targets and duplicates before confirmation; uncertain results require a query before retrying. Add lightweight Dashboard collaboration summaries.
- Refine bilingual hosting settings with official marks, full-card click targets, centered empty states, automatic GitHub verification-page opening and complete native focus rings. GitLab uses ordinary browser tabs and a one-time state-bound application callback; keep About rightmost with stable tab IDs. Preserve v1.4.4 native Git authentication, Automatic Fetch, SSH and production update identity.

简体中文：

- 新增 GitHub Device Flow、GitLab 普通浏览器 S256 PKCE，以及 Gitea v1.23+ 公共客户端 PKCE / IPv4 回环授权。内置已注册的 GitHub.com/GitLab.com 公共 Client ID，支持自建实例配置复用与 PAT 备用，无需 Client Secret 或自建后端。
- 新 OAuth/PAT 默认使用本地加密凭证库：AES-256-GCM、每账号独立随机密钥、私有密钥/密文分离与原子版本提交。保留可选系统钥匙串与旧账号，提供未来账号默认值、确认后双向迁移和旧副本主动清理，准确说明本地密钥的安全取舍。
- 窗口共享按需 Token 会话，合并读取与刷新，拒绝过时或跨实例身份；持久化失败后保留当前会话并明确提示。迁移先记录意图再写入目标，取消或切换失败保留原存储；重复连接旧用户不应用新账号存储默认值。
- 新增多账号仓库/Remote 关联，提供 PR/MR 列表、详情、提交、文件、审查、准确 SHA 的 CI/Pipeline 与只读远端 Diff。创建请求前检查权限、已推送分支、Fork 目标和重复请求并确认；结果未知时先查询再重试。Dashboard 增加轻量协作摘要。
- 完善双语原生托管设置、官方图标、整卡点击、居中空状态、GitHub 自动打开验证页和完整焦点环。GitLab 使用普通浏览器标签与一次性 State 绑定应用回调；保持关于标签最右侧与原标签 ID，保留 v1.4.4 Git 原生认证、自动 Fetch、SSH 和生产更新身份。

## 1.4.4 — 2026-10-16

- Unify Automatic Fetch with native Git authentication across HTTP/HTTPS/SSH/Git/local transports and hosting platforms. Reuse configured helper forms and original SSH commands/configuration, Agent/file identities and wallets; remove saved-password/Agent prerequisites so public repositories work anonymously. Preserve get-only helper delegation, native matching and full OAuth/partial responses.
- Use Git's default remote when no upstream is set, retain Clone account bindings before automatic admission, and scope a prepared private Agent to its repository/authentication identity. Reevaluate legacy authentication-policy blocks once while preserving success history and actual rejection/cancellation.
- Show HTTP's unencrypted transport warning and distinguish readiness from verified Fetch. Retain managed HTTPS Token isolation/no-UI reads, TLS/host verification, Index/FETCH_HEAD, queues and safe tracking-ref restrictions. Fix installer layout/unmount ownership with older same-name volumes mounted.
- 自动获取统一复用 Git 原生认证，覆盖 HTTP/HTTPS/SSH/Git/本地及各托管平台；支持全部原有助手形式、SSH 命令/配置、Agent/文件身份和钱包，不再以已保存密码或 Agent 作为获取前提，公开仓库可匿名获取。保留只读 get、原生匹配及完整 OAuth/分段响应。
- 无上游时沿用 Git 默认远程；Clone 在自动检查前保存所选账号；专属 Agent 按仓库及认证身份隔离。旧策略阻塞仅重查一次，保留成功历史及真实拒绝/取消。增加 HTTP 明文提示与实际获取验证状态，保留托管 HTTPS Token、TLS/主机验证、Index/FETCH_HEAD 和安全跟踪引用边界；修复同名安装卷布局和卸载归属校验。
- Release v1.4.4 (24) as a Universal DMG with the existing production update signature identity. 发布 v1.4.4（24）Universal DMG，保留生产更新签名身份。

## 1.4.3 — 2026-10-16

- Stabilize Fetch queue regressions with explicit cancellation and worker-release barriers. Exercise 128 manual/automatic handoffs, preserve the result of already-completed Fetches, and remove timing assumptions from duplicate-admission/retry coverage.
- 稳定 Fetch 队列回归测试：明确等待取消信号并控制工作任务放行，覆盖128轮手动/自动交接和已完成获取的结果保留，移除重复提交与重试测试中的延时假设。
- Release v1.4.3 (23). Prevent Automatic Fetch from opening legacy login-Keychain authorization dialogs. Disable interaction in dedicated credential helpers, reject unprepared background reads and Askpass fallback, and disable SSH Keychain passphrase lookup only for automatic checks. Add isolated denied-ACL and command-entry regressions.
- 发布 v1.4.3（23）。修复自动获取反复弹出传统登录钥匙串授权窗口：在专用凭证子进程禁用交互，拒绝未准备的后台读取与 Askpass 回退，仅自动检查禁用 SSH 钥匙串口令查询，并增加隔离 ACL 拒绝及命令入口回归。

## 1.4.2 — 2026-10-16

- Release v1.4.2 (22) with opt-in Automatic Remote Checks in Git settings, separate from external-change watching: current repository checks every 10/15/30/60 minutes (15 by default), other workspace repositories every 45 minutes in staggered batches, at most two Fetch operations. Check only while active and online, defer during Git writes, honor monotonic deadlines and persisted backoff, and give manual operations priority.
- Reuse the reviewed Fetch engine and common-directory coordination. Check the branch's upstream remote only; deduplicate identical Worktree targets, revalidate configuration, reject Mirror/custom refspecs and interactive transports, forbid background prompts, tags, Prune and automatic maintenance, and retain TLS/SSH verification, hooks, Index and working files. Persist opaque target identities/timestamps atomically without remote URLs or server diagnostics.
- Separate local snapshot age from successful remote-check age. Keep valid ahead/behind counts after failed checks, expose checking/overdue/failure/authentication states, update tracking counts without resetting repository browsing or drafts, and show Pull/Push counts plus divergence/upstream tooltips.
- Add an aligned native mixed-state Select Matching checkbox including collapsed Worktrees. Clear only the selected entries accepted into a reviewed Fetch queue; preserve cancellation and unsubmitted error selections. Background checks never alter selection or open review/results trays. Collapse successful manual Fetch details after five seconds, retaining failures and reviewed retries.

简体中文：

- 发布 v1.4.2（22）。Git 设置新增独立于外部监听的自动远程检查，默认关闭；当前仓库可选10/15/30/60分钟（默认15），其他仓库约45分钟、错峰最多两并发，仅活动且联网时执行，写操作期间延后，保留跨重启时间与有限退避，手动操作优先。
- 复用现有 Fetch 与 Common Directory 队列，仅检查当前分支上游远程，关联 Worktree 去重并重查配置，保守跳过 Mirror/自定义 RefSpec/交互传输。后台禁交互、标签、Prune 和自动维护，保留TLS/SSH验证、Hooks、Index和工作文件；原子保存目标摘要及时间，不保存远程URL或服务器诊断。
- 区分本地扫描与成功远程检查时间；失败保留有效领先/落后数据，显示检查中、过期、失败和认证提示；仅回写跟踪计数，保留草稿及浏览状态。Pull/Push增加数量和分叉/无上游提示。
- 表头增加与行对齐的原生三态“选择匹配项”，包括折叠Worktree；确认Fetch后只清除已被队列接受的选择，取消和未提交错误项保留。自动检查不干扰选择或打开审查/结果栏；手动成功详情五秒后收起，保留失败与审查重试。

## 1.4.1 — 2026-10-15

- Redesign the native Dashboard with a centered adaptive workspace, five clickable overview metrics, compact search/filter/sort controls, aligned repository columns, worktree indentation and contextual batch selection. Preserve AND filtering, selection outside current results, local-only snapshots, reviewed Fetch and independent repository sessions; expose full failure details and shared native repository menus. Add disposable native visual/interaction coverage and pure listing regressions.
- Prevent a child process that closes standard input early from terminating GitPier with SIGPIPE. Disable the signal only on the parent stdin write descriptor, preserving command diagnostics, cancellation, timeouts and process-wide signal handling. Add an isolated default-SIGPIPE regression for early/partial reads and normal input delivery.

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
