# OAuth setup — Unreleased v1.5.0

GitPier's hosting connection runs on the Mac. It uses public Client IDs, S256 PKCE or GitHub Device Flow, ordinary browser authorization and per-account Local Encrypted Vault or macOS Keychain storage. No Client Secret, GitPier account server, token exchange backend or public callback server is required. Git Fetch/Push continues to use existing Git credentials independently.

## GitPier maintainer

Public platform registrations are shared by all GitPier installations. Ordinary users should not register their own GitHub.com or GitLab.com applications.

### GitHub.com

1. Register an OAuth App named **GitPier** under the maintainer's GitHub settings. Use `https://github.com/Heisenberg2024/gitpier` as the homepage.
2. For the registration form's required authorization callback, use `http://127.0.0.1/oauth/github/callback` with wildcard matching disabled. This is a form-only loopback registration: Device Flow does not use it and GitPier does not start a GitHub callback listener.
3. Enable **Device Flow** in the application's settings.
4. Put its public **Client ID** in `githubClientID` in `Sources/GitPier/Resources/HostingOAuthConfiguration.json`. The maintainer registration is configured as `Ov23liOxmvZTkLKYdLF2`. A missing value disables Connect OAuth with an explanation; PAT remains available.
5. GitPier initially requests `read:user` and reads public repository data. Public collaboration explicitly requests `public_repo`; private collaboration explicitly requests `repo`. These repository scopes permit writes; `repo` includes broad private repository access. A previously authorized application may receive previously granted scopes; GitPier displays the returned scopes.
6. Verify a packaged app: Settings → Code Hosting → GitHub → Authorize; GitPier automatically opens the verified GitHub Device Flow page. Copy the one-time code, enter it in that page and approve. Use Open GitHub to reopen the page if needed. Check identity, restart/unlock, read a public request and CI, reauthorize at the chosen level, then disconnect. If expiring tokens are enabled on the application, test device-token refresh and rotation too.

The application does not request `offline_access` automatically and makes no assumption about token expiry. When GitHub returns a refresh token for Device Flow, refresh uses the public Client ID without a secret.

### GitLab.com

1. Register **GitPier** on GitLab.com as a **Public / Non-Confidential** OAuth application. Disable the confidential setting.
2. Register this exact Redirect URI: **`gitpier://oauth/gitlab`**. Keep it stable across releases. GitPier opens the authorization URL with `NSWorkspace` in the ordinary default browser, reusing its normal login and window/tab policy. The packaging script registers `gitpier`; `NSApplicationDelegate.application(_:open:)` forwards callbacks to the active state-bound PKCE receiver. No `ASWebAuthenticationSession` is started, so its per-login macOS website-sharing prompt and dedicated authentication window are avoided. The browser can still ask permission to open GitPier on return.
3. Allow `read_user` and `read_api` for initial read access. If the maintainer wants users to create MRs, the registration must also allow `api`; GitPier requests this broad scope only after the user selects collaboration access and authorizes again.
4. Put the **Application ID** in `gitlabClientID` in the same configuration file. The configured Application ID is `8fd0815fa82ccc41540a1c5ba78d21be59c93af8e086a89a6aa1e81a20da500a`. Do not copy its generated secret into the repository, build environment, application, logs or documentation.
5. Verify browser return, current-user identity, access/refresh token rotation, restart/unlock, MR/CI reads, permission failures, explicit reauthorization and disconnect in the packaged app.

