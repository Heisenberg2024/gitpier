# Security & privacy

## v1.6.1 operation recovery (released 2026-10-18)

Confirmed review writes require a durable local intent before HTTP mutation begins. `~/Library/Application Support/GitPier/workspace.review-operations/` holds versioned JSON batches (0700 directory, 0600 files); custom workspaces use the same `review-operations` extension beside their own workspace file. Identity, SHA/version, operation type/state, timestamps and opaque receipt/reviewer IDs are stored. No tokens, keys, headers, comment bodies, body hashes, source paths, Diff or code are recorded. This metadata can still reveal account/repository/request identities and activity; private file permissions do not provide cryptographic tamper resistance against the same user.

A possibly sent operation remains Unknown after a crash. Unreadable, unsafe or incompatible history is preserved and blocks new review writes; it never deletes credentials. Known receipts can be inspected using GET under an explicitly selected saved binding, with fresh stable-ID checks. Missing bodies/anchors cannot be fully verified after restart. A second manual acknowledgement clears only the block and never retries a request. Completed-history cleanup never removes an unresolved batch. Normal close warns before discarding memory-only bodies; disconnect explicitly discards this account's drafts across windows and keeps unknown metadata.

The journal checks namespace synchronization for same-device parent directories, then requires file `fsync`, atomic rename, directory `fsync` and macOS `F_FULLFSYNC`. A failed or unsupported barrier prevents sending; failure after a later state replacement retains the live Unknown barrier, including failed manual acknowledgements, until a successful explicit retry. This requirement is specific to the review journal and does not change the existing Vault format or write path. Filesystem/device guarantees still apply; deterministic fault tests are not physical power-loss testing.

Disconnect/shutdown clear both session drafts and the coordinator's cached private reports/contexts. Stable consumed-confirmation and uncertain-item IDs remain to prevent replay. Already running tasks/HTTP requests can retain their confirmed payload until cancellation or a response settles; late results are journaled without restoring the report cache. No secure memory erasure is claimed.

Active and unknown write protection follows the stable remote user and target across local account UUID changes after reconnection. Receipt inspection and acknowledgement remain bound to the original local account identity; a new connection cannot implicitly acknowledge an old operation or access its credential.

简体中文：审查写入必须先安全持久化意图。默认日志在 `~/Library/Application Support/GitPier/workspace.review-operations/`，自定义工作区使用其旁同扩展目录，目录0700/文件0600。只保存稳定身份、SHA/版本、操作类型/状态、时间与不透明结果/审查者 ID，不保存 Token、密钥、请求头、正文、正文哈希、源码路径、Diff 或代码。身份与活动仍是私有元数据，同用户文件权限不等于密码学防篡改。异常退出后可能已发送的操作保持未知；日志损坏/不兼容会保留原文件并阻止新写入，不删除凭证。已知结果可在明确选择的关联下只读回查，但无法完整恢复正文/位置；二次人工确认仅解除阻止，不重试请求。正常关闭提醒丢弃内存正文，账号断开确认所有窗口的丢弃并保留未知元数据。

日志检查同设备父目录的命名空间同步，依次要求文件 fsync、原子替换、目录 fsync 和 macOS F_FULLFSYNC。同步失败或不受支持时不发送；后续状态替换或人工确认的最终屏障失败，当前进程仍保留 Unknown，需显式成功重试。此严格路径仅用于审查日志，原 Vault 格式与写入路径保持。保证受文件系统和设备能力约束，故障注入测试不代表实际断电测试。

断开/关闭会清理会话草稿及协调器缓存的私有报告/版本上下文，只保留已消费确认与未知条目 ID 以阻止重发。已运行的任务或 HTTP 请求可能持有已确认正文，直至取消或响应结束；迟到结果仍记最小日志，但不恢复私有报告缓存，不声称安全擦除内存。

同一远端用户重连生成新的本地账号 UUID 后，仍共享原目标的正在发送/未知写入保护。结果回查、凭证读取与人工确认继续绑定原本地账号，新连接不能隐式核实旧操作或访问旧凭证。

## v1.6.0 review writes (released 2026-10-18)

Review comments and approvals are explicit remote writes using the selected Hosting account, independently of Git transport. Immutable confirmation snapshots bind the stable account/repository/request and revision; complete patches and exact file coordinates validate inline positions. A shared per-target lock rejects duplicate concurrent submissions. Successful writes require stable-ID readback; ambiguous network, cancellation and verification outcomes preserve the draft and block automatic reposting. No review action applies code, changes local Git state or triggers Fetch/Push. Remote bodies remain plain text. See [provider capabilities and recovery](docs/code-review.md) for permission and API limitations, including Gitea's disabled formal-review/pending writes that may publish another client's draft, and unverified inline creation.

