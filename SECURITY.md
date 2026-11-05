# Security & privacy

## Reporting a concern

Do not post credentials, private keys, private repository contents, or unredacted logs in public issues. Use GitHub's private vulnerability reporting if it is available on the [repository security page](https://github.com/Heisenberg2024/gitpier/security). Otherwise, request a private contact without including the sensitive details. No dedicated security contact is currently documented.

For an exposed credential, revoke or rotate it with its provider. Deleting a file or adding an ignore rule does not remove prior commits, tags, releases, forks, or downloaded copies.

## Local Git and executable code

GitPier invokes installed Git with argument arrays and literal pathspecs. Reviewed writes recheck repository state and preserve external Index content and partial staging. Hooks, commit signing, TLS verification, and SSH host-key checks remain enabled. Destructive operations ask for confirmation; tests of those operations belong in temporary repositories.

GitPier is not a sandbox for untrusted repositories. Git hooks, credential helpers, configured filters, shells, external editors, and optional agents can execute code with your user permissions. Review a repository and its configuration before running tools in it. Terminal commands are your commands; hiding a terminal keeps its jobs running, and closing its session stops the shell and attached jobs.

An interrupted write can have taken effect even when the client reports cancellation or failure. Commit & Push preserves a known local commit separately from Push outcome. When completion is unproven, inspect History/Reflog or explicitly verify the original remote reference before retrying. Cancellation is not rollback, and GitPier does not automatically replay an uncertain write.

## Git network authentication

Repository Git transport and hosting API accounts are separate. Connecting GitHub/GitLab/Gitea through OAuth does not configure Fetch/Push. Git transport can use existing Git credential helpers and SSH configuration, a selected GitPier-managed HTTPS token, or an SSH profile.

Managed HTTPS tokens are stored in macOS Keychain, isolated by their configured host/account/protocol context, and are refused for plain HTTP. Keychain authorization can be requested again after an ad-hoc app upgrade. GitPier does not broaden Keychain ACLs or copy credentials merely to avoid authorization.

Automatic remote checks are optional and off by default. They reuse the effective native Git authentication configuration and restrict helper calls to read-only lookup; background Git does not invoke helper store/erase. Terminal prompts are disabled, but configured Askpass/native helper programs retain their own authorization behavior, so arbitrary helpers cannot be guaranteed to suppress all UI. A session-only password, expired token, or SSH-agent socket available only in another terminal is not automatically transferable to the app.

Optional **Prepare SSH Authentication** is an explicit action. Its private agent uses a one-hour identity lifetime, is bound to the prepared repository/authentication identity, and stops on normal app exit. It does not replace unrelated inherited agents. GitPier does not automatically edit global Git/SSH configuration or shell startup files.

Existing HTTP remotes remain HTTP and transmit data and credentials without transport encryption. Settings warn about that boundary. Use trusted HTTPS or SSH endpoints; do not disable certificate or host-key verification to resolve authentication errors.

## Credential storage

Hosting OAuth/PAT accounts share one token lifecycle with two storage choices. New accounts default to **Local Encrypted Vault**; existing Keychain accounts keep their mode. The default setting affects future accounts only.

- **Local Encrypted Vault:** CryptoKit AES-256-GCM with independent random account keys and private local files. The default location is `~/Library/Application Support/GitPier/HostingCredentials/`; custom workspaces keep it beside their workspace file. Directory/file permissions are 0700/0600, writes validate ownership and reject unsafe links, and encrypted generations are switched atomically. Missing keys, damaged data, and mismatched authentication tags fail closed.
- **macOS Keychain:** OS-controlled credential access. After restart, use Verify Connection for the account; macOS may request authorization. Ad-hoc updates can cause another prompt.

Vault keys and ciphertext are both stored on the Mac. Anyone who obtains both can decrypt the tokens; there is no master password, hardware isolation, or protection from malware with full access to the user's files. FileVault adds protection while the disk is locked. Backups containing both need equivalent protection. Ordinary deletion from an SSD does not guarantee physical erasure. Local Vault avoids OAuth Keychain reads, but Git transport helpers and other Keychain-backed features can still access Keychain.

OAuth refresh is shared per account and persists the complete rotated token pair. PATs do not refresh. If saving fails, a token can remain usable only for the current session; restarting may require reauthorization because the previous refresh token may already be invalid. GitPier records a nonsecret recovery marker when possible rather than knowingly restoring stale credentials.

Changing storage requires per-account confirmation. Reauthorization can avoid reading the previous Keychain credential. Migration saves the destination before switching metadata and preserves the source on failure; previous-copy cleanup is separate and may be postponed. Disconnect cancels account work and removes active bindings before cleanup. Copies that cannot be deleted remain disconnected, visible for explicit cleanup retry, and cannot restore that account. If disconnect metadata itself cannot be saved, restart durability cannot be guaranteed. Disconnect does not revoke the provider grant: revoke it separately in the platform's authorization settings.

