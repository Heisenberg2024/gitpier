# Hosting credential storage — v1.5.1

## v1.6.0 disconnect recovery and review drafts (unreleased)

Review APIs continue through `OAuthTokenManager`; they do not read or write storage directly. Unpublished review text stays in memory and is excluded from hosting metadata, credentials, disconnect journals and logs. Closing does not publish it.

Alongside `workspace.hosting.json`, `workspace.hosting.json.disconnects/` holds per-account UUID JSON intent files (directory 0700, files 0600). They contain only identity and remaining cleanup modes. Load overlays durable intents onto older metadata, removing active accounts/bindings before lazy credential restoration. Successful cleanup saves main metadata before removing the intent. A zero-copy recovery row means credential removal succeeded but saving its completion must be retried. If both persistence destinations fail, the current session is still stopped, credentials are preserved and cleanup waits for an explicit retry; restart durability cannot be promised before a write succeeds. Existing formats, keys and Keychain ACLs stay compatible.

简体中文：审查继续通过 OAuthTokenManager 获取有效 Token，未发布正文仅在内存，不进入凭证、元数据、断开日志或普通日志。断开意图保存在 hosting JSON 旁的 `.disconnects/` 每账号 UUID 文件，目录0700/文件0600，只含身份和待清理介质；启动覆盖旧活动记录，清理完成先保存主元数据再移除日志。空副本恢复行表示凭证已删但完成状态需重试保存；双写全失败时仍停止内存会话、保留凭证并等待主动重试，不能承诺此时重启持久性。原凭证格式、密钥与 ACL 保持。

GitPier uses one OAuth/PAT account and token lifecycle with two persistence backends. Git network authentication remains independent.

| | Local Encrypted Vault (default for new accounts) | macOS Keychain |
|---|---|---|
| Protection | CryptoKit AES-256-GCM, per-account random 256-bit key, private local files | Existing `GitPier.hosting.oauth` service, exact account UUID, macOS access control |
| Restart | Lazily decrypt once into a shared memory session | Explicit Verify Connection; read once into shared memory |
| Passwords | No master password or OAuth Keychain authorization | macOS may request authorization, including after ad-hoc updates |
| Security boundary | Access to both the key and ciphertext allows decryption | OS-managed credential access permissions |

The global default in Settings → Code Hosting applies only to future accounts. Each account persists its own `storageMode` in version-2 hosting metadata beside `workspace.json` (normally `workspace.hosting.json`). Version-1 accounts lacking that field retain Keychain. Unknown versions/modes are rejected without overwriting the file. Startup loads only metadata, with no batch migration or credential reads.

## Local vault

Default directory: `~/Library/Application Support/GitPier/HostingCredentials/`. Isolated workspaces use `HostingCredentials` beside their own workspace file.

- `keys/<account UUID>.<key UUID>.key`: 32 random bytes from `SymmetricKey(size: .bits256)`.
- `vault/<account UUID>.<generation UUID>.sealed`: one complete encrypted token pair, including type, optional expiration dates and scopes. CryptoKit's combined format includes a 96-bit nonce and authentication tag.
- `vault/<account UUID>.json`: nonsecret version/key/generation pointer. Keys are never embedded in this pointer or account metadata.
- `<account UUID>.lock`: private advisory lock, containing no token or key.

Directories are 0700 and files 0600 from creation. Descriptor-relative `openat`/`renameat` IO rejects symlinks, unsafe ownership/permissions, nonregular files and hard links. New key/ciphertext files are fsynced before atomic pointer replacement; interruption before replacement keeps the old record authoritative. A later successful save or explicit account deletion removes orphan material belonging only to that UUID. Nonsecret metadata also uses private atomic writes. No plaintext token temporary files or UserDefaults entries are created.

Each encryption uses CryptoKit's fresh random nonce. Refresh reuses the current account key; reauthorization rotates it. Sorted-key JSON associated data binds format version, provider, canonical instance, account UUID, stable user ID, key UUID and generation UUID. Missing keys, damaged data, wrong keys, altered tags and changed bindings fail closed. Reauthorization can replace a damaged record.

Random key files are protected by user permissions, not hardware. The scheme cannot resist malware with complete access to the current user's files. Source disclosure does not reveal independently generated keys, but GitPier is not the only program capable of decryption. FileVault adds protection when the disk is locked; backup copies of keys and ciphertext must receive equivalent protection. Ordinary deletion on SSDs is not guaranteed physical erasure.

## Sessions, refresh and migration

All windows share the AppStore's actor token manager. Authorization validates the provider's stable identity before installing the pair in memory. No immediate readback is required after saving either backend. Local loads and refreshes are single-flight per account; unrelated accounts continue independently. PATs never invoke OAuth refresh. A failed installation or refreshed-pair save leaves the newly obtained pair in memory with a session-only warning. Reauthorize before quitting; restart may need new authorization, because a rotated old refresh token may already be invalid. A nonsecret recovery marker is saved when possible so restart refuses the known stale persisted pair. Account OAuth configuration must match the account’s provider/instance; stale client configurations are rejected before refresh.