Disconnect records a private per-account intent before asynchronous cleanup. A durable journal suppresses stale account/binding metadata after restart. If both metadata and journal writes fail, memory remains disconnected, credentials are retained and explicit retry is required; no cross-restart guarantee is claimed in that state. Journals contain identity/cleanup metadata, never tokens or drafts. Existing Keychain ACLs and credential formats remain intact.

简体中文：审查评论/审批是用户确认后的远程写入，使用所选托管账号，与 Git 认证分离。提交快照绑定稳定身份和版本，逐行位置校验真实 Patch；共享锁阻止重复提交，成功后按服务器稳定 ID 回读。网络、取消或回读结果未知时保留草稿并阻止自动重发。不应用代码、不修改本地 Git、不触发 Fetch/Push、不执行远程正文。断开意图在异步清理前私有持久化，重启时抑制旧账号；元数据与日志双写全失败则保留内存断开、凭证和重试入口，并明确此时跨重启无保证。凭证格式与 ACL 保持。

GitPier runs Git, SSH, and terminal commands locally with the current user's privileges. Repositories, hooks, shell startup files, credential helpers, and external tools should be trusted before opening or running them. GitPier is distributed outside the macOS App Sandbox.

Managed HTTPS tokens are stored in macOS Keychain. Local workspace configuration contains repository paths, drafts, preferences, and credential-profile metadata, including SSH identity paths. Terminal output is not logged to disk by GitPier. Remote operations use the configured Git remotes; there is no GitPier upload or analytics service.

## Reporting a concern

Never put tokens, private keys, private repository contents, or unredacted logs in a public issue. Use GitHub's private vulnerability reporting if the owner has enabled it. If no private channel is available, request one without including sensitive details. No dedicated security contact or private reporting channel is configured yet.

If a credential has entered a public repository or log, revoke or rotate it first. Removing the working-tree file or adding an ignore rule does not remove it from existing Git history.

## Application updates (released in v1.1.0)

Sparkle 2 fetches the stable feed over GitHub HTTPS and authenticates both feed/embedded release notes and final DMG using Ed25519 signatures. Archive verification happens before extraction. Signed-feed failures never expire into a degraded fallback mode. SHA256 is a manual integrity check, not a substitute for source authentication. Missing production keys disable updates; missing/invalid signatures, altered archives, incompatible versions or broken bundles must not be installed. Sparkle owns replacement and rollback behavior; GitPier does not run an ad-hoc shell installer or request root access.

Production private keys remain in the owner-controlled login Keychain; offline encrypted backups are essential. No production key enters public CI, source, application resources or command arguments. Without Developer ID signing, losing the EdDSA key can prevent trusted automatic recovery or rotation and require a manually verified reinstall. See [development](docs/development.md) for backup and recovery commands.

Updates do not send repository data or a system profile. Automatic checks default off; download/install/restart require confirmation. Git work prevents termination, and existing conflict-draft/terminal warnings remain in force. Failed checks/downloads or cancellation leave the workspace and running old app available. Read-only mounts and App Translocation require installation in a writable trusted location or a manual DMG upgrade.

Current builds are ad-hoc signed and **not Apple Developer ID signed or notarized**. EdDSA update authentication does not change Gatekeeper trust. Never disable Gatekeeper, strip quarantine or bypass Sparkle verification to make an update succeed. v1.0.3 requires a one-time manual upgrade because it contains no updater.

## History recovery and working-tree management (released in v1.2.0)

Reflog and branch comparison are local queries; Blame never changes the Index or working files. Recovery branches require an available commit object. Expired logs and garbage-collected objects may be unrecoverable. GitPier does not automatically run garbage collection, reflog expiry, hard reset or worktree pruning. Explicit soft/mixed reset retains the existing stale-review checks and confirmation boundary.

Released v1.3.0 Interactive Rebase requires an explicit reviewed history plan, preserves native hooks/signing/reflog and unfinished Git state, and never automatically stashes or force-pushes. Selected-line staging validates the displayed patch, locks the real Index, applies to a private copy and publishes only after state revalidation. It does not modify working files, clear other staging or fall back to whole-file staging. Complex metadata/filter/encoding boundaries fail explicitly; a malformed optional rebase message plan cannot block native Abort.

