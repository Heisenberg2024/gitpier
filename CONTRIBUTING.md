# Contributing to GitPier

GitPier is a native Swift / SwiftUI / AppKit macOS application. Start with [development](docs/development.md) and [architecture](docs/architecture.md). GitPier is licensed under the [MIT License](LICENSE). Third-party components retain their own licenses; see [third-party notices](THIRD_PARTY_NOTICES.md).

## Reporting issues

Include the GitPier version, macOS version, architecture, Git version, expected behavior, and steps to reproduce. Prefer a disposable repository with fictional files. Remove usernames, local paths, private remotes, tokens, and private code from logs and screenshots. For credential exposures, follow [SECURITY.md](SECURITY.md).

## Pull requests

Keep changes focused and describe the user-visible result and checks actually run. Maintain English and Simplified Chinese strings and READMEs together. Preserve the native application architecture and existing repository state.

Git subprocesses belong in `GitPierCore/GitService.swift`. Use argument arrays and literal pathspecs. Writes must share the canonical working-tree actor and its explicit queue. Preserve external Index contents, partial staging, hooks, signing, TLS, and SSH host-key verification. Destructive-operation tests must use temporary repositories.

Run `Scripts/test.sh` for Core changes and `Scripts/build-app.sh` for application or resource changes. Native UI or PTY changes also need `Scripts/ui-acceptance.sh` in a logged-in macOS session. State any untested remote-authentication, platform, or distribution boundary. Do not commit generated reports, local workspace data, or private configuration.

For distribution changes, also run `python3 Scripts/test-release-tools.py` and `Scripts/test-dmg-structure.sh` after building. Finder layout and an actual isolated Sparkle update require local GUI acceptance. Preserve the production bundle ID and increment the single release configuration build number; never commit production/test private keys or enable an unsigned release feed.
