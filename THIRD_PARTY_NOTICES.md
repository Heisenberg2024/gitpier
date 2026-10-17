# Third-party notices

GitPier is licensed under the [MIT License](LICENSE). Its dependencies retain their own copyright notices and licenses.

| Component | Version | Use | License | Full text |
| --- | --- | --- | --- | --- |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm/tree/5d14406844143538cd8f8851d2d8a67c1fe443e5) | 1.20.0 | Linked native PTY terminal emulator | MIT | [License](Resources/Licenses/SwiftTerm-LICENSE.txt) |
| [Sparkle](https://github.com/sparkle-project/Sparkle/tree/2.10.0) | 2.10.0 | Embedded framework, updater helpers and XPC services | MIT plus bundled external notices | [License and external notices](Resources/Licenses/Sparkle-LICENSE.txt) |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser/tree/6a52f3251125d74daf04fcbd5e6f08a75d074382) | 1.8.2 | Resolved dependency for SwiftTerm's `termcast` tool; not linked into GitPier | Apache 2.0 with the Swift Runtime Library Exception | [License and exception](Resources/Licenses/swift-argument-parser-LICENSE.txt) |

Exact revisions are recorded in `Package.resolved`. The full license texts above are preserved from those revisions. SwiftTerm's license includes notices for Miguel de Icaza, the xterm.js authors, SourceLair, and Christopher Jeffrey. swift-argument-parser identifies Apple Inc. and the Swift project authors in its source notices.

`Scripts/build-app.sh` includes this notice, GitPier's LICENSE, and the dependency license texts in the application bundle. Retain the applicable copyright notices and license terms when redistributing the application. GitPier's MIT License does not replace these dependency licenses.


## Hosting platform marks

The hosting connection cards use unmodified official marks to identify integrations. These marks remain the property of their respective owners and are not covered by GitPier's MIT license; their use does not imply endorsement.

- GitHub Invertocat (black/white PDF): [official logo toolkit](https://brand.github.com/foundations/logo), [source archive](https://brand.github.com/GitHub_Logos.zip). GitHub and Invertocat are trademarks of GitHub, Inc.
- GitLab Tanuki (full-color SVG): [official asset](https://gitlab.com/gitlab-org/gitlab-svgs/-/blob/main/illustrations/gitlab_logo.svg), [brand guidelines](https://design.gitlab.com/brand-logo/core-logo/). GitLab and its logo are trademarks of GitLab Inc.
- Gitea (green SVG): [official source asset](https://github.com/go-gitea/gitea/blob/main/assets/logo.svg), [official website](https://about.gitea.com/). Gitea and its logo belong to the Gitea project and its respective trademark owners.