Released v1.4.0 workspace scans/searches read only registered local repositories, disable lazy fetching, and keep snapshots/queries in memory. Partial-clone local queries require Git 2.43+; older Git retains ordinary-repository support and receives a clear query limitation for partial clones. Batch Fetch requires repository/remote review, rechecks root/common metadata identity and remote configuration, uses existing credential isolation and coordinated queues, and preserves working files, Index and FETCH_HEAD. It never chains Pull, Push, Merge, Rebase, Stash, Checkout or Reset. Search pathspec metacharacters are escaped; output/result bounds and cancellation apply. Optional performance instrumentation stores only command categories, timings and counts, never search arguments or credentials.

Patch imports show affected files and a distinct Working Tree/Index target, check native applicability, and reject stale file/index state, traversal, Git metadata, nested repositories and unsupported formats. Encoded/decoded binary limits are enforced before applying. LFS installation, filters, hooks, object cleanup and history migration are never automatic; Pull requires configured filters and protected checkout after fixed-ref download. Submodule operations reserve parent/child queues, preserve other worktrees and Index content, refuse local/ignored-file overwrites, and never force, recursively update, deinitialize or remove directories. Failed or cancelled clones remain for review instead of being automatically deleted.

Worktree removal is a distinct disk operation, separate from removing a sidebar record. It requires an explicit affected-path review and matching GitPier creation receipt and metadata UUID marker. Detached commits require a retaining branch or tag first. Main repositories, unknown working directories, locked/missing/prunable trees, unfinished operations and modified/untracked/ignored files are refused. Active terminal sessions and unsaved drafts must be preserved first. Revalidation runs inside the shared metadata queue; no `--force` bypass exists. Repair only updates metadata for a verified moved linked tree in the same common directory and never moves or deletes its files. Filesystem/Git permissions and external Git safety checks remain active.

## Background authentication (v1.4.4 development)

Automatic Fetch uses the same native Git authentication configuration as manual Fetch, independently of platform or credential-helper name. A get-only projection preserves Git's helper command transformation, URL/account/path matching, empty resets, order, partial responses and OAuth authentication fields. Git never calls store/erase automatically; helpers may perform their own native refresh or storage during get. Credentials stay in native sources and protocol pipes, not workspace JSON or diagnostics. Helpers and SSH commands configured by the user execute with the same user permissions as manual Git.

Native credential sources include core.askPass, original GIT_ASKPASS and SSH_ASKPASS programs, in Git's precedence order. The application-owned fallback Askpass remains blocked in background. Actual Fetch decides whether credentials are required. Public repositories do not need a saved password. SSH retains configured commands/variants, static and dynamic config, ProxyJump/ProxyCommand, agents, file identities, providers and native Keychain behavior. GitPier does not force UseKeychain=no, replace the SSH command, source shell startup scripts or disable TLS/host verification. New terminal prompts and GitPier fallback login UI are disabled; configured Git/SSH Askpass providers and native tools retain their original authorization behavior; an arbitrary helper cannot be guaranteed to suppress all UI. Cancellation and timeouts stop the operation; real rejection pauses the target.

GitPier-owned managed HTTPS Tokens retain host/account/protocol isolation and dedicated no-UI background reads. Explicit foreground authorization does not copy credentials or widen ACLs. Ad-hoc binary upgrades can require a new grant for managed credentials; native helpers retain their own executable identity. HTTP remote URLs remain unchanged and transmit credentials/data without encryption; settings warn about this. Managed HTTPS Tokens refuse HTTP.

Existing credentials must be available to the app's Git process through persistent configuration, native storage or an inherited environment. An unsaved interactive password, an expired login, or a socket/token available only inside another terminal session is not transferable automatically. Standard Homebrew helper locations are appended without changing existing PATH precedence; shell startup files and user/global Git/SSH configuration are not modified.

Prepare SSH Authentication remains an optional explicit action. A private Agent is created only when requested, uses a one-hour identity lifetime and is stopped on normal exit. Its socket is bound to the prepared repository and authentication identity; it never replaces another repository's inherited Agent. The conservative SSH inspection used for this optional preparation is not an Automatic Fetch prerequisite.

自动获取与手动获取共用 Git 原始认证配置，不按平台或助手名称限制；只读 get 投影保留助手顺序、URL/账号/路径匹配、空重置、分段响应和 OAuth 字段。Git 不在后台调用 store/erase；助手自身仍可能按原逻辑刷新和保存凭证。公开仓库无需预先保存密码，认证需求由实际获取决定。原生 SSH 配置、命令、Agent、文件身份、Provider 和钥匙串保持原行为，不强制关闭钥匙串或削弱 TLS/主机验证。