The maintainer has supplied the GitLab.com registration. Packaged-app browser callback acceptance and restart recovery passed on 2026-10-17; see the [development evidence](development.md#real-public-oauth-acceptance--2026-10-17). If the instance refuses a callback or public PKCE configuration, do not add a relay or confidential secret. Report the restriction and use PAT.

## Self-hosted GitLab / Gitea administrators and users

Each independent instance needs its own public OAuth application. An administrator, a group owner or an ordinary user with application registration rights may register it, according to instance policy. Other users of that same instance can reuse its public Client ID. IDs belong to the instance where they were registered and must not be reused for another server.

In Settings → Code Hosting, choose the platform, select self-hosted GitLab if applicable, and enter its HTTPS instance URL (including its installation prefix and port when needed), Client ID and redirect configuration. The configuration contains public metadata only and is saved for reuse on that instance. Select a saved configuration to connect another account. Use the displayed **Copy** action for registration.

| Platform | Public client callback | Requirements |
| --- | --- | --- |
| Self-hosted GitLab | `gitpier://oauth/gitlab` | Register exactly; non-confidential application, PKCE S256 |
| Self-hosted GitLab, optional loopback | `http://127.0.0.1:43827/oauth/gitlab/callback` (or the configured fixed port) | Instance must accept this exact registration; the same port must be available locally |
| Gitea | `http://127.0.0.1/oauth/gitea/callback` | Public client, S256; Gitea allows any loopback port for public clients; GitPier chooses an available port at runtime |

Gitea OAuth uses `read:user read:repository` initially and `read:user write:repository` for user-selected collaboration access. GitPier checks `/api/v1/version` before requesting granular OAuth scopes and requires 1.23 or later. Earlier or unrecognized versions use the PAT fallback; GitPier does not silently request a legacy broad OAuth grant. Server policy, forks, CI/Actions endpoints and PKCE support still require testing on the actual instance.

The listener binds only `127.0.0.1`, accepts the configured path/session/state once, caps request size, times out, and closes on completion/cancellation. It receives an authorization code, never a token. Self-signed HTTPS certificates must be trusted through macOS system trust; GitPier has no bypass.

### PAT fallback

Choose **Personal Access Token**, paste a token created on the selected instance and connect. The current-user API verifies its stable user ID before saving. Begin with read-only permissions; request creation requires the provider's repository write/API permission. Fine-grained PAT access is enforced by the API, so a valid account does not imply permission to every private repository or operation. PAT expiry is handled when the platform rejects it; PATs do not automatically become OAuth refresh tokens.

## Accounts, credentials and repository association

- Account uniqueness is provider + canonical HTTPS instance + stable server user ID. Multiple accounts on one instance and multiple instances are supported.
- New OAuth/PAT accounts default to **Local Encrypted Vault**, using AES-256-GCM and independent per-account random keys saved in private files on this Mac. Keys and ciphertext are separate, but obtaining both permits decryption. No OAuth Keychain calls or extra password are needed. See [credential storage and migration](credential-storage.md).
- **macOS Keychain** remains selectable. Existing v1 accounts retain **`GitPier.hosting.oauth`**, separately from **`GitPier.credentials`**. Startup reads metadata only; local credentials restore on demand and Keychain accounts use **Verify Connection** after restart. Normal macOS authorization and ad-hoc update prompts remain possible; ACLs are never loosened.
- Code Hosting settings change the default for future accounts only. **Change Storage Method** confirms an individual migration. Reauthorization into the destination is recommended; it avoids reading old Keychain tokens. Using memory or explicitly reading the source is also available. Destination writes precede the metadata commit; failed/cancelled migration preserves the source. Previous copies are cleaned only with explicit permission.
- OAuth refreshes are single-flight through the complete pair save, with a reused local key and new random nonce. PATs never refresh. Persistence failure keeps the new pair in memory and reports session-only status; restart may need reauthorization, since the old refresh token may be invalid.
- Repository → More → Pull / Merge Requests → Repository Binding selects the account, Remote and provider repository. Verify suggestions, especially SSH ports and forks. This never edits a Git remote/upstream, copies a Git token or runs Fetch/Push. Worktrees may select the same hosting repository while retaining their local branch state.
- Remote review diffs are read-only; binary, oversized, quoted/unsupported or omitted patches provide a browser fallback. Descriptions/comments render as selectable text, without active HTML or remote Markdown resources.
- Creation first checks permissions, source/target branches, pushed source SHA, open duplicates and unfinished local operations, then displays a confirmation. It checks again before POST and never auto-pushes. Unknown creation results must be queried before another attempt. Gitea's portable create API has no draft flag, so GitPier omits that control there.
- Disconnect removes local hosting credentials and bindings. Revoke the grant on the provider to invalidate it remotely. API data is memory-only and account-partitioned; denied/revoked credentials invalidate related caches.

## Validation boundary

Automated tests use synthetic tokens, injected provider responses and real local loopback sockets/isolated Keychain items. They do not establish that any public OAuth application was registered or any real user approved a login. Real GitHub.com Device Flow and GitLab.com PKCE, restart/unlock and public PR/MR/CI reads passed on 2026-10-17, as recorded in the development guide. Self-hosted GitLab/Gitea end-to-end login, private data, write scopes, fork creation, actual expiry/refresh and ad-hoc upgrade ACLs require separate instance and user acceptance. No such production credentials are included in source. Current evidence and commands are recorded in the [development guide](development.md).

Provider references: [GitHub authorization](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps), [GitLab PKCE](https://docs.gitlab.com/api/oauth2/), [Gitea public clients](https://docs.gitea.com/development/oauth2-provider/), [Gitea API schema](https://docs.gitea.com/api/1.24/).

## 简体中文配置清单

GitPier 的 OAuth 完全在 Mac 上执行，不需要 Client Secret、自建后端、账号服务器或公网回调服务。普通用户使用维护者统一注册的 GitHub.com / GitLab.com 公共 Client ID，无需自行注册。已内置维护者提供的 GitHub.com 与 GitLab.com 公共 ID，可直接开始 OAuth。缺失 ID 时仍禁用 OAuth 并说明原因，保留 PAT 入口。

维护者需注册 GitHub OAuth App **GitPier**，Homepage 填写项目主页 `https://github.com/Heisenberg2024/gitpier`，表单 Callback 填写 `http://127.0.0.1/oauth/github/callback` 并关闭通配匹配，然后启用 Device Flow（设备流程不使用此回调，也不启动 GitHub 回调监听）。将真实公共 Client ID 填入 `HostingOAuthConfiguration.json` 的 `githubClientID`。点击授权连接后会自动打开 GitHub 官方验证页；验证码具有有效期，需要在页面输入并批准，可用“打开 GitHub”重新打开。默认 `read:user`；公共协作的 `public_repo` 和私有协作的 `repo` 都包含写权限，尤其 `repo` 权限广泛，不是只读。升级由用户主动选择并重新授权。

GitLab 使用默认浏览器普通标签，可复用已有登录；采用 State + PKCE 校验应用回调，不使用 ASWebAuthenticationSession。GitLab.com 需注册 Public / Non-Confidential 应用，精确回调 **`gitpier://oauth/gitlab`**，允许初始 `read_user read_api`；创建 MR 需要用户明确授权较宽的 `api`。将 Application ID 填入 `gitlabClientID`，不要复制 Secret。2026-10-17 已完成正式公共应用的真实浏览器返回、重启解锁和公开 MR/CI 读取，详见开发验证说明。

自建 GitLab/Gitea 必须在对应实例注册公共应用，并在连接界面填写 HTTPS 实例地址、Client ID 和显示的回调配置。同实例用户可以复用 ID，不同实例不能混用。GitLab 默认由普通浏览器打开，复用窗口/标签与登录状态，通过应用已注册的 URL Scheme 回调；不再启动系统认证专用窗口或其网站登录确认。浏览器回跳时仍可能要求确认打开 GitPier，也可使用实例接受并已注册的固定端口回环地址。Gitea 注册 **`http://127.0.0.1/oauth/gitea/callback`**，运行时使用动态端口；仅绑定本机，校验 State、路径和会话，结束/取消即关闭。Gitea OAuth 限 v1.23+ 已识别细粒度权限，旧版或不兼容实例使用 PAT，不降级为宽 OAuth 权限。自签证书遵循 macOS 系统信任，不能关闭验证。

新 OAuth/PAT 账号默认使用本地加密凭证库：CryptoKit AES-256-GCM、各账号独立256位随机密钥与密文分文件保存在本机，重启后按需自动恢复，不访问 OAuth 钥匙串，无额外密码。若密钥和密文同时泄露，Token 可以被恢复；这不具备系统 Keychain 的隔离能力。可按账号选择系统钥匙串；旧无模式字段账号继续使用 **GitPier.hosting.oauth**，重启后明确点击“验证连接”，遵循 macOS 授权，不放宽 ACL。两种模式均不触碰 **GitPier.credentials**、Git/SSH 配置或凭证助手。

全局默认仅影响未来新账号。逐账号“更换存储方式”需要确认，可重新授权、使用内存 Token，或明确允许读取旧凭证。先记录迁移意图并保存目标，元数据原子切换后才使用新模式；失败保留原存储，旧副本由用户主动清理，可暂缓需要系统授权的 Keychain 删除。OAuth 按需刷新、并发合并、整对保存；失败保留新内存会话并提示重启可能需重新授权，不能继续假定旧 Refresh Token 有效。PAT 不具有 OAuth 刷新能力。详见[凭证存储与迁移](credential-storage.md)。

仓库关联入口位于 More → 拉取 / 合并请求，不自动 Fetch/Push 或改动 Remote/Upstream。PR/MR、CI、提交、文件和审查评论只读展示；远端 Diff 不提供暂存、应用补丁或丢弃操作。创建请求必须先检查与确认，超时结果未知时先查询，保留输入。断开只删除本地托管凭证和关联；平台授权撤销需前往平台设置。

模拟测试和本机夹具通过不代表真实 OAuth 登录通过。GitHub.com / GitLab.com 正式公共 ID 已配置，2026-10-17 真实登录、重启恢复及公开 PR/MR/CI 读取通过。自建实例、真实到期轮换、私有权限、写入与 Fork、重新授权及断开仍需分别验收。


Ordinary-browser window reuse follows the selected browser and its user preferences. GitPier does not request Accessibility/Automation permission, resize another application's windows, change browser preferences or replace the system default URL handler. macOS must route `gitpier://` to the running GitPier installation; multiple installed development copies can receive callbacks in the wrong copy. Unsolicited, late or mismatching callbacks do not start login, read Keychain or exchange codes.
