# Third-party notices

GitPier is licensed under the [MIT License](LICENSE). Its dependencies retain their own copyright notices and licenses.

| Component | Version | Use | License | Full text |
| --- | --- | --- | --- | --- |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm/tree/5d14406844143538cd8f8851d2d8a67c1fe443e5) | 1.20.0 | Linked native PTY terminal emulator | MIT | [License](Resources/Licenses/SwiftTerm-LICENSE.txt) |
| [Sparkle](https://github.com/sparkle-project/Sparkle/tree/2.10.0) | 2.10.0 | Embedded framework, updater helpers and XPC services | MIT plus bundled external notices | [License and external notices](Resources/Licenses/Sparkle-LICENSE.txt) |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser/tree/6a52f3251125d74daf04fcbd5e6f08a75d074382) | 1.8.2 | Resolved dependency for SwiftTerm's `termcast` tool; not linked into GitPier | Apache 2.0 with the Swift Runtime Library Exception | [License and exception](Resources/Licenses/swift-argument-parser-LICENSE.txt) |
| [Material Icon Theme](https://github.com/material-extensions/vscode-material-icon-theme/tree/f368264282ef14ee7feb012fd54e825181eff9c3) | Revision `f368264282ef14ee7feb012fd54e825181eff9c3` | Bundled file type SVG icons | MIT | [License](Resources/Licenses/Material-Icon-Theme-LICENSE.txt) |

Exact revisions are recorded in `Package.resolved`. The full license texts above are preserved from those revisions. SwiftTerm's license includes notices for Miguel de Icaza, the xterm.js authors, SourceLair, and Christopher Jeffrey. swift-argument-parser identifies Apple Inc. and the Swift project authors in its source notices.

File icons are unmodified upstream SVGs. Their source paths, fixed revision and SHA-256 hashes are recorded in [the icon manifest](Sources/GitPier/Resources/FileIcons/filetype-icons-manifest.json). Material Icon Theme's MIT license covers these assets; language and product marks remain the property of their respective owners and do not imply endorsement.

`Scripts/build-app.sh` includes this notice, GitPier's LICENSE, and the dependency license texts in the application bundle. Retain the applicable copyright notices and license terms when redistributing the application. GitPier's MIT License does not replace these dependency licenses.


## Hosting platform marks

The hosting connection cards use unmodified official marks to identify integrations. These marks remain the property of their respective owners and are not covered by GitPier's MIT license; their use does not imply endorsement.

- GitHub Invertocat (black/white PDF): [official logo toolkit](https://brand.github.com/foundations/logo), [source archive](https://brand.github.com/GitHub_Logos.zip). GitHub and Invertocat are trademarks of GitHub, Inc.
- GitLab Tanuki (full-color SVG): [official asset](https://gitlab.com/gitlab-org/gitlab-svgs/-/blob/main/illustrations/gitlab_logo.svg), [brand guidelines](https://design.gitlab.com/brand-logo/core-logo/). GitLab and its logo are trademarks of GitLab Inc.
- Gitea (green SVG): [official source asset](https://github.com/go-gitea/gitea/blob/main/assets/logo.svg), [official website](https://about.gitea.com/). Gitea and its logo belong to the Gitea project and its respective trademark owners.

## README demonstration media

The README illustration uses fictional repositories and code, GitPier's own app artwork, and the bundled Material Icon Theme Swift icon described above. It is authored with Stageshow and uses Lucide 0.468.0 glyphs to approximate native system controls. Authoring tools and their JavaScript runtime are not application dependencies. The following notices apply to that demonstration work; no other product-study artwork or third-party fonts are used.

### Stageshow

MIT License

Copyright (c) 2026 Benji Taylor

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

### Lucide

ISC License

Copyright (c) for portions of Lucide are held by Cole Bemis 2013-2022 as part of Feather (MIT). All other copyright (c) for Lucide are held by Lucide Contributors 2022.

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