禁止新增终端登录和 GitPier 回退登录框；原有 Git/SSH Askpass 程序和助手可能按其原有行为请求系统授权，任意助手不能保证完全无界面。GitPier 自有托管 Token 仍仅 HTTPS，后台禁止系统授权 UI，主动授权不复制秘密或放宽 ACL。HTTP 会明文传输凭证和数据，设置中明确提示。凭证必须可由应用 Git 进程访问，未保存密码、过期登录或另一个终端私有的 Token/Agent 无法自动恢复。专属 Agent 仅绑定主动准备的仓库及认证身份，不覆盖其他仓库的原始 Agent；不修改用户 Git、SSH 或 Shell 配置。

An explicitly selected GitPier HTTPS Token remains exclusive: native Askpass must not substitute another account when that Token cannot be read. A server-challenged negative regression verifies this with a valid original Askpass provider and an unavailable selected Token.

## v1.5.0 hosting accounts

Hosting OAuth/PAT is independent of Git transport authentication. New accounts default to CryptoKit AES-256-GCM with separate, random per-account 256-bit keys and ciphertext in private local files. Keys are stored on this Mac without a master password or Keychain; simultaneous access to keys and ciphertext permits recovery. This does not isolate credentials from malware with the user's full file access. FileVault adds locked-disk protection. Optional `GitPier.hosting.oauth` Keychain storage retains the existing exact account UUID namespace and normal macOS access control. Neither backend touches `GitPier.credentials`. See [credential storage](docs/credential-storage.md).

Public metadata is saved beside the workspace in private versioned hosting JSON. Missing legacy storage modes mean Keychain; unknown modes fail closed. Startup loads metadata only. Local tokens restore lazily; legacy/Keychain accounts require explicit Verify to avoid background authorization dialogs. Shared memory prevents repeated reads. Failed installation or refresh persistence keeps the newly obtained pair only in memory with a session-only warning; an old refresh token may no longer work. Migration journals intent before destination writes and commits the account's mode only after successful saving. Source copies remain until explicit cleanup; Keychain cleanup can be postponed or cancelled. Ordinary SSD deletion is not physical secure erasure. Ad-hoc upgrades may request renewed Keychain authorization; ACLs are never relaxed.

Public Client IDs are identifiers, not secrets. GitHub uses Device Flow; GitLab/Gitea use S256 and one-time expiring state/session-bound callbacks without Client Secrets. GitLab opens the ordinary default browser and uses the registered private-scheme AppDelegate callback with state/PKCE validation, expiry, size limits and one-time consumption. It does not use ASWebAuthenticationSession; macOS routes the URL to the configured installed handler, while PKCE protects code exchange. Browser window/tab policy is left intact; the API transport remains ephemeral and cookie-free. GitLab optionally uses an instance-registered fixed loopback port; Gitea binds an ephemeral listener only to 127.0.0.1. Callback size, path, Host, state, lifetime and duplicate consumption are checked. Cancellation/termination closes the listener and cancels pending work. No public relay is required.

The API client uses system HTTPS trust, ephemeral URLSession, no cookies/credential store, no redirect following, bounded responses/timeouts, cancellable safe-read retries, reconstructed pagination and account/instance/repository-partitioned memory caches. Credentials are never attached to response-provided URLs. Errors use fixed local text and never persist response bodies or token-bearing headers. Refresh rotation saves the whole pair atomically and rejects late results after account changes. Unknown POST outcomes require a query before another attempt. Remote text has no active HTML/Markdown resources, and remote Diff has no Index mutation callbacks.

GitHub `repo` is broad private-repository read/write access, `public_repo` includes public writes, and GitLab `api` is broad API access. GitPier does not automatically elevate scopes. Gitea OAuth requires recognized v1.23+ granular scopes; older/unsupported instances can use PAT. Disconnect removes local credentials; revoke provider grants separately. GitHub.com/GitLab.com public registrations are configured. Real GitHub.com/GitLab.com read-only consent, restart/unlock and public PR/MR APIs passed on 2026-10-17. Self-hosted policies/certificates/forks, private/write access, actual expiry/refresh and post-upgrade Keychain authorization require separate acceptance. See [OAuth setup](docs/oauth-setup.md).


## Task workspaces and local agents (v1.8.0 development)

Task creation and removal reuse the original Git worktree lifecycle and queues. External association does not grant deletion ownership. Private task records preserve identity/baseline/session/review metadata and an optional explicitly saved description, without prompts, transcripts, source contents, terminal output or credentials. Invalid records are preserved and block changes. Archive never deletes files. See [task workspace boundaries](docs/task-workspaces.md).