## OAuth, permissions, and remote collaboration

OAuth runs locally through a browser, using public client metadata, GitHub Device Flow or S256 PKCE. GitPier has no token-relay backend and embeds no client secret. Hosting instances use HTTPS with system trust; there is no self-signed-certificate bypass. Loopback callbacks bind to `127.0.0.1` and validate session/state. Public Client IDs and the Sparkle public verification key are not secrets.

Read permissions do not imply write access. GitHub repository scopes and GitLab `api` can be broad; Gitea repository writes and issue comments use distinct scope categories. Permission expansion requires explicit reauthorization or PAT replacement. See [hosting setup and provider limits](docs/development.md#hosting-setup).

Remote reviews bind to exact target identities and commit/patch coordinates, with revision/permission checks before supported writes. The server can still change concurrently with a request. GitLab Discussions and approvals are separate operations, and some Gitea operations require browser fallbacks. Unpublished review bodies stay in memory, are not published on close, and can be lost on quit; disconnect warns about affected drafts.

Before confirmed review writes, a private local journal stores minimal intent and receipt metadata in `workspace.review-operations/` beside the workspace file. It contains account/repository/request identities, revisions, operation states, timestamps, and opaque receipt/reviewer IDs. It excludes tokens, keys, headers, comment bodies, body hashes, source paths, Diff, and code. This metadata can still reveal activity. File permissions do not provide cryptographic tamper resistance against the same user.

After a crash or an uncertain response, Unknown remains visible across restart. Reopening does not resend. Inspect available receipts read-only, check the platform, and explicitly acknowledge the result before another preview. Journal decode/permission failures preserve the files and block review writes. Local disconnect/migration journals are separate from review-operation recovery.

## Local metadata, diagnostics, and optional tools

Workspace configuration, repository paths, task descriptions, account metadata, and recovery records can reveal private context. Task metadata excludes agent prompts/transcripts and credential payloads; GitPier does not provide isolation from the user's local tools. Starting or resuming the separately installed Codex CLI requires confirmation. Its authentication, network traffic, model use, and service costs belong to that external tool and the user's plan. Codex can read files and execute commands with user permissions; GitPier does not independently audit or approve each command.

The navigation CLI opens a chosen local app/repository/page. It does not accept credentials or arbitrary Git/shell commands and cannot start Codex. The `gitpier://` scheme cannot authenticate its sender; adding an unknown repository through an external URL requires confirmation and identity revalidation. Install/uninstall verifies ownership and the launcher receipt rather than overwriting unknown files. See the [CLI guide](docs/cli.md).

Operations Center keeps bounded session-memory summaries and redacted diagnostics, with user-facing failure detail capped at 4,096 characters and 16 KiB UTF-8. Additional interrupted-commit/recovery-Push capture is transient and bounded to 64 KiB per stdout/stderr stream before presentation redaction. Known URL credentials, common authentication headers, and named secret fields are redacted. Unknown secret formats, private code, remotes, paths, and repository context can still remain. Review logs and screenshots manually before sharing them; redaction is not a guarantee that every sensitive value is detected.

## Updates and distribution

Sparkle fetches the stable feed over GitHub HTTPS and verifies Ed25519 signatures for update metadata/embedded release notes and the final DMG before extraction. Missing/invalid signatures, altered archives, incompatible versions, or invalid bundles must not install. Signed-feed failures do not fall back to unsigned updates. SHA-256 sidecars check integrity; they do not authenticate the publisher on their own.

New installations enable automatic update checks; existing opt-outs are preserved. Downloads, installation, and restart require confirmation. Update checks do not upload repository data or a system profile. Active Git work prevents termination; terminal/conflict-draft warnings still apply. Failed checks, downloads, or cancellation keep the old app available. Read-only mounts and App Translocation can require moving to Applications or a manual DMG upgrade.

Current releases are **ad-hoc signed, without Apple Developer ID signing or notarization**. Update-channel signatures do not establish Gatekeeper trust. Follow [Apple's per-app opening guidance](https://support.apple.com/en-us/102445) only for a source you trust; never disable Gatekeeper, strip quarantine, or bypass update verification. A malware/damaged-app warning needs investigation.

Production update private keys stay in the maintainer's Keychain and require protected offline backups. No production key belongs in source, application resources, command arguments, or public CI. Without Developer ID signing, loss of the update identity can prevent a trusted automatic rotation/recovery and require a manually verified reinstall. See [packaging boundaries](docs/development.md#packaging-and-updates).

Automated tests, synthetic authentication, and structural bundle checks do not establish every hardware, OS, private-server, accessibility, notification, or production self-update path. Report the specific environment and checks actually exercised.
