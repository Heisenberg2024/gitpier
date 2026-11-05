# Contributing to GitPier

GitPier is a native Swift / SwiftUI / AppKit macOS application. Read the [development guide](docs/development.md) and [architecture overview](docs/architecture.md) before changing behavior. The project uses the [MIT License](LICENSE); dependencies and assets retain their [own terms](THIRD_PARTY_NOTICES.md).

## Report an issue

Use [GitHub Issues](https://github.com/Heisenberg2024/gitpier/issues). Include the GitPier/macOS/Git versions, architecture, expected result, and reproducible steps, preferably with fictional files in a disposable repository. Remove private code, usernames, local paths, private remotes, and credentials from logs and captures. Follow [SECURITY.md](SECURITY.md#reporting-a-concern) for sensitive reports.

## Submit a pull request

Keep the scope focused and explain the problem, resulting behavior, and validation actually run. Preserve existing user work, repository state, native application architecture, and English/Simplified Chinese UI and README parity. Discuss major workflow or dependency changes before implementing them.

Git commands belong in `GitPierCore/GitService.swift`, use argument arrays and literal pathspecs, and share the canonical working-tree actor and explicit write queue. Preserve external Index content, partial staging, hooks, signing, TLS, and SSH host-key verification. Destructive tests must use temporary repositories; never change user global Git, SSH, or shell configuration.

Use the existing appearance and shared overlay scrollbars for application-owned scroll regions, both axes, nested editors, and new presentation roots. Keep About as the rightmost Settings tab and preserve selection IDs. See [development conventions](docs/development.md#documentation-and-assets).

## Validate the affected path

- Documentation/media: review the rendered result, relative/external links, bilingual consistency, privacy, and applicable licenses.
- Core logic: run `Scripts/test.sh` with appropriate regression coverage and boundary scenarios.
- Application/resources: run `Scripts/build-app.sh`; native UI or PTY changes also need `Scripts/ui-acceptance.sh` with isolated state and temporary repositories.
- CI/distribution: run the relevant policy/cache suites and `python3 Scripts/test-release-tools.py`; packaging changes also need `Scripts/test-dmg-structure.sh` and any affected Finder/update acceptance.

Describe skipped checks and untested hardware, remote authentication, accessibility, or distribution paths. Mocks and structural checks do not establish real-service or native interaction acceptance. Do not weaken assertions or bypass safety checks to turn a failure green.

## Documentation and public files

Keep product capability descriptions based on implemented behavior and update both READMEs together. Release history belongs in `CHANGELOG.md` and GitHub Releases. Public `docs` contains durable guides; internal plans, logs, acceptance evidence, temporary screenshots, authoring projects, private configuration, and build products stay local. Ignored directories need separate backups.

Retain legal notices, source manifests, and required resource files. Do not include credentials or production/test signing keys. Changes to release identity, signing, update trust, or publication need separate maintainer approval; a pull request is not authorization to publish.