Use **Change Storage Method** for one account. The confirmation explains the destination security tradeoff. Reauthorization into the destination is recommended and does not read old Keychain tokens. The current memory token can also be used. Reading a stored source requires explicit selection and may request macOS authorization. Both backends use the same providers, account IDs, refresh and APIs.

Migration refuses to race an active refresh, freezes that account's persistence, records `pendingMigration`, saves the destination, then atomically commits `storageMode` and `pendingCleanup`. Before that metadata commit the source remains authoritative, including after interruption or failed metadata saving. Source tokens/keys are never deleted as part of the commit. Successful migration invalidates account API caches. A stale window cannot retarget a token to the previous mode.

Previous-copy cleanup is an explicit separate action or confirmation option. Keychain cleanup can be postponed without blocking Local Vault use. Interrupted migration targets remain visible for retry/cleanup. Disconnect first removes the active account/bindings, cancels account work and permanently invalidates its in-memory session. It journals a disconnected record before deleting the current credential and then each retained or interrupted-migration copy independently. A denied Keychain deletion cannot keep the Local Vault credential active. Remaining copies are explicitly listed under disconnected credentials, survive restart as cleanup-only records and can be retried without loading tokens or reconnecting. macOS authorization is never bypassed. If the cleanup metadata itself cannot be saved, the application reports the restart limitation and keeps the current process disconnected. Disconnect does not revoke the provider grant. Official grant pages: [GitHub](https://github.com/settings/applications), [GitLab.com](https://gitlab.com/-/user_settings/applications); self-hosted instances manage grants on that instance. Git credentials, Git remotes/configuration, SSH, repositories and other accounts remain independent.

Local Vault avoids OAuth Keychain access. Git transport helpers, existing GitPier HTTPS credentials and update signing can still use Keychain; this is not a promise that the whole application never accesses Keychain.

## 简体中文

新 OAuth/PAT 账号默认使用本地加密凭证库，系统钥匙串仍可按账号选择。全局默认只影响未来新账号；旧配置缺少模式字段时继续按 Keychain 解释，不自动迁移、读取或删除。账号元数据独立保存实际 `storageMode`，支持两种模式并存。

本地目录通常为 `~/Library/Application Support/GitPier/HostingCredentials/`；隔离工作空间使用自身 workspace 文件旁的同名目录。`keys` 保存各账号独立的256位随机密钥，`vault` 保存 AES-256-GCM 完整 Token 对和非敏感版本指针。目录0700、文件自创建即0600，检查所有权、拒绝不可信链接，原子切换前保留原版本。每次加密生成新 Nonce，刷新复用密钥，重新授权轮换密钥；Associated Data 绑定格式、平台、规范实例、账号/用户及版本身份，篡改或错配会拒绝解密。

本地模式不需要主密码或 OAuth Keychain 授权，但密钥也保存在本机：同时获得密钥和密文即可解密，不能抵抗具备当前用户完整文件读取权限的恶意程序，不具有硬件隔离。FileVault 增强磁盘锁定时的保护。系统钥匙串使用原 `GitPier.hosting.oauth` 与 macOS 访问控制，ad-hoc 更新后仍可能重新要求授权，不修改 ACL。普通 SSD 删除不保证物理擦除。

窗口共用内存会话，本地凭证按需读取一次；Keychain 重启后明确“验证连接”。OAuth 刷新合并并整对保存，PAT 不刷新。保存失败保留刚取得的新 Token 供当前会话使用并明确提示，重启可能需重新授权，不能假定已轮换的旧 Token 仍有效。会尽可能保存非敏感恢复标记，使重启拒绝读取已知过时的旧凭证；OAuth 配置必须匹配账号自身实例，旧客户端配置在刷新前被拒绝。

逐账号迁移须确认，推荐重新授权至目标以避免读取旧 Keychain；也可使用内存 Token 或明确允许读取原凭证。先记意图、保存目标，再原子切换元数据，之前始终以原模式为准；失败、中断或取消不会提前删除原凭证。迁移与刷新不同时进行，其他账号继续可用。旧副本由用户确认后清理，钥匙串授权可以暂缓；中断目标可重试或主动清理。断开优先移除活动账号/关联、取消账号请求并永久失效当前内存会话；持久记录已断开状态后，先删除有效凭证，再独立尝试历史副本和中断迁移目标。历史 Keychain 删除被拒绝不会让 Local Vault 凭证继续生效。剩余副本显示在已断开凭证列表，重启后仍仅用于主动重试清理，不读取 Token 或恢复登录，也不绕过 macOS 授权。若清理记录本身无法保存，会明确提示重启限制并保持当前进程断开。该操作不自动撤销平台授权，不更改原 Git 凭证助手/SSH/Remote/仓库或更新签名。Git 网络认证仍可能访问系统钥匙串。

Implementation references: [Apple AES.GCM](https://developer.apple.com/documentation/cryptokit/aes/gcm), [random symmetric keys](https://developer.apple.com/documentation/cryptokit/symmetrickey/init(size:)).