A navigation failure after registration never rolls back task/worktree creation. Confirmed detail writes retain their per-task lifetime and single-flight protection across UI refresh; cancellation of a query is not evidence that a persisted mutation rolled back.

Task-detail navigation revalidates its request and task/repository/page selection identities before committing selection. Superseded requests cannot open terminals or replace newer selections. Selection commit is the boundary: source-view cancellation afterwards preserves the completed result. This does not cancel confirmed writes or running agents; Operations Center opens retain an independent lifetime.

Codex detection uses bounded version/help and complete-argument parser probes. Explicit login status checks use the same environment as the confirmed PTY, discard output, and never inspect credentials. An optional validated Codex Home applies only to these children. Pending creation records capture original identities before the ownership marker; recovery cannot grant external worktrees removal rights from a path or marker alone. Confirmed direct-argv PTY launches retain Codex's approval/sandbox mechanisms and existing local configuration; GitPier never installs Codex or reads/modifies its authentication. Independent worktrees are not OS sandboxes, and native GitPier confirmations do not constrain each internal Codex command. Quit/Stop verify current process identities and wait for attached-process cleanup; intentionally detached processes may require manual inspection. Restart marks unfinished sessions Interrupted without automatic replay. Exit zero is not task/test success.

External navigation cannot authenticate the official CLI. Unknown repository registration requires explicit confirmation with Cancel default, followed by filesystem/root/common-directory revalidation. No external execution/agent endpoint exists; OAuth state/PKCE remains separate.

登记后的导航失败不会回滚任务或工作树创建。详情确认写入按任务保留生命周期并防重复，刷新查询的取消不代表持久化修改已回滚。

详情导航在提交选择前复核请求及任务/仓库/页面选择身份，过期请求不能创建终端或覆盖新选择；选择提交后，来源视图取消保留已完成结果。导航取消不停止确认写入或运行中的 Agent，操作中心打开保持独立生命周期。

简体中文：任务复用原 Worktree 所有权/写队列，外部关联不授予删除权；私有元数据不保存 Prompt、对话、源码、终端输出或凭证，坏记录保留并停止修改，归档不删文件。Codex 主动检测版本/帮助及完整参数组合，登录检查与PTY共用有效环境并丢弃输出；可选Codex Home仅影响本应用子进程，不读凭证。创建前保留私有预留、标记前捕获原身份，恢复不单凭路径/标记授予外部工作树移除权。确认后以参数数组启动，保留自身审批/沙箱及原配置，不安装、不读改认证。Worktree 不是系统沙箱，GitPier 确认无法约束 Codex 内部命令。停止/退出核对进程身份并等待关联进程；脱离会话的进程可能需手动检查。重启不自动执行，退出码0不等于任务/测试成功。外部URL不能证明CLI来源，陌生仓库需默认取消的确认及身份复核，无外部执行入口，OAuth隔离保持。

## v1.7.0 navigation and operation observation

The CLI accepts only local open/page navigation. It never constructs shell commands, accepts credentials, invokes arbitrary Git commands or bypasses app write confirmations. `gitpier://navigate/open` rejects unknown/duplicate query fields and is separate from `gitpier://oauth/gitlab` state/PKCE handling. Both ends validate access and working-tree identity; Launch Services targets the user's selected app without changing the production default handler in tests.

The user-directory installer creates names exclusively, refuses directory/file links and unsafe ownership/permissions, and does not overwrite even an existing owned launcher. A private schema-1 receipt contains only the launcher hash, selected installation location, app bookmark and Bundle ID. Uninstall requires matching current regular-file content and ownership. Same-user file access is not a cryptographic trust boundary against malicious software already controlling that user's files; unknown or changed installations require manual inspection. No administrator privileges or global Shell/Git/SSH configuration changes are requested.

Operations Center keeps typed, bounded summaries in memory and forwards cancellation to original task owners. Cancelling does not promise rollback or non-delivery. Remote Review Unknown is reconciled only through the existing journal/recovery flow; no generic retry/replay is available. The center does not persist command arguments, review bodies, tokens or process output.

简体中文：CLI只导航，不接收凭证、拼接Shell或绕过Git确认，URL与OAuth严格分离并双端核实路径/仓库。安装不覆盖已有文件，拒绝链接与不安全权限；卸载核实私有归属凭据及当前哈希。拥有同一用户文件权限的恶意程序不属于凭据能隔离的密码学边界。操作中心仅保存类型化内存摘要，取消不代表回滚或远端未收到，Review未知继续由原日志核查，不自动重放。
