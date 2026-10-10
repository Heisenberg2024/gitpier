# Security & privacy

GitPier runs Git, SSH, and terminal commands locally with the current user's privileges. Repositories, hooks, shell startup files, credential helpers, and external tools should be trusted before opening or running them. GitPier is distributed outside the macOS App Sandbox.

Managed HTTPS tokens are stored in macOS Keychain. Local workspace configuration contains repository paths, drafts, preferences, and credential-profile metadata, including SSH identity paths. Terminal output is not logged to disk by GitPier. Remote operations use the configured Git remotes; there is no GitPier upload or analytics service.

## Reporting a concern

Never put tokens, private keys, private repository contents, or unredacted logs in a public issue. Once this repository is published, use GitHub's private vulnerability reporting if the owner has enabled it. If no private channel is available, request one without including sensitive details. No dedicated security contact or private reporting channel is configured yet.

If a credential has entered a public repository or log, revoke or rotate it first. Removing the working-tree file or adding an ignore rule does not remove it from existing Git history.
