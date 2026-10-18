# Developer ID and notarization plan

Status: planning only for v1.7.0–v2.0. Current distribution remains ad-hoc signed. No production signing identity, entitlement, certificate, private key or notarization submission is changed by this work.

Three checks have different purposes: Developer ID signs executable identity; Apple notarization evaluates a submitted distribution and issues a ticket; Sparkle EdDSA authenticates the update archive and signed feed. None replaces the other two. [Apple Developer ID](https://developer.apple.com/developer-id/), [Sparkle documentation](https://sparkle-project.org/documentation/).

The maintainer needs a Developer ID Application certificate/private key in an authorized build environment and separately authorized notarytool credentials. Do not export these into this repository. Hardened Runtime and secure timestamping are required for distribution signing; audit entitlements against actual PTY, System Git child processes, OAuth callbacks, networking and Sparkle behavior before enabling them. Avoid adding broad runtime exceptions without an observed requirement. [Apple distribution signing](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/), [notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

Implementation sequence after explicit maintainer authorization:

1. Freeze exact Universal application/CLI inputs. Record identities and current entitlements for every nested Sparkle Mach-O/helper/XPC bundle, launcher and main executable.
2. Sign from the inside out with the chosen certificate, consistent team identity, timestamp and tested runtime options. The CLI is nested executable code in `Contents/Helpers`; preserve Sparkle framework links and required XPC entitlements. Sign the outer app last.
3. Verify both architectures and the complete signature chain, with no build-directory dynamic-library paths. Run native UI, Git HTTPS/SSH, helper/Keychain, PTY, OAuth, Review recovery, CLI and multiwindow regressions under the hardened candidate.
4. Create a new isolated DMG using the existing Finder layout. Submit only the approved immutable candidate using notarytool. Inspect the full result/log; a submission receipt alone is not acceptance.
5. Staple and validate the ticket, verify Gatekeeper assessment and offline/quarantined first launch on clean machines. Recheck the mounted app's exact contents and CLI installation/launch.
6. Sign the final immutable DMG/feed with the existing production Sparkle EdDSA key only in the authorized release stage. Stapling/packaging changes precede this signature. Recheck v1.6.1→v1.7.0 installation, app replacement/restart, Vault/Keychain compatibility and update trust continuity.

Separate evidence is required for Apple Silicon/Intel, macOS 14/current macOS, offline ticket behavior, actual system credential denial and multi-copy application selection. Without certificate/submission authorization, retain this checklist and report those distribution gates as unverified. [Apple notarization troubleshooting](https://developer.apple.com/documentation/security/resolving-common-notarization-issues).

## 简体中文

本轮只完成方案，不使用生产证书/私钥，不提交公证，不改变正式安装。Developer ID、Apple公证与Sparkle EdDSA分别负责可执行身份、苹果分发检查和更新附件/Feed真实性，不能互相替代。获维护者明确授权后，先冻结Universal输入并审计每层Sparkle/CLI签名与Entitlements，验证Hardened Runtime所需最小能力，再由内到外签名和执行原生回归；新建DMG、提交并核实公证结果、Staple/Gatekeeper/离线隔离启动通过后，才能对最终不可变DMG/Feed做生产EdDSA签署。当前仍须如实标记ad-hoc及未验证的硬件、系统和真实权限边界。
