# Security & privacy

GitPier runs Git, SSH, and terminal commands locally with the current user's privileges. Repositories, hooks, shell startup files, credential helpers, and external tools should be trusted before opening or running them. GitPier is distributed outside the macOS App Sandbox.

Managed HTTPS tokens are stored in macOS Keychain. Local workspace configuration contains repository paths, drafts, preferences, and credential-profile metadata, including SSH identity paths. Terminal output is not logged to disk by GitPier. Remote operations use the configured Git remotes; there is no GitPier upload or analytics service.

## Reporting a concern

Never put tokens, private keys, private repository contents, or unredacted logs in a public issue. Use GitHub's private vulnerability reporting if the owner has enabled it. If no private channel is available, request one without including sensitive details. No dedicated security contact or private reporting channel is configured yet.

If a credential has entered a public repository or log, revoke or rotate it first. Removing the working-tree file or adding an ignore rule does not remove it from existing Git history.

## Application updates (v1.1.0 development)

Sparkle 2 fetches the stable feed over GitHub HTTPS and authenticates both feed/embedded release notes and final DMG using Ed25519 signatures. Archive verification happens before extraction. Signed-feed failures never expire into a degraded fallback mode. SHA256 is a manual integrity check, not a substitute for source authentication. Missing production keys disable updates; missing/invalid signatures, altered archives, incompatible versions or broken bundles must not be installed. Sparkle owns replacement and rollback behavior; GitPier does not run an ad-hoc shell installer or request root access.

Production private keys remain in the owner-controlled login Keychain; offline encrypted backups are essential. No production key enters public CI, source, application resources or command arguments. Without Developer ID signing, losing the EdDSA key can prevent trusted automatic recovery or rotation and require a manually verified reinstall. See [development](docs/development.md) for backup and recovery commands.

Updates do not send repository data or a system profile. Automatic checks default off; download/install/restart require confirmation. Git work prevents termination, and existing conflict-draft/terminal warnings remain in force. Failed checks/downloads or cancellation leave the workspace and running old app available. Read-only mounts and App Translocation require installation in a writable trusted location or a manual DMG upgrade.

Current builds are ad-hoc signed and **not Apple Developer ID signed or notarized**. EdDSA update authentication does not change Gatekeeper trust. Never disable Gatekeeper, strip quarantine or bypass Sparkle verification to make an update succeed. v1.0.3 requires a one-time manual upgrade because it contains no updater.
