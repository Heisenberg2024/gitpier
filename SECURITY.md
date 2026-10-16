# Security & privacy

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

Automatic HTTPS uses Git's credential matching and ordered read-only projections of supported helpers. Tokens travel only through pipes/Keychain and are never stored in workspace JSON or diagnostics. Native store/cache remain user-managed; GitPier does not migrate their secrets. Unknown helpers, custom SSH commands and external ProxyCommand executables have no automatic execution contract. TLS and SSH host verification remain enabled, including jump hosts.

Authorize Background Access is an explicit current-remote action. It can show the macOS authorization dialog and then checks silent access again; GitPier never approves that dialog, widens an ACL or copies another application's secret. Manual osxkeychain and GitPier are different Keychain clients. Legacy login-Keychain ACL approval may not survive an ad-hoc-signed binary change, even with the same Bundle ID. If silent access still fails, keep automatic checks paused and use the explicit recovery/settings workflow. No Developer ID requirement or weaker Keychain policy substitutes for authorization.

Prepare SSH Authentication uses system ssh-add and an existing agent, or an application-private agent only after the user requests it. Passphrases are not persisted. Private-agent key lifetime is one hour; normal shutdown terminates the agent, but an abnormal application exit may leave it alive until the key lifetime expires. Existing external agents retain their own lifetime/policy. Authentication capability does not imply server access or a successful Fetch.

自动 HTTPS 仅使用受支持助手的只读投影，仍由 Git 匹配 URL、账号、路径与顺序；秘密不进入普通配置或诊断。主动授权才允许系统对话框，GitPier 不替用户批准、不放宽 ACL 或复制其他应用的秘密。同一 Bundle ID 的 Ad-hoc 升级也可能需要重新授权。SSH 初始化使用系统 ssh-add，不保存口令、不改 SSH 文件；专属 Agent 仅在主动操作后创建，钥匙存活时间一小时，正常退出清理，异常退出仍可能存活至身份过期。服务器权限仅以实际 Fetch 结果确认。

Automatic SSH preflight statically checks the bounded user/system Include tree before running ssh -G: Match exec (including negation), dynamic Includes, external ProxyCommand/LocalCommand/KnownHostsCommand and external providers are unavailable automatically. The scan is conservative across included files, including other Host blocks; regular static Host/Alias/Port/IdentityAgent settings and native ProxyJump remain supported. Existing manual SSH semantics remain unchanged. OpenSSH's unset default $SSH_SK_PROVIDER is treated as the builtin provider.

自动 SSH 会先静态检查用户/系统配置及 Include 链；包含 Match exec、动态 Include、外部 Proxy/Local/KnownHosts 命令或 Provider 时暂停自动认证，手动流程保持不变。检查跨全部被包含的 Host 配置保守执行，不通过 ssh -G 探测后再决定是否运行。普通静态配置及原生 ProxyJump 保留；未设置的默认 $SSH_SK_PROVIDER 属于内置实现。
