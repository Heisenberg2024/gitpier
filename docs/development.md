# Development

## v1.8.0 development

Task Workspaces and optional local Codex integration are under development in build 30. Incremental hardening covers partial-creation recovery, explicit CLI login checks/environment inheritance and budgeted concurrent review. Creation fault tests use real temporary Git repositories plus controlled command/filesystem failures; authentication tests use synthetic executables and never real credential files. Record real CLI/account results separately, with explicit authorization and no credential copies. Use the [task guide](task-workspaces.md) for exact storage, ownership, process and review boundaries. Existing v1.7.0 evidence below is historical, not validation of this new source. Full Core/Universal/DMG/update validation and independent review must be recorded for the final inputs before release; no publication is authorized by a local build.

```sh
Scripts/test.sh --filter 'TaskWorkspaceTests|LocalAgentTests|OperationCenterTests'
GITPIER_UI_ACCEPTANCE_SCOPE=task-workspaces Scripts/ui-acceptance.sh .cache/v180/native
```

The new native scope uses temporary repositories and a local executable fixture, not a real Codex conversation. It verifies PTY cwd/arguments, session/page lifetime, partial Index preservation, archive/recovery, process cleanup and language/theme compositor captures. Keep real CLI detection, unauthenticated CLI startup, authenticated model execution, UI interaction and fixture evidence separate.

For an explicitly authorized existing-login test, the isolated `Scripts/workspace-acceptance.sh task-workspaces` runner additionally accepts `GITPIER_TASK_ACCEPTANCE_HOLD=1` and `GITPIER_TASK_ACCEPTANCE_REAL_CODEX` set to the real absolute executable path. It launches the normal SwiftTerm pipeline without copying credentials. Inspect the temporary window, then create `finish-gui` in the selected output directory. `GITPIER_TASK_ACCEPTANCE_FAIL_AFTER_REAL_START=1` injects a failure after spawn; expect a nonzero test exit and a verified cleanup record. Unknown cleanup retains the host for inspection and an explicit `retry-real-cleanup` marker. Never accept saved folder trust if the test scope forbids Codex configuration changes.

简体中文：v1.8.0（30）仍在开发，下方v1.7发布证据不代表新源码验收；最终输入需单独完成Core、Universal/DMG/升级及独立审核。专项原生验收使用临时仓库和可执行夹具，不是真实Codex对话；真实版本检测、未认证启动、认证模型执行、实际UI操作和夹具证据必须分别记录。

明确授权复用登录后，隔离 runner 可设置上述 HOLD 与真实可执行路径变量，复用正常 SwiftTerm 管线且不复制凭证；验收后在输出目录创建 finish-gui。启动后故障注入应以非零退出并留下已核验清理记录；无法核验则保留宿主，等显式 retry-real-cleanup。禁止改 Codex 配置的测试不得接受保存目录信任。

## v1.7.0 publication — 2026-10-19

[GitPier v1.7.0 (29)](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.7.0) was published as **Latest** at **2026-10-19 22:41:45 Asia/Shanghai**, release `417398240`, from `dfcd0f65e1df889985a4e9a385db1d78d814032c`. The owner approved the exact bilingual notes. [Main CI 39266290595](https://github.com/Heisenberg2024/gitpier/actions/runs/39266290595) passed full macOS validation using Swift 6.1.2: **932 Core tests**, zero failures, **554.547 s**, all ten release gates, build, temporary DMG structure and signature/permission-preserving archive/upload. [Tag CI 39270296068](https://github.com/Heisenberg2024/gitpier/actions/runs/39270296068) explicitly reused that exact full run. The CI repair made nested closure captures explicit and split a type-check-heavy string expression without changing behavior.

Independent read-only review passed on the final source after fixing a CLI cleanup race. The tool and receipt enter exclusive 0700 custody before deletion, are revalidated there, and restore without overwriting concurrent replacements. All **21 installer tests** and the complete local **932 tests** passed (241.238 s). The final Universal app and helper contain arm64/x86_64, pass deep signatures and bundle checks, and retain all 290 frozen tracked inputs. Final native assistant/workflow/workflow170 acceptance passed **87 / 37 / 41** records.

The final DMG is **26,471,828 bytes**, SHA256 `c1535a9975bfadbdf7676cf13a328e2e13753e2f1124b27325b27f1b320655c3`; its 115 application files/links and modes match the built bundle. Finder inspection confirmed the application/Applications icons, arrow and bilingual instructions. The existing production Keychain Ed25519 key signed both DMG and appcast; CryptoKit and independent Node verification passed, including equal-length tamper rejection. Three Draft assets were downloaded by ID before publication; anonymous public downloads and the canonical Latest Feed then matched exact bytes, hashes, signatures, notes, version/build and minimum OS. All 16 historical releases, 44 remote assets, 16 tags and 32 local historical assets remained unchanged.

An isolated actual **1.6.1 (28) → 1.7.0 (29)** Sparkle update replaced and automatically relaunched the app. The new process passed nine recovery checks, matched the prepared binary, and passed an independent workspace/credential-metadata/local-Vault/Review-journal/partial-Index probe. The test used a unique Bundle ID, loopback Feed and disposable key; the actual installed app, production credentials and URL handler were not replaced. Owned runtime, test preferences, private seed, mounts and server were cleaned. Local evidence: `.cache/releases/v1.7.0/prepare-20261019-221109/` and `.cache/v170-ci-release/`.

Universal compilation and isolated update acceptance do not establish physical Intel/macOS 14 runtime acceptance, full VoiceOver, actual OS Keychain refusal, new real-provider Review coverage or a production-identity self-update. Developer ID/notarization remains a separate plan. Existing unverified service/hardware boundaries remain open.

简体中文：v1.7.0（29）已从 `dfcd0f6` 正式发布为 Latest，发布说明经所有者确认。同源码 Swift 6.1.2 完整 CI 通过932项Core与10项发布门控，标签明确复用该运行；独立复核发现并完成CLI并发替换清理修复后通过审核。最终本地932测试、Universal、87/37/41原生断言、签名附件草稿/公开回读及隔离28→29实际Sparkle替换重启均通过。部分暂存、恢复身份和生产更新身份保持，真实安装未替换；Intel/macOS14真机、完整VoiceOver、真实Keychain拒绝、生产身份自升级等仍不宣称已验收。

See the [CLI guide](cli.md), [Operations Center guide](operations-center.md), [contextual workflow](context-workflow.md) and [Developer ID/notarization plan](developer-id-notarization.md). Internal CLI product name `GitPierCommandLine` avoids collisions with `GitPier` on case-insensitive filesystems; packaging renames it to the signed `Contents/Helpers/gitpier`. Production version/build still have one source in ReleaseConfiguration.json.

```sh
Scripts/test.sh --filter 'ContextWorkflow|testContextWorkflow'
Scripts/test.sh --filter 'OperationCenterTests|NavigationRequestTests|CLIToolInstallationTests'
Scripts/test.sh
Scripts/build-app.sh
UNIVERSAL=1 Scripts/build-app.sh
Scripts/workspace-acceptance.sh context-assistant .cache/ui-acceptance/context-assistant
Scripts/workspace-acceptance.sh context-workflow .cache/ui-acceptance/context-workflow
Scripts/workspace-acceptance.sh workflow170 .cache/ui-acceptance/workflow170
Scripts/workspace-acceptance.sh full .cache/ui-acceptance/workflow170-full
python3 Scripts/test-release-tools.py
```

Native routing acceptance uses a disposable app with no `CFBundleURLTypes`, fixture-only workspace metadata and a unique runtime Bundle ID under the existing `workspace-test.workflow170` namespace. Use a private `/private/tmp/GitPier-workflow170-*` workspace to avoid changing Documents privacy permissions. The production URL handler must remain unchanged. Do not install into the real user bin directory during fixtures; use `CLIToolInstallation(directory:)` with an owned temporary directory. Exact-source full Swift 6.1 CI and independent review remain required for releases; the v1.7.0 evidence above satisfies those gates.

简体中文：v1.7.0已正式发布，专项/完整Core、原生UI、CLI与Universal/DMG分别记录证据。CLI内部产物须避免与主程序仅大小写不同，正式命令仍为gitpier。夹具使用私有临时目录/独立身份，不更改生产回调或实际安装。Swift6.1同源码CI与独立复核保持发布门槛。

## v1.6.1 publication — 2026-10-18

[GitPier v1.6.1 (28)](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.6.1) was published as **Latest** at **2026-10-18 22:58:47 Asia/Shanghai**, release `416510671`, tag/source `74dc071187cfbf6e0b6f6a574eb94e155f140d07`. The owner approved the exact bilingual release notes and publication. [Main CI 39135432486](https://github.com/Heisenberg2024/gitpier/actions/runs/39135432486) passed full macOS validation with Swift 6.1.2: **855 Core tests**, zero failures, **486.628 s**, **10 release gates**, **1.184 s**, build, temporary DMG, signature/permission-preserving archive and upload. [Tag CI 39138220447](https://github.com/Heisenberg2024/gitpier/actions/runs/39138220447) passed by explicitly reusing that exact full run, attempt 1; it did not rerun the macOS suite.

The tested Universal DMG was reused without rebuilding: **21,139,037 bytes**, SHA256 `8dfc1677ed44431022295e6b83acf06c72d0ed22a1c3ac82ce50db7ee5d82c5f`. The existing production Keychain key signed the DMG and Feed; CryptoKit and independent Node Ed25519 verification plus equal-length tamper rejection passed. All three Draft assets were downloaded by ID and verified before publication. Anonymous downloads of the DMG, SHA256 file and appcast, and the canonical Latest Feed, returned HTTP 200 with exact hashes, signatures, version/build and approved notes. A read-only mount matched all **179** app entries, Finder's normal default layout passed, and an isolated mounted-app copy launched with About **1.6.1 (28)**. Production installation was not changed.

Preservation checks passed for **248** frozen inputs, **130** protected files, **121** historical local assets, **15** prior releases, **41** remote assets and **15** tags. The installed app, hosting/Vault data and default URL handler remain unchanged; task-owned apps/runtime/preferences/tamper files and both owned mounts were cleaned. The 17 verified live operations and one unresolved GitLab comment remain distinct; unavailable approval/reviewer cases are not passes. The actual isolated Sparkle update and 418 captures below belong to the earlier b2d90b7 build. See [full scope and release evidence](v1.6.1-validation.md). Evidence: `.cache/releases/v1.6.1/prepare-20261018-224113/`.

简体中文：v1.6.1（28）已于 **2026-10-18 22:58:47（Asia/Shanghai）**按已确认双语说明正式发布为Latest，Tag指向74dc071。main同提交Swift6.1.2完整CI通过855项Core与10项门控；Tag CI明确复用该完整记录，不冒充重新运行。原生产Keychain签DMG/Feed，Draft三附件按ID回读及公开匿名HTTP200、哈希、签名、正文与固定Latest Feed验证全部通过。179项包镜像、Finder默认布局、隔离About启动通过；248输入、130保护文件、121本地历史资产与15旧Release/41附件/15Tag保持，实际安装和配置未改。真实17项成功与1项未知及未覆盖账号/硬件/生产升级边界继续保留；任务临时资源已清理。发布记录仅在本地更新，尚未提交。

### Development checkpoints

The baseline `main` cce72c4 passed all 772 Core tests (zero failures/skips, 263.890 s) and 10 release-tool gates. The b2d90b7 candidate passed 852 Core tests, 10 release gates, 418 native captures, Universal/DMG checks and an actual isolated 27 → 28 Sparkle install/relaunch with seven application data checks. See [the validation report](v1.6.1-validation.md) for exact build provenance and authorization boundaries. Synthetic/native fixture success does not establish real hosted-service writes.

简体中文：基线772项Core与10项发布门控已通过；最终候选版852项Core、418张原生截图、Universal/DMG及真实隔离27→28升级和7项应用数据检查已通过，详见[完整记录](v1.6.1-validation.md)，Fixture不能替代真实平台写入许可或正式发布。


The authorized live continuation started from committed `b2d90b7`: 17 review operations verified, one native GitLab ordinary comment remains Unknown without replay, and missing-account cases remain unverified. A real Gitea form-encoding compatibility fix passed 11 callback and all 855 Core tests, rebuilt Universal/DMG and a new native recovery launch. The earlier Sparkle update and 418 captures belong to the pre-fix build; see [current evidence and limits](v1.6.1-validation.md#current-post-live-candidate-and-cleanup). That phase performed no GitPier commit, push or publication; the maintainer subsequently committed/pushed 74dc071 and explicitly authorized the release above.

简体中文：真实验收阶段从已提交b2d90b7继续，17项成功、1项GitLab普通评论未知且不重发，账号不足项保留未验。Gitea回调兼容修复通过11专项与855项Core，已重建Universal/DMG并验新应用恢复界面；此前升级与418图属于修复前版本。该阶段未提交、推送或发布；随后由所有者提交推送74dc071，并另行明确授权上述正式发布。

## v1.6.0 code review validation

Released **[1.6.0 (27)](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.6.0)** at commit `d4e1657e2ff3afec31c5a9c7a541d670ccd173c8`. The local audit below preceded the Swift 6.1 CI fix and publication recorded at the end of this section. Provider capabilities, position safety, permission changes and deliberate fallbacks are specified in the [code review guide](code-review.md). The implementation reuses the v1.5.1 detail loader/cache, Diff parser and OAuth token manager. Real review writes require explicit maintainer authorization for named test requests. Existing v1.5.1 live results below do not establish v1.6.0 acceptance.

Before the CI compatibility fix, the complete local Core regression passed **772 tests, zero failures/skips, 264.658 seconds**: the original 494 test functions plus 278 new cases. The focused run passed **424 tests, zero failures/skips, 1.439 seconds**; all **10 release-tool gates** passed in **2.080 seconds**. The complete Core evidence is `.cache/v160-core-full-final-v2.log`. The new cases cover provider APIs, anchor/submission safety, stable-identity concurrency locks, reviewer selection, inbox/branch identity, multiline comments, approval rules and disconnect intent. One original Gitea fixture was corrected to its actual unpaginated endpoint and strengthened; the remaining 33 original test files retain their baseline bytes.

Completed native acceptance includes the original UI/PTY suite (**104 captures**), the Hosting matrix (**273 captures**), real AppleEvent delivery with a mock OAuth exchange, and the final automatic Review run (**18 WindowServer captures / 21 provider assertions**). Four JSON records verify close/quit protection for unknown results without a draft body. A complete GUI-assisted Review run passed with **25 captures / 22 provider assertions**, including actual account/filter menu choices, late-response rejection, exact inbox/current-branch navigation and a real GitLab rule expansion/Load click. That rule read occurred exactly once and showed required approvals = 2 / rule not approved. Compare used its real view with actual refs and localized snapshot explanation; the existing main navigation was not clicked. Evidence: `.cache/ui-acceptance/v160-review-final-auto/` and `.cache/ui-acceptance/v160-review-final-gui/`. Counts describe captures, not unit-test cases; HTTP/credential stores are synthetic.

Before the CI compatibility fix, the local Universal candidate **1.6.0 (27), arm64 + x86_64** bundle passed deep signature and Sparkle structure checks with all **191 frozen build inputs unchanged**. `Scripts/test-dmg-structure.sh` passed. The unique local candidate DMG was packaged and verified (20,399,690 bytes); it was not published, installed or signed with the production EdDSA key; Finder visuals, drag installation and real Sparkle self-update remain separate acceptance boundaries.

The preceding results use local macOS 27.0.1 / Swift 6.4. Subsequent exact-commit CI and publication are recorded below; neither establishes Intel hardware or macOS 14 runtime acceptance. No v1.6.0 real-service review writes, natural token expiry, actual operating-system Keychain refusal or production upgrade have been verified. A damaged disconnect-intent sidecar rejects the entire Hosting metadata load; it is not silently ignored or repaired. If both the journal and main metadata writes fail, the session is revoked in memory and credential deletion pauses, but disconnection cannot be guaranteed across restart until persistence succeeds.

Run `Scripts/test.sh --filter 'HostingReview|HostingDisconnectionIntent|HostingApprovalRules'` for focused review checks, `Scripts/test.sh` for the complete Core regression, and `python3 Scripts/test-release-tools.py` for release tooling. Native review acceptance uses `Scripts/workspace-acceptance.sh review` after a Debug application build. The default run covers main/provider flows. To include real account/filter menu selections and GitLab rule controls, set `GITPIER_REVIEW_MENU_INTERACTIVE=1` and operate the displayed controls; the fixture waits for exact selection readback and API/UI postconditions. `GITPIER_REVIEW_ACCEPTANCE_PART=entries` requires that interactive flag; `providers` isolates provider diagnostics. The GUI-assisted run is not an unattended menu test. Compilation alone is not UI or provider acceptance.

简体中文：下述为发布前 1.6.0（27）本地验收检查点；后续 Swift 6.1 修复和正式发布见下一节。最终完整 Core 772 项（原 494＋新增 278），零失败/跳过，264.658 秒；专项 424 项零失败/跳过，1.439 秒；10 项发布工具门控通过，2.080 秒。原 UI/PTY 104 图、Hosting 273 图、真实 AppleEvent＋模拟 OAuth、最终自动 Review 18 图/21 断言与完整 GUI 辅助 Review 25 图/22 断言均通过。后者实际选择账号/筛选并验证迟到隔离、准确跳转、当前分支和 Git 状态保持，实际展开/加载 GitLab 规则且只读一次，显示所需批准 2、规则未通过；比较页使用真实原生视图与本地/跟踪引用，未点击旧主导航。截图数不等于测试用例数。最终 Universal 双架构、深层签名、Sparkle 结构及 191 项冻结输入核对通过，临时 DMG 结构通过。未安装、发布或使用生产更新私钥；Finder 实看、拖拽安装和 Sparkle 实际升级分开验收。本轮未执行真实评论/审批，未新增自然到期、实际 Keychain 拒绝、Intel/macOS 14 真机或 CI 验收。损坏断开日志会整体拒绝 Hosting 读取；双重持久化失败时不能保证断开跨重启。

### v1.6.0 publication — 2026-10-18

[GitPier v1.6.0](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.6.0) was published as **Latest** at **2026-10-18 04:55:29 (Asia/Shanghai)**, release ID **416045747**. The tag points to `d4e1657e2ff3afec31c5a9c7a541d670ccd173c8`. [Main CI 39067115701](https://github.com/Heisenberg2024/gitpier/actions/runs/39067115701) and [Tag CI 39067499370](https://github.com/Heisenberg2024/gitpier/actions/runs/39067499370) passed the complete workflow, including 772 Core tests, 10 release-tool gates, the native application build, temporary DMG structure and signature/permission-preserving archive upload. The failed earlier run exposed a Swift 6.1 type-check timeout in the large inbox body. Splitting the header, selectors, status and rows into native view expressions with explicit String labels preserved queries, permissions and cancellation behavior.

Both CI runs used Swift 6.1.2 and reported zero Core failures/skips. Main Core completed in 595.781 seconds and Tag Core in 507.051 seconds; their ten release-tool gates passed in 1.100 and 0.953 seconds respectively.

After that fix, 24 focused inbox tests and 10 release-tool gates passed locally. A new Universal bundle passed arm64/x86_64, deep-signature and Sparkle checks. GUI-assisted entry acceptance on that rebuilt release bundle passed with 6 WindowServer captures: real account/filter choices, five synthetic searches, zero remote writes, stale-scope/account rejection, exact inbox/current-branch navigation and unchanged local Git state. Comparison used the actual local/remote-tracking view; its old main-menu navigation was not clicked. All 191 frozen build inputs matched the working files and tagged commit.

The new released DMG is **20,404,197 bytes**, SHA256 `8726ec3c64340c16225164ddba27dea26bc742ca2db899b0746e3a33790e0dff`. Its 179 bundle entries matched the built content, links and permissions. Actual Finder inspection confirmed application/Applications icons, arrow and bilingual instructions. The original production Keychain EdDSA key signed the DMG and appcast; independent verification, exact embedded notes and equal-length DMG/Feed tamper rejection passed. Three Draft assets were downloaded by ID and verified before publication. Anonymous public downloads and the canonical Latest Feed then returned HTTP 200 with exact bytes, hashes, signatures, version/build/minimum OS, notes and Tag/Latest identity verified again.

All 14 historical releases, 38 remote assets, 14 prior tags, 33 local historical distribution artifacts and 12 protected source/config files were preserved. The installed application was not replaced. The application remains ad-hoc signed without Developer ID/notarization; no drag installation, production self-update, real v1.6.0 service writes, natural token expiry, actual Keychain refusal or Intel/macOS 14 device run was added. Publication evidence is local in `.cache/releases/v1.6.0/release-20261018-043312/`.

简体中文：v1.6.0（27）已于 **2026-10-18 04:55:29（Asia/Shanghai）**正式发布为 Latest，Release **416045747**，标签指向 `d4e1657e2ff3afec31c5a9c7a541d670ccd173c8`。修复 Swift 6.1 的收件箱视图类型推导超时后，Main/Tag CI 均通过完整 772 Core、10 发布门控、构建、临时 DMG 结构及保权限归档上传；本地 24 专项、10 门控和重建 Universal 上 6 图 GUI 辅助入口验收通过。191 项输入与标签源码一致，新 DMG 20,404,197 字节，179 包项目/链接/权限一致，Finder 图标/背景/双语说明实看通过；原生产钥签署、独立验签、等长篡改拒绝、Draft 回读及公开三附件/canonical Feed 核验均通过。历史版本、附件、标签、保护文件和实际安装保持；真实服务写入、安装/生产升级、自然过期、实际 Keychain 拒绝及 Intel/macOS 14 真机边界未扩大。

## Requirements

- macOS 14 or later; Xcode 16 or later with a Swift 6 toolchain and command-line tools.
- System Git, SSH, and an installed shell.
- Git LFS is optional for the LFS page. Install/configure it separately; GitPier never installs the tool, global filters or repository hooks. No new SwiftPM dependency is introduced.
- Swift Package Manager; commit `Package.resolved` for reproducible application dependencies.
- Python 3.9+ for release metadata and verification (standard library only); macOS `hdiutil`, `codesign`, `osascript` and Finder for local installer acceptance.

## Build and test

Run these scripts from the repository root:

```bash
Scripts/build-app.sh
Scripts/test.sh
```

The build script produces `dist/GitPier.app` for the current architecture. `CONFIGURATION=debug` selects a Debug build. `UNIVERSAL=1 Scripts/build-app.sh` builds both architectures; `Scripts/package-release.sh --unsigned-candidate` produces a local DMG candidate with SHA256. `BUNDLE_IDENTIFIER` and `CODE_SIGN_IDENTITY` can set an owner-controlled bundle ID and signing identity. The default ID is `com.heisenberg2024.gitpier` and the default signature is ad-hoc; packaging does not notarize or publish anything.

Scripts keep build caches in `.cache` and use SwiftPM's native build engine. The engine may report a deprecation warning on newer toolchains. Do not bypass hooks, signing, or transport verification to work around build or Git failures.

## CI validation policy

`.github/workflows/validate.yml` keeps the required check named `build-test`. A small Ubuntu planning job runs `python3 Scripts/test-ci-validation.py` and selects one of three paths:

- **Full:** the original macOS toolchain check, real Git/Core tests, release metadata/signing gates, Release application build and signature verification, temporary DMG structure test, permission-preserving ZIP and artifact upload. Only successful completion of all these steps produces `Full macOS validation complete (v1)`.
- **Documentation:** Ubuntu checks the complete Git diff for whitespace errors, UTF-8, NUL bytes and unresolved conflict markers, and still runs all ten offline release metadata/security gates. Only ordinary non-executable Markdown in `docs/`, `README.md`, `README.zh-CN.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, `SECURITY.md` and `.github/pull_request_template.md` qualifies. Packaged branding/legal Markdown, licenses, source, resources, scripts, workflows and dependency files require full validation. Rename source and destination both count. New branches, force pushes, empty diffs and unavailable comparison history never qualify for the documentation shortcut.
- **Reuse:** main/tag push runs for the same SHA queue at the workflow level (`queue: max`, no cancellation), without occupying a waiting runner. Whichever runs second can reuse the first's full validation. The planner checks the same repository, workflow, push source and exact commit; it reads all pages of the latest attempt's jobs and requires every full step and completion marker to have succeeded, then rechecks the run. The summary links to that run/attempt and its development artifact. A green documentation/reuse run, skipped step, failed run, API error or incomplete evidence cannot establish full validation. When no valid evidence exists, the tag runs the complete macOS path, even for a documentation-only release commit.

PR and other branch runs do not reuse release evidence. Manual dispatches and explicit reruns always perform full validation, including failed-jobs-only reruns that retain an earlier plan's outputs. Rerun artifacts add an `-attempt-N` suffix to avoid name conflicts and preserve previous uploads. The SHA queue has GitHub's 100-pending-run limit. Planning failures fail `build-test`; the workflow does not hide required checks with top-level path exclusions. Tokens remain read-only: only planning needs `actions: read`, and checkout does not persist credentials. No CI path signs production updates, publishes releases or changes repository settings.

Full runs execute the complete XCTest suite with two worker processes and two compilation jobs; IDE index generation is disabled for this CI test build. SwiftPM build/dependency and compiler module caches are separated by runner OS/architecture, Xcode/Swift/SDK/system versions and dependency manifests, with build inputs in the exact cache key. Compatible previous inputs can supply incremental compilation state. `Scripts/ci_cache_inputs.py` records relative paths, SHA-256, modes and nanosecond timestamps in `.cache/swiftpm/gitpier-input-timestamps-v1.json` after all full push gates pass. On restore it considers only current tracked sources, tests, resources and package manifests, requires the same toolchain context and identical contents/modes, and uses descriptors to reject symlinks, hard links and changing inputs. Missing or invalid records leave normal compilation in place. Both Debug application/CLI builds and the existing credential CLI acceptance remain part of the complete test command; Release builds and packaging also remain. Only `.build`, `.cache/swiftpm`, `.cache/swift` and `.cache/clang` are cached. Pull requests only restore caches; successful full push runs save them after every original gate passes. Cache hits never skip tests, signature verification or packaging, and cache transport failures are optional.

Planning is limited to five minutes and `build-test` to forty minutes, with twenty minutes for Core tests and twelve for the application build. Cache transfers and packaging steps have their own limits. Full runs retain test logs and xUnit results as `GitPier-core-tests-attempt-N`, including failed test runs when the runner can upload diagnostics. A hosted-runner disconnect can prevent both logs and artifacts from being saved; it is not evidence of a passing or failing test assertion.

For offline CI-policy validation, run `python3 Scripts/test-ci-validation.py` and `python3 Scripts/test-release-tools.py`. These do not build or launch the application. Changes to routing or the full-step contract require updating the corresponding regression coverage. Before publishing, inspect the **exact release SHA's successful full `build-test` steps and completion marker**, or follow a verified reuse link to those steps; a successful lightweight workflow alone is insufficient.

简体中文：CI 保留原 `build-test` 检查名。普通文档由 Ubuntu 检查完整差异、空白、UTF-8、NUL 和冲突标记，并保留 10 项发布安全门控；打包使用的 Markdown/许可证、源码、资源、脚本、工作流和依赖不在轻量白名单。同 SHA 的 main/tag 先由 GitHub 排队，再逐项核对相同仓库、工作流、提交及最新 attempt 的完整成功步骤，避免占用 runner 等待。文档轻量成功或仅复用成功都不能冒充完整验收；API 异常、缺失或不完整证据回退完整 macOS 检查。纯文档提交后来打发布标签时也必须获得该 SHA 的完整验收。手动运行和显式重跑始终全验，原生测试、签名、包结构、DMG 和保权限归档均保留。发布前查看完整成功步骤/标记或复用链接，不能只看 workflow 绿色状态。

完整回归使用两个独立测试 worker、两个编译任务，并关闭 CI 测试构建的 IDE 索引。仅缓存 SwiftPM 构建/依赖和编译器模块目录，按系统、架构、工具链、SDK 与依赖清单隔离，再按构建输入区分精确缓存；PR 仅恢复缓存，完整 push 通过全部原有门槛后才保存。`Scripts/ci_cache_inputs.py` 在全部完整 push 门槛通过后，将相对路径、SHA-256、权限模式及纳秒时间戳记录到 `.cache/swiftpm/gitpier-input-timestamps-v1.json`。恢复时仅处理当前受跟踪的源码、测试、资源与包清单，要求工具链、内容和模式一致，以描述符拒绝符号链接、硬链接及变化中的输入；记录缺失或无效时保持正常编译。完整测试命令仍构建 Debug 应用与 CLI，并保留真实凭证 CLI 验收，Release 构建与打包也保留。命中缓存仍执行全部测试、签名和打包检查。plan 最多 5 分钟，build-test 最多 40 分钟，Core/应用构建分别最多 20/12 分钟；测试日志与 xUnit 结果按 attempt 留存，失败时也尝试上传。托管 runner 失联可能使日志无法保存，不能据此声称测试断言成功或失败。

## Local acceptance

Core tests create temporary Git repositories. Keychain tests use synthetic entries and remove them. Native UI / PTY acceptance requires a logged-in macOS session:

```bash
Scripts/ui-acceptance.sh
```

For the v1.3 workflows, run `GITPIER_UI_ACCEPTANCE_SCOPE=version130 Scripts/ui-acceptance.sh`. Rebase tests exercise typed plans, native conflicts, restart/message recovery, hooks/signing rejection and stale HEAD/Index/todo/file protection in disposable repositories. Hosted screenshots supplement actual visible GUI interaction; they do not establish real drag or confirmation behavior. Native Git may require an explicit recovery commit after a signing/hook failure; keep its diagnosis, use the repository terminal or reviewed Abort, and never disable signing to make acceptance pass.

The temporary DMG structural test uses a unique staging directory, volume and mount point. Only an exact `hdiutil: create failed - Resource busy` retries (three attempts; one/two-second delays). Every attempt emits its complete log, uses a different image path, and other failures stop immediately. Cleanup detaches only its own mount, preserves the directory if detach fails, and never forces a detach or restarts DiskImages services. `python3 Scripts/test-release-tools.py` includes four offline retry gates. A successful original-commit CI rerun establishes environment evidence only; new local source still needs its own CI after an owner-authorized commit/push.

The v1.3 scope also renders Patch import/export, LFS rules/files and Submodule list/review/Add in both languages and appearances using temporary repositories. Installed LFS interfaces use a clearly identified, network-disabled command fixture when the host lacks Git LFS; this does not establish real LFS server/credential/download acceptance. Submodule fixtures use only temporary local origins with file transport enabled for the fixture process. Native previews and write actions check preserved HEAD/Index and reuse DiffTable.

For visible P1 inspection, set `GITPIER_UI_ACCEPTANCE_INTERACTIVE_V130=1` and `GITPIER_UI_ACCEPTANCE_INTERACTIVE_PAGE=advanced` with a separately identified Debug bundle via `GITPIER_UI_ACCEPTANCE_EXECUTABLE`. The isolated panel exposes fixture, language and appearance selectors at 960×640, including a clearly labeled network-disabled LFS interface. Finish by creating `finish-gui` in the output directory; the process restores its settings, quits and cleans the temporary repositories. Normal application Settings scenes are not registered by the standalone acceptance runner; use these dedicated selectors instead.

For the rejected-push workflow only, run `GITPIER_UI_ACCEPTANCE_SCOPE=push-recovery Scripts/ui-acceptance.sh`. It checks the English and Simplified Chinese native alert buttons, cancellation, successful merge/push and conflict resolution against disposable local remotes, and captures only the test alerts.

Use `GITPIER_UI_ACCEPTANCE_SCOPE=version110 Scripts/ui-acceptance.sh` for native update-delegate/gate registration, deferred install callbacks, cancellation of reviewed destructive actions, full-history layout, rapid stash previews and bilingual About captures.

Use `GITPIER_UI_ACCEPTANCE_SCOPE=conflicts Scripts/ui-acceptance.sh` for the built-in conflict editor. It uses disposable local remotes to verify native text input, block-choice button actions, drafts across files, save/review cancellation, protected merge commits and the original push destination. English and Simplified Chinese captures contain only the fixture window.

App-modal `NSAlert.runModal()` is separate from SwiftUI's attached sheets. Default conflict acceptance checks its alert configuration without displaying a blocking quit dialog. Set `GITPIER_UI_ACCEPTANCE_INTERACTIVE_QUIT=1` only for an interactive run and press Cancel on the actual quit alert; do not infer a successful click from a proxy button or an empty `attachedSheet`.

For scrollbar coverage only, run `GITPIER_UI_ACCEPTANCE_SCOPE=scrollbars Scripts/ui-acceptance.sh`. It checks application pages and all eight Settings tabs in both languages, native thumb dragging and fading, dynamically replaced and nested SwiftUI scroll views/editors, document resizing/replacement, compact viewports, Diff header clipping and terminal scrollback/alternate screens. The full UI/PT​Y acceptance also includes these checks. The `context-assistant` scope additionally checks independent popover-window themes, shared scrollbar installation and native thumb dragging; optional `GITPIER_ASSISTANT_VISUAL_HOLD=1` pauses for compositor inspection of the closed anchor and light/dark materials (`themes` pauses only on the two themes). Set `GITPIER_CONTEXT_READONLY_REPOSITORY=/absolute/repository` on that scope (or the focused `context-repository` scope) to verify comparison/confirmation against an existing repository without Fetch or writes; the disposable workspace uses explicitly simulated freshness metadata, not the real app’s check history.

Captures and execution records default to `.cache/ui-acceptance`. `Scripts/performance.sh` generates a marked disposable workload and writes measurements to `.cache/performance/latest`. These results are local artifacts, not public compatibility guarantees.

## Product images

`Scripts/product-screenshots.sh` builds the Debug application and captures its existing native components using isolated, temporary demonstration repositories. This entry point is compiled only in Debug builds. It uses no real accounts or remotes, displays relative fixture paths, and uses a controlled shell prompt. Inspect every image before publishing it. Only the four approved PNGs belong in `docs/screenshots`.

`Resources/Branding/gitpier-icon-1024.png` is the canonical raster icon, with transparency outside its rounded tile. `Scripts/build-app.sh` regenerates the AppIcon sizes and SwiftPM resource before every build, preserving the master image's exact bytes. It creates a fresh iconset and uses a content-stamped ICNS filename in Info.plist; increment the bundle build number when replacing a packaged application. `AppResources.applicationIcon` is shared by the sidebar, Dock, and About panel, whose icon is passed explicitly. Both image workflows call `Scripts/strip-png-metadata.py` to remove text, EXIF, and timestamps from generated outputs while preserving pixels and color profiles.

## Public file boundary

Keep source, tests, package manifests and lockfile, reviewed resources, build scripts, CI, and public documentation. `.gitignore` excludes build output, local app configuration, secret-bearing files, caches, and internal notes under `.local`. Review environment examples individually. `PROJECT_MEMORY.md` is local working guidance and is intentionally excluded; `AGENTS.md` contains portable contributor guidance.

Before publishing, inspect both current files and Git history with a local secret scanner. Ignore rules do not remove previously tracked files or secrets from history. Do not rewrite history or publish without the owner's authorization. GitPier uses the [MIT License](../LICENSE); retain the [third-party notices](../THIRD_PARTY_NOTICES.md) and dependency license texts when distributing the application. GitPier's copyright holder is Heisenberg2024 (2026); keep LICENSE and the build script's copyright metadata consistent. Distribution identity, Developer ID signing, notarization, and future public releases still require the owner's authorization.

## DMG and Sparkle release preparation

Maintain production versions only in `Sources/GitPier/Resources/ReleaseConfiguration.json`; increase `build` for every distributed build. Keep the production bundle identifier stable. Empty `publicEDKey` means updates are disabled and production release signing refuses to run.

```bash
Scripts/test.sh
python3 Scripts/test-release-tools.py
UNIVERSAL=1 Scripts/build-app.sh
Scripts/package-dmg.sh
task_version="$(python3 Scripts/release_metadata.py --field version)"
Scripts/verify-dmg.sh "dist/GitPier-${task_version}-macos-universal.dmg"
```

`package-dmg.sh` refuses to overwrite an existing image and requires a logged-in Finder session with Automation permission. The Finder-only layout is in `Scripts/layout-dmg.applescript`: a 720 × 448-point outer window (approximately 720 × 420-point content), 104-point real icons at (190,196) and (530,196), and /Applications symlink. `Scripts/generate-installer-background.swift` regenerates `Resources/Installer/background@2x.png` and `background.tiff` using AppKit; the TIFF includes 1x/2x representations. No external assets, false icons or installer programs are used. Visually inspect the mounted Finder window separately from the structural checks and copy to an isolated installation location for launch acceptance.

Initialize the production signing key only as an explicit owner action:

```bash
Scripts/update-keys.sh init
Scripts/update-keys.sh public
Scripts/update-keys.sh export /secure/offline/location/GitPier-update-key.secret
```

Paste only the public key into `publicEDKey`. The official Sparkle tool stores the private key in the login Keychain under account `GitPier-production`. Export uses mode 0600, refuses repository paths and existing files; transfer the backup to encrypted offline storage and remove the temporary copy. Never put private key contents in command arguments, logs, source or CI. Restore with `Scripts/update-keys.sh import /secure/backup/GitPier-update-key.secret` on an owner-controlled machine and verify the public key again. Without Developer ID, losing this key can require a manually trusted replacement installation; do not assume automatic key rotation is possible.

For an encrypted local backup, create a mode-0700 directory outside the repository and invoke `swift Scripts/backup-update-key.swift create /secure/backup/GitPier-update-key.dmg "$PWD"`. It creates an AES-256 disk image, exports the seed directly into that encrypted volume, enforces mode 0600, and verifies it by read-only remount, public-key comparison and a signing proof. The image password is generated in memory and stored separately in the login Keychain under service `com.heisenberg2024.gitpier.signing-backup`; the image's `.json` sidecar identifies its account and hash without containing secrets. Verify later with the same command using `verify` instead of `create`. The tool refuses overwrite and never prints passwords or private keys. A local backup does not survive loss of the machine unless both the image and its unlock password are copied to separate secure offline storage. Use Keychain Access to retrieve the password, mount the image, and import `GitPier-update-key.secret` only on an owner-controlled recovery machine.

After reviewing release notes and completing local acceptance:

```bash
task_version="$(python3 Scripts/release_metadata.py --field version)"
Scripts/sign-release.sh "dist/GitPier-${task_version}-macos-universal.dmg" reviewed-release-notes.md
# Or perform the complete build/test/package/sign pipeline with a new output path:
Scripts/package-release.sh reviewed-release-notes.md
```

Signing validates the Keychain public key, final DMG, EdDSA signature against the embedded public key, version/length/fixed download URL, signed appcast and unchanged DMG hash. Sparkle's official `generate_appcast` embeds the reviewed notes and signs the feed. Do not edit the feed/notes or DMG after signing. Copy only the DMG, .sha256 and appcast.xml into a future GitHub draft; no private keys, test fixtures or unsigned candidates. The scripts never upload or publish.

Before release, confirm a clean approved source commit and successful full CI for that exact SHA (see the CI validation policy above), review the bilingual notes with the owner, create a draft only with authorization, upload all three assets and compare remote sizes/hashes. Publish only after authorization. Verify the latest feed redirects and a real old-version update after publication; retain historical ZIP releases unchanged.

## Isolated updater acceptance

The production key is not used for tests. `Scripts/serve-update-test.py` serves only a fixture directory on a random loopback port. `Scripts/prepare-update-test.py` creates separate Bundle IDs and a disposable CryptoKit Ed25519 seed under ignored `.cache/update-acceptance`; workspace location is embedded in test-only Info.plist so Sparkle relaunch cannot fall back to the user's real workspace. Runtime data and the controlled shell are created under a dedicated `/private/tmp/GitPier-update-acceptance-*` directory (recorded in `runtime-root.txt`) to avoid Documents privacy prompts during launchd relaunch; keep test repositories there too. No privacy permission is relaxed.

```bash
python3 Scripts/serve-update-test.py .cache/update-acceptance/example/server
# In another terminal, after the server starts:
python3 Scripts/prepare-update-test.py .cache/update-acceptance/example
open .cache/update-acceptance/example/installed/GitPier.app
```

Use Check for Updates in the test app, confirm installation and verify build 20 → 21, relaunch, workspace/draft preservation and framework loading. Also test invalid signed feeds, missing/invalid DMG signatures, altered archives, failed downloads, cancellation, active Git work, unsaved conflict drafts and read-only-DMG launch. Prefer isolated installation locations. When verifying /Applications, use a distinct filename plus the isolated test Bundle ID, preserve any existing GitPier.app, and remove only the verified test copy afterwards. Quit test apps, stop the loopback server, remove disposable private-key files and retain only redacted acceptance evidence. A mounted DMG or readable appcast alone does not prove a successful self-update.

Full CI runs unit tests, metadata/security gate tests, native bundle builds and `Scripts/test-dmg-structure.sh`, which creates and deletes a clearly temporary image without claiming Finder layout. It must not generate production keys, publish releases or claim Finder visuals / actual self-updates in a headless job.

Failure cases can be prepared with `python3 Scripts/update-test-scenario.py .cache/update-acceptance/example invalid-signature` (or `invalid-feed`, `tampered-dmg`, `download-failure`, `restore`). These commands only modify the isolated loopback fixture. AppKit/Sparkle language preferences are stored only in the application's own defaults domain and follow the selected GitPier language after restart.

Example draft creation, only after explicit authorization and source/asset review:

```bash
task_version="$(python3 Scripts/release_metadata.py --field version)"
gh release create "v${task_version}" --draft --target "$APPROVED_COMMIT_SHA" --title "GitPier v${task_version}" --notes-file "$REVIEWED_NOTES_FILE" "dist/GitPier-${task_version}-macos-universal.dmg" "dist/GitPier-${task_version}-macos-universal.dmg.sha256" dist/appcast.xml
```

`APPROVED_COMMIT_SHA` and `REVIEWED_NOTES_FILE` must identify the owner's approved commit and final notes. This command is documentation, not an automatic publishing step; verify draft assets and CI before separately approving publication.

## v1.2.0 professional workflows

Released v1.2.0, build 18, is based on v1.1.0 (1827818). The original 98 Core tests and six release-tool gates remain intact. Worktree identification/opening, commit details, DiffTable, literal paths, reviewed destructive actions and per-working-tree state already existed; the new pages reuse them.

| Capability | v1.1.0 baseline | v1.2.0 implementation |
| --- | --- | --- |
| Reflog | No dedicated page/query | Native paged HEAD/local-branch log, filters, details, fixed-object recovery branch, reviewed soft/mixed reset |
| Worktrees | Identify/open linked repositories | List/create/register, lock/unlock, guarded remove, moved-linked-tree repair, shared metadata queue |
| Branch comparison | Commit/parent Diff | Local/remote-tracking ref pairs, merge bases, unique counts/paged commits, tip or three-point file Diff |
| Blame | File history and commit Diff | Working/historical text, per-line attribution, commit/file details, rename attribution and bounded paging |

Run the complete suite with `Scripts/test.sh`, `python3 Scripts/test-release-tools.py`, and `Scripts/ui-acceptance.sh .cache/ui-acceptance/v120`. The workflow-only GUI entry is `GITPIER_UI_ACCEPTANCE_SCOPE=version120 Scripts/ui-acceptance.sh .cache/ui-acceptance/v120-workflows`. All writes and resets in these workflows use disposable repositories. The visible GUI mode sets `GITPIER_UI_ACCEPTANCE_INTERACTIVE_WORKFLOWS=1`, uses an independently identified application through `GITPIER_UI_ACCEPTANCE_EXECUTABLE`, supports `GITPIER_UI_ACCEPTANCE_LANGUAGE=zh-Hans` / `GITPIER_UI_ACCEPTANCE_APPEARANCE=light` for isolated initial settings, and waits for a `finish-gui` marker in its output directory after manual interactions. Use an isolated workspace and application identity; never launch this mode with a normal user's workspace. Offscreen view bitmaps do not prove full SwiftUI visuals or mouse interaction.

Local builds remain development candidates until an approved release. Production signing, asset uploads, tags and publication require owner authorization; preserve historical releases. The production Bundle ID, Sparkle 2, feed and public key are retained; never replace or regenerate the production key. Keep future changes in Unreleased until an approved release. Universal compilation does not establish Intel/macOS 14 device acceptance or notarization.

### v1.3.0 local validation — 2026-10-15

Before release, the 1.3.0 (19) source passed 201 Core tests with zero failures/skips and ten release-tool gates. The original full native UI/PTY regression and the v1.3 workflow scope passed; the added visible P1 panel was compiled and checked again through `Scripts/ui-acceptance.sh`. Actual CUA inspection covered Patch import/export, the explicitly marked LFS interface fixture and Submodules at 960×640 in English/Chinese and light/dark, with native Diff, OID/gitlink details, rule/Add sheets and default-cancel confirmations. A native Patch save produced the expected 225-byte fixture. Read-only inspection and cancelled confirmations retained the fixture's staged configuration/gitlink and working files.

`UNIVERSAL=1 Scripts/build-app.sh` passed on the final source, including both architectures, Sparkle helpers and deep signatures. A new local HFS+/ULFO DMG passed `Scripts/package-dmg.sh` structural/signature checks; all 109 mounted bundle files/links matched the current application. Finder displayed the actual application icon, Applications link, background, arrow and bilingual instructions. That earlier image was a local review artifact without production EdDSA signing. No commit, push, tag or Release was created at that checkpoint. Subsequent Swift 6.1 compatibility and release checks are recorded below; real LFS server downloads, physical Rebase drag behavior, Intel/macOS 14 device runs and production update/Gatekeeper acceptance remain outside this local evidence.

Additional interface/update fixes passed the full UI/PTY suite and the v1.1 updater lifecycle scope, followed by a current Universal rebuild. Visible inspection checked aligned Rebase controls, functional menus without attached indicators, and the complete About content at the fixed 760×580 Settings size in both languages/appearances. A temporary-key signed loopback Feed offered build 21 to build 20 automatically despite a freshly seeded last-check date; disabling automatic checks persisted across restart with no Feed request, and manual checking still offered the update. Both dialogs were dismissed without downloading/installing. The test application, server, preference domain, runtime and disposable key files were cleaned; the production install and preferences were read only. The earlier local DMG predates these additional interface changes and must not be distributed as the current candidate.

The visible v1.3 inspector accepts `GITPIER_UI_ACCEPTANCE_INTERACTIVE_PAGE=rebase` for the clean linear fixture and `about` for 760×580 Settings. These are optional isolated acceptance entries; normal launches and the default full suite retain the same workflow.

### v1.3.0 release validation — 2026-10-15

[v1.3.0](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.3.0) was published as Latest after owner approval of the bilingual notes. Its tag and final Universal DMG correspond to commit `b2de5bdadffecc11d8da265e6905e6126f3d4f6f`. [Same-commit CI](https://github.com/Heisenberg2024/gitpier/actions/runs/38616173476) passed 201 Core tests with zero failures/skips and ten release-tool gates on Swift 6.1.2 / macOS 15, plus application build, temporary DMG structure and archive/upload checks. Earlier runs exposed actor-isolation errors in a local async Submodule traversal and type-check timeouts in complex Rebase/Submodule Text expressions. The final source uses an actor-isolated traversal with Sendable value state and explicit String summaries; it retains scan bounds, displayed content and reviewed operations.

The final source passed the native v1.3 scope again, followed by a new Universal build and DMG. The mounted application's 109 files/links matched the built bundle, and actual Finder inspection confirmed the real icons, Applications link and bilingual background. The DMG is 12,656,672 bytes with SHA256 `a82da2522b1a95b4a744bd9a24bd5ccee9fbde5ca471ffa338ae5039677b7f76`.

The existing production EdDSA key signed the DMG and Feed; altered copies were rejected. Draft and public release bodies matched the approved notes, and all three downloaded attachments matched local sizes, hashes and signatures. Public download URLs and the canonical Latest Feed returned HTTP 200; the Feed served the signed 1.3.0 (19) item. All six historical releases, fourteen historical assets and existing tags were preserved. The user's installed application was not replaced. Real LFS server downloads, physical Rebase drag, Intel/macOS 14 device runs, quarantine/Gatekeeper and a production v1.2.0 → v1.3.0 self-update remain unverified; Developer ID signing/notarization are still absent.

### Local validation — 2026-10-14

`Scripts/test.sh` passed all 128 Core tests (the original 98 plus 30 new cases), with zero failures and zero skips in the normal macOS environment. `python3 Scripts/test-release-tools.py` passed all six existing gates. New tests use temporary Git repositories and cover recovery after reset, unavailable objects, 1,001-record reflog pagination, worktree creation/lock/removal/repair, stale reviews, ignored files, replaced-directory ownership, detached commit retention, independent Index/drafts/layouts, full-ref comparison, merge bases, rename Blame, large files and cancellation.

The final `Scripts/ui-acceptance.sh .cache/ui-acceptance/v120-full` run passed the complete native UI/PTY suite, including existing 1.0.2/1.1.0, conflict, scrollbar and terminal regressions plus the v1.2.0 workflow checks. `UNIVERSAL=1 Scripts/build-app.sh` verified both arm64/x86_64, version 1.2.0 (18), embedded Sparkle helpers and deep signatures. `Scripts/test-dmg-structure.sh` passed on that final bundle; it verifies a disposable image and does not establish a new Finder drag-install or self-update.

Visible acceptance used a separate application identity, isolated configuration and disposable repositories. Native interactions checked recovery-branch creation, worktree creation/registration/lock/unlock/removal with the affected path, independent state, both comparison semantics, Blame → commit file Diff → return, English/Chinese, light/dark and 960×640 layouts. Hosted/offscreen component snapshots are separate evidence and do not prove complete SwiftUI pixels.

Blame refuses single lines longer than 20,000 UTF-16 characters as well as files over 4 MiB, to keep native text layout bounded. Removal of external worktrees is intentionally unavailable; repair does not grant deletion ownership. Repair supports moved linked trees within the same common directory, not an automatic relocation of the whole main repository. This local validation preceded the release checks below.

### Release validation — 2026-10-14

[v1.2.0](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.2.0) was published as Latest after owner approval of the bilingual notes. Its tag and Universal DMG correspond to commit `c08d64bf81f58b8a45daaae3a71be83524180f84`. [Same-commit CI](https://github.com/Heisenberg2024/gitpier/actions/runs/38490929602) passed 128 Core tests and six release-tool gates on Swift 6.1.2 / macOS 15, plus application build, temporary DMG structure and archive/upload checks. Local packaging verified arm64/x86_64, the embedded Sparkle helpers, deep signatures, HFS+/ULFO DMG structure and the visible Finder installer layout.

The final DMG and Appcast were signed with the existing production EdDSA key. Altered archive/feed copies were rejected. Draft and public downloads of the DMG, checksum and Appcast matched the local hashes; the Latest feed served the same signed 1.2.0 (18) item. Historical release bodies, tags and attachments were preserved. Intel/macOS 14 device runs, an actual new-DMG mouse drag/install, downloaded quarantine/App Translocation, Developer ID/notarization and an end-to-end v1.1.0 → v1.2.0 production update remain unverified.

### v1.4.0 local validation and measurements — 2026-10-15

Released [v1.4.0](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.4.0) is build 20. Workspace Core regressions cover local-only status, unchanged Index bytes, branch/HEAD/upstream changes, permission/missing/invalid failures, worktree identity, request coalescing/priorities/cancellation, failed-cache backoff, reviewed Fetch/transport errors and safe shared queues, and literal Unicode/special-path, commit and scope searches. Partial-clone local queries require Git 2.43 or later because older versions ignore the lazy-fetch prohibition; ordinary repositories retain existing Git compatibility.

Run native workspace acceptance with `GITPIER_UI_ACCEPTANCE_SCOPE=version140 Scripts/ui-acceptance.sh`, or `Scripts/workspace-acceptance.sh version140` for the packaged Release app. The latter copies the existing app under a unique test bundle ID, resigns only that copy, disables production updater configuration by identity mismatch and removes its own preference domain/bundle on exit. Production application/preferences remain untouched. The full default UI/PTY suite includes the workspace scope. Optional `GITPIER_UI_ACCEPTANCE_INTERACTIVE_V140=1` keeps a disposable visible fixture open until the output directory contains `finish-gui`; use an independently identified application copy for manual inspection. Only fixture repositories are cloned/changed.

For repeatable Release measurements, first build with `UNIVERSAL=1 Scripts/build-app.sh`, then run:

```bash
Scripts/workspace-acceptance.sh workspace-performance .cache/performance/workspace
```

The harness creates 10/50/100 physical repositories, one linked Worktree and two unavailable entries, 10,000 untracked files and 1,000 commits per clone. It records native Dashboard readiness before scanning finishes, local scan/refresh duration, organization switching during refresh, direct Git process launch peaks, failure isolation and main-loop lag. Readiness uses a fresh AppStore/cache in a warmed native process and excludes fixture creation/process launch; RSS is process-wide cumulative `ru_maxrss`. Counters store no arguments, paths or search text. Measurements and screenshots remain local/ignored; do not infer improvement percentages, physical Intel/macOS 14 compatibility or production self-update from these checks.

Local validation on 2026-10-15 passed all 239 Swift tests (the original 201 plus 38 workspace cases), with zero failures/skips, and all ten release-tool gates. The complete native UI/PTY suite passed in SwiftPM and again through the separately identified Universal Release copy, including v1.1/v1.2/v1.3/v1.4 workflows. Visible Release inspection checked Dashboard filters/worktree collapse, readable Fetch review/cancellation, actual Quick Open keys with terminal exclusion, scoped tracked-path search and file-history navigation. FSEvents notification-only semantics survived configuration saves until explicit refresh.

Release measurements on macOS 27.0.1, Apple silicon with 14 logical CPUs and Apple Git 2.54.0 used exactly 10/50/100 physical repositories, plus one linked Worktree and two unavailable entries per case. Each clone had 1,000 commits; one repository had 10,000 untracked files. One sample per case, with fresh store/cache in a warmed visible native process:

| Physical repositories / entries | Dashboard ready (ms) | Local scan (ms) | Refresh (ms) | Direct Git peak | Peak process RSS (MiB) | Organization layout during refresh (ms) | Heartbeat excess p95 / max (ms) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10 / 13 | 240.21 | 628.49 | 337.30 | 3 | 193.36 | 50.63 | 30.26 / 33.51 |
| 50 / 53 | 316.51 | 1585.71 | 1434.69 | 3 | 221.05 | 94.22 | 31.00 / 74.54 |
| 100 / 103 | 595.25 | 3177.58 | 2412.19 | 3 | 247.36 | 104.81 | 25.22 / 94.53 |

Full RepositoryModel refresh count was zero in every scan case; the unavailable entries did not block the remaining repositories. Deliberate missing-remote Fetch failed independently in 57.93/59.18/61.64 ms. Organization timing measures a programmatic scope change followed by native layout/yield, not a physical-click latency; heartbeat values measure scheduling excess over a 10 ms probe. Direct Git counters exclude helpers launched internally by Git. No previous-version performance baseline was measured, so no percentage improvement is claimed.

The final 1.4.0 (20) Universal bundle, Sparkle helpers and deep signatures passed. A local HFS+/ULFO DMG passed structure/signature checks; 109 mounted bundle files/links and permissions matched the built app. Actual Finder inspection confirmed the real GitPier icon, Applications link, background, arrow and bilingual instructions. That earlier candidate was not production EdDSA signed or published; final release validation is recorded below. A temporary-key signed loopback update completed build 20 → 21, installation/relaunch and responsive startup under a separate test identity; repository settings/selection/draft and Index bytes were preserved. The workspace JSON was normally reserialized with default fields. Altered Feed and invalid archive signatures were rejected; the test app/runtime/private key/preferences/server were cleaned. Production preferences/configuration and historical local packages/appcast fingerprints stayed unchanged.

Earlier verification exposed a dictionary exclusivity conflict, actor closure isolation-checker limitations and stale configuration/cache edges; these were repaired and rerun. Acceptance-only issues included an unsigned outer test-app copy, an initial-foreground-refresh timestamp race and an offscreen accessibility tree containing only scrollbars. The wrapper now signs the outer copy and benchmarks visible windows after activation; failed checkpoints are not counted as passing measurements. Intel/macOS 14 device runs, real LFS service downloads, physical Rebase dragging, downloaded quarantine/Gatekeeper, real Applications drag installation and production self-update remain outside this local evidence. Developer ID/notarization are still absent.

### v1.4.0 release validation — 2026-10-15

[v1.4.0](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.4.0) was published as Latest after owner approval of the revised English-first bilingual notes. The tag and final Universal DMG correspond to commit `51a1cd958f0b9a47e7d1b12486edcd94cc6b4ef6`. [Same-commit CI](https://github.com/Heisenberg2024/gitpier/actions/runs/38676352614) passed 239 Core tests with zero failures and ten release-tool gates on Swift 6.1.2, plus application build, temporary DMG structure and archive/upload checks.

The final source was rebuilt through `UNIVERSAL=1 Scripts/build-app.sh`; all 141 recorded build inputs matched the approved clean commit. The application and Sparkle helpers passed both-architecture/deep-signature checks. The HFS+/ULFO DMG passed structural verification; its 109 bundle files/links and permissions matched the built app, and actual Finder inspection confirmed the real icons, Applications link, arrow and bilingual instructions. The DMG is 13,637,970 bytes with SHA256 `5bd51482569e8d28dcd325e294a670133239c7686018ca80c8adc985c34a0fbd`.

The existing production EdDSA key signed the DMG and Appcast, with the bundle ID, public key and feed URL unchanged. The signed feed embeds the approved notes byte-for-byte; altered archive/feed copies were rejected. Draft metadata, server digests and all three downloaded attachments matched the approved body and local bytes/hashes/signatures before publication. After publication, the three public downloads and canonical Latest Feed returned HTTP 200 and matched the same assets; feed/archive signatures verified again. All seven historical releases, seventeen historical assets and existing tags were preserved; the user's installed application, preferences and workspace were unchanged. Intel/macOS 14 device runs, real LFS service downloads, physical Rebase dragging, downloaded quarantine/Gatekeeper, real Applications drag installation and a production self-update remain unverified. Developer ID signing and Apple notarization are still absent.

### Post-release CI SIGPIPE repair — v1.4.1

The documentation-only commit `5c57c15` changed six Markdown files. Its [CI run](https://github.com/Heisenberg2024/gitpier/actions/runs/38679465508) and the [v1.4.0 tag run](https://github.com/Heisenberg2024/gitpier/actions/runs/38678738243) both exited with signal 13 during `testSelectedLinesNativePatchCheckFailurePreservesIndex`. The same source had passed its earlier CI run; the later failures exposed an existing timing-dependent process-I/O defect. The test intentionally rejects a Git patch without reading stdin. An asynchronous `FileHandle` write to the closed pipe could deliver SIGPIPE before Swift could handle its EPIPE error.

`ProcessRunner` now sets Darwin's `F_SETNOSIGPIPE` on the parent stdin write descriptor before launch, without changing the application-wide signal disposition or child/hook behavior. `ProcessRunnerTests.testClosedStdinDoesNotTerminateRunner` launches a disposable XCTest child with the default terminating SIGPIPE policy, so the regression cannot kill the parent suite. It reproduces exit 13 before the fix and covers early/partial input rejection, preserved exit diagnostics, normal byte delivery, timeout/cancellation and the unchanged signal policy after the fix. Do not suppress SIGPIPE globally or skip the failing test. The published v1.4.0 tag and assets are unchanged; this source fix passed [same-commit CI](https://github.com/Heisenberg2024/gitpier/actions/runs/38681026772) and is included in v1.4.1.

Local validation on Swift 6.4 passed all 240 Core tests (239 existing plus the isolated regression) with zero failures/skips, including the original patch-check rejection, and all ten release-tool gates. The regression failed with child exit 13 before the fix and passed afterward. These local results do not replace Swift 6.1.2 CI on the final pushed revision.

### Dashboard visual redesign — v1.4.1

`DashboardView.swift` composes a centered workspace (1320pt content limit), five snapshot-backed metrics, a responsive search/filter/sort toolbar and a lazy repository list. `DashboardRepositoryRow.swift` shares column geometry with the headings; narrow windows put the branch under the name and omit update timestamps. The independent checkbox, worktree disclosure and open button preserve their separate actions. Selection is shown in a reserved footer, including selected entries outside the search/filter results. Failures expose the full redacted diagnostic and a local-refresh action.

`GitPierCore/WorkspaceListing.swift` computes the organization-scoped summary, metadata search, existing AND filters, stable sorting and visible worktree projection once per Dashboard update. Collapsing changes only displayed rows; matching IDs/counts and Select Matches still include hidden worktrees. If filters remove the main worktree, the first matching member remains visible. It introduces no Git queries, persistence or collection/Fetch changes. Dashboard and sidebar share the existing native editor/favorite/organization menu actions.

Run `Scripts/test.sh`, `UNIVERSAL=1 Scripts/build-app.sh`, then `Scripts/workspace-acceptance.sh dashboard .cache/dashboard-redesign/final` for the focused native check. It creates eight real disposable entries including three related worktrees, modified/staged/ahead/behind/conflict/no-upstream/missing states. It renders both languages and light/dark appearances at 960×640, 1200×800, 1440×900, 1600×1000 and 1920×1080, with separate selection/collapse/error/empty/scanning captures and native interaction checks. `GITPIER_DASHBOARD_INTERACTIVE=1` leaves this isolated window open until its output directory contains `finish-gui`, for physical mouse/keyboard inspection. Use `workspace-acceptance.sh full` for the complete native UI/PTY suite, and `workspace-acceptance.sh workspace-performance` for 10/50/100-repository checks. Keep GUI runs serial. The wrapper copies the app to a unique runtime identity, re-signs it and removes only its own preferences/copy on exit; it cannot start production updating. No version change or publication is part of this redesign.

Local validation on 2026-10-15 passed 245 Core tests (including five new listing regressions) with zero failures/skips, ten release-tool gates, the focused Dashboard suite and the complete native UI/PTY suite through a separately identified Universal Release copy. Thirty native fixture screenshots cover the five sizes, both languages/appearances and selection/conflict/unavailable/worktree/empty/scanning states. CUA additionally checked actual keyboard search, independent selection, retained selections outside results, sorting, reviewed Fetch/cancel, empty organization, Clone access, native Favorite count updates and wheel scrolling to the last row. The column heading is pinned inside the same scroll layout as rows; horizontal content margins are zero, and its opaque background prevents scrolling text from bleeding through.

The 10/50/100-physical-repository Release checks (plus one linked Worktree and two unavailable entries) recorded readiness of 232.27/421.57/635.33 ms and scans of 587.73/1735.52/2835.01 ms. Direct Git peak remained three and full repository-session refreshes remained zero. These are single samples in a warmed process with empty per-case caches, excluding fixture/process launch; they do not establish a percentage improvement. The Universal slices, deep bundle signatures and final temporary DMG structure passed. Physical drag attempts did not trigger in either Dashboard or the existing sidebar, so physical dragging remains for manual confirmation; shared drag/drop code is unchanged and order/persistence regressions passed. The Dashboard changes, including the final path spacing, subsequently passed [same-commit CI](https://github.com/Heisenberg2024/gitpier/actions/runs/38714258115) at `033d054`. Intel/macOS 14 hardware runs remain unverified. Version 1.4.1 uses build 21 and the existing production identity, update key and feed; publication requires the complete release revision to pass CI.

### Automatic remote checks — v1.4.2

Released [v1.4.2](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.4.2) uses build 22. Automatic checks default off, independent of local file watching. The selected repository uses 10/15/30/60 minutes (15 by default); other workspace repositories use 45 minutes, with at most two Fetches and 30-second workspace admission spacing. Startup/foreground/navigation only request an eligibility evaluation. Failures use 5/10/20/40/60-minute backoff while respecting a recent successful check; authentication requires manual recovery. The scheduler uses monotonic deadlines in-process and versioned, atomically written metadata across restarts.

Fetch targets retain the existing common-directory/remote/full-config/effective-URL/filesystem identity. Automatic Fetch allows standard tracking refspecs only, skips Mirror, foreign VCS/upload-pack helpers and custom SSH commands, and forbids tags, Prune, recursive submodule fetching, automatic maintenance and interactive terminal/browser login. GitPier-owned Keychain reads prohibit background interaction; recognized native osxkeychain/gh helpers retain their original OS permission behavior. HTTP remotes use protocol-specific native credentials and show an unencrypted-transport warning. Native manual Fetch keeps its original command semantics; metadata excludes remotes skipped by either `skipFetchAll` or `skipDefaultUpdate`. Neither failed nor cancelled checks erase previous tracking counts. Running cancellations refresh snapshots because Git may already have committed refs before cancellation.

Local snapshot collection time and remote success/attempt/eligibility time are distinct. Per-attempt and snapshot uptimes reject older completions and cached data. Automatic tracking refreshes preserve drafts, Diff tabs, selection, history and Worktree pages; busy sessions keep the newest pending tracking snapshot. Zero/zero is described literally as matching tracking references, with a separate remote-check state/time, since a custom manual refspec may not cover every upstream.

Run the following against disposable fixtures, keeping GUI runs serial:

```sh
Scripts/test.sh
python3 Scripts/test-release-tools.py
UNIVERSAL=1 Scripts/build-app.sh
Scripts/workspace-acceptance.sh version142 .cache/v142/remote-checks
Scripts/workspace-acceptance.sh full .cache/v142/full
Scripts/workspace-acceptance.sh version140 .cache/v142/workspace
Scripts/workspace-acceptance.sh dashboard .cache/v142/dashboard
Scripts/workspace-acceptance.sh workspace-performance .cache/v142/performance
Scripts/test-dmg-structure.sh
```

The 1.4.2 scope exercises native tri-state selection, partial queue acceptance/cancellation, real local-bare automatic Fetch and Worktree deduplication, enabled restart without duplicate Fetch, corrupt metadata preservation, a committed reference-transaction Hook cancelled after refs changed, timestamp/result ordering, toolbar running/disabled/count/divergence/no-upstream states, failure retention/backoff and shared metadata removal. It captures English/Chinese and light/dark layouts at 960/1440 widths plus Git settings.

When macOS foreground activation or other desktop work interrupts the opt-in network check, use a fresh output directory and `GITPIER_UI_ACCEPTANCE_INTERACTIVE_FOREGROUND=1`. The fixture pauses at `ready-automatic` and `ready-cancellation`; physically click only the uniquely identified disposable test window, then create the corresponding `continue-automatic` / `continue-cancellation` file in that output directory. This does not bypass `NSApp.isActive` or scheduling/backoff. Never operate the normal production GitPier window. Disabled SwiftUI buttons may be absent from AX: the running capture and absence of an enabled Fetch action are the acceptance criteria.

Final local validation passed 276 Core tests (all 245 existing cases plus 31 new cases), with zero failures/skips, and all ten release-tool gates. The final Universal Release app passed both architectures, embedded Sparkle helpers and deep signatures. Separately identified copies passed the complete native UI/PTY regression, v1.4 workspace scope, Dashboard scope and v1.4.2 scope. The latter produced 24 captures; actual CUA activation verified both foreground checks, and native interaction verified mixed/all/none selection. Dashboard regression produced 30 captures across both languages/appearances and five window sizes. All remote fixtures were disposable local bare repositories or controlled transports; no repeated requests used real GitHub repositories or accounts.

Release measurements used Apple silicon, 14 logical CPUs, macOS 27.0.1 and one sample per case. Each case contained the specified physical repositories, one linked Worktree and two unavailable entries; every clone had 1,000 commits and one repository had 10,000 untracked files. Readiness uses an empty per-case store/cache in a warmed visible process and excludes fixture creation and process launch.

| Physical repositories / entries | Dashboard ready (ms) | Local scan (ms) | Refresh (ms) | Initial Git launches / peak | Full session refreshes | Peak process RSS (MiB) | Heartbeat excess p95 / max (ms) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10 / 13 | 231.42 | 913.82 | 732.62 | 137 / 3 | 0 | 197.84 | 12.08 / 37.21 |
| 50 / 53 | 415.24 | 2662.77 | 2418.60 | 657 / 3 | 0 | 226.72 | 12.33 / 85.90 |
| 100 / 103 | 642.41 | 5329.82 | 4373.29 | 1307 / 3 | 0 | 254.92 | 12.85 / 110.90 |

Local scans include additional local upstream/configuration identity queries when an upstream exists; no-upstream repositories retain the existing six-query budget. No scan activated a full RepositoryModel session or calculated Diff/history. Unavailable entries remained isolated. Explicit missing-remote Fetch failed independently in 114.01/87.16/66.23 ms. Automatic checks were off during performance scans; the v1.4.2 network trace separately verified zero Fetch before opt-in, one Fetch for two shared Worktrees, no repeat on rapid lifecycle events or enabled reopen, and preserved failure backoff. Process counts cover direct Git launches, not internally launched helpers; RSS is cumulative process high water. These samples do not establish a percentage improvement.

The final development bundle passed the temporary DMG structural/signature test. Production Bundle ID, macOS 14 minimum, Sparkle feed and EdDSA public key match the v1.4.1 baseline. This local checkpoint preceded the CI and publication checks below. Intel/macOS 14 device acceptance, real private-server authentication, new Finder drag installation, production self-update and Gatekeeper/notarization acceptance remain unverified. Developer ID signing and notarization were not requested.

### v1.4.2 release validation — 2026-10-16

[v1.4.2](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.4.2) was published as Latest at 01:28:44 Asia/Shanghai after owner approval of the exact English-first bilingual notes. The tag, approved source and Universal DMG correspond to `4d613dc8ff2fb77e651a15e5f35cfe58d78d1dda`. [Same-commit CI](https://github.com/Heisenberg2024/gitpier/actions/runs/38772270746) passed all 276 Core tests with zero failures/skips and ten release-tool gates on Swift 6.1.2, followed by bundle, temporary DMG, archive and upload checks.

The local release pipeline reran all 276 Core tests with zero failures/skips, built both architectures, verified embedded Sparkle helpers and deep signatures, and produced the final HFS+/ULFO installer. All 188 tracked inputs matched the approved commit before post-release documentation updates; all 147 build/resource/tool inputs remain frozen. The mounted app's 109 files/links and permissions matched the built bundle. Actual normal Finder opening confirmed the real application icon, Applications link, background, arrow and bilingual instructions. The existing same-source native UI/PTY, workspace, Dashboard, v1.4.2 and performance evidence was retained; those suites were not repeated during release preparation. The DMG is 14,640,338 bytes with SHA256 `3d112041468ff39fcc2980b2d9f8a83fb64ef5b1d791a1bd12915b4b1192d941`.

The existing production Keychain key signed the DMG and Feed without export or replacement. The approved notes match the public Release and signed Feed byte-for-byte; equal-length altered DMG and Feed copies were rejected. Draft attachments were downloaded and verified before publication. After publication, all three public attachments and the canonical Latest Feed returned HTTP 200 and matched the local sizes, hashes and signatures; Latest and tag SHA were verified again. All nine historical releases, 23 historical assets, prior tags and 25 local historical assets/feed files were preserved. The installed v1.4.1 application, preferences, workspace and global Git/SSH/shell configuration were unchanged, and task mounts/windows were cleaned. Intel/macOS 14 hardware, real private-server authentication, new drag installation, production self-update installation and Gatekeeper quarantine were not newly tested. Developer ID signing and Apple notarization remain absent.

### CI cancellation test ordering — after v1.4.2

The [v1.4.2 tag run](https://github.com/Heisenberg2024/gitpier/actions/runs/38777670074) later failed one of the 276 Core tests, despite using the same `4d613dc` source as the successful main run above. `testManualAdmissionCancelsAutomaticAndBlocksFurtherAutomaticWork` created an unstructured Task for manual admission and immediately released the held automatic executor. Task creation does not establish admission order: the automatic Fetch can finish successfully before the manual operation starts. The test incorrectly required cancellation for that valid ordering. A controlled admission gate reproduced the exact `succeeded` versus `cancelled` failure locally.

The cancellation regression now observes an XCTest cancellation expectation before releasing the fake transport, with 128 handoffs per run and a bounded expectation timeout. A separate regression covers an automatic Fetch that completed before manual admission and verifies admission resumes when the manual session ends. The adjacent duplicate-submission/retry test holds both workers through duplicate admission and drains explicit batches, replacing its assumption that a 15 ms executor delay keeps jobs active. Production coordinator behavior and the published v1.4.2 tag/assets remain unchanged. Use `Scripts/test.sh --filter WorkspaceFetchTests` for the focused suite; new source still requires its own Swift 6.1 CI after an authorized push.

Local repair verification passed all 277 Core tests with zero failures/skips, all 25 focused Fetch cases and ten release-tool gates. The original cancellation assertion remains strict for in-flight jobs; every full run now includes 128 explicitly ordered handoffs. Documentation links/anchors and diff checks also passed. Application/build inputs and released assets were unchanged, so no new application build or release was needed for this test/documentation repair.

### Automatic Fetch legacy-Keychain authorization — v1.4.3

v1.4.2's background helper set `kSecUseAuthenticationUIFail`, but the traditional file-based login Keychain can still request authorization through its legacy ACL path. Apple's [Mac keychain implementation note](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains) distinguishes that implementation from the data protection Keychain. Per-query authentication options alone do not establish a no-UI boundary for existing login-Keychain credentials.

Dedicated helper processes now call [SecKeychainSetUserInteractionAllowed](https://developer.apple.com/documentation/security/seckeychainsetuserinteractionallowed(_:)) with `false` before reading credentials, and verify the resulting policy. The generic-profile and Internet Password accessors reject background requests without preparation. Background invocations cannot fall through to AppKit Askpass. The GUI process never changes this process-wide policy; manual authentication retains its existing behavior. Automatic SSH also disables `UseKeychain`, since exec of SSH creates a new process image; already-loaded agent identities remain usable. Credentials that require approval produce Authentication Required and pause automatic attempts instead of prompting repeatedly.

Keychain regressions run in isolated XCTest children and create only random synthetic credentials. An empty trusted-application ACL requires authorization and verifies that repeated Internet/generic secret reads are denied without UI; authorized same-process fixtures retain type/host/port matching. CLI entry checks use a nonexistent host and an empty temporary configuration. They verify that background credential commands exit without opening Askpass. The tests do not change real credential ACLs, migrate existing Keychain items or exercise private servers. Test fixtures do not replace existing installations; v1.4.2 users seeing repeated dialogs can update to v1.4.3 before re-enabling Automatic Fetch.

Source-fix validation passed 280 Core tests with zero failures/skips and ten release-tool gates. The final four Keychain/CLI cases also passed separately after tightening child-failure propagation. `Scripts/test.sh` compiled the application executable used for CLI acceptance; that stage did not install a GUI app or produce a release package. A discarded cross-application ACL fixture was cleaned by exact synthetic item references and rechecked absent; the final tests use only same-process authorized items, explicit denied ACLs and credential-free CLI probes. Documentation links/anchors and diff checks passed. Implementation CI and later candidate packaging are recorded below; an installed-app upgrade remains unverified.

### v1.4.3 release validation — 2026-10-16

The implementation commit `a2160bf6b029f810be8429b543fe9a5a45d0d4ac` passed [CI](https://github.com/Heisenberg2024/gitpier/actions/runs/38788886574) on Swift 6.1.2: all 280 Core tests with zero failures/skips, ten release-tool gates, application build, temporary DMG, archive and upload. That commit still declared 1.4.2 (22). The new release configuration is 1.4.3 (23), retaining the production Bundle ID, macOS 14 minimum, Feed and EdDSA public key.

Local `Scripts/package-release.sh --unsigned-candidate` passed all 280 Core tests with zero failures/skips, the Universal arm64/x86_64 build, deep bundle-signature checks and the HFS+/ULFO DMG checks. Ten release-tool gates passed separately. All 109 mounted application files, links and modes matched `dist/GitPier.app`; the packaged executable passed credential-free background-helper and Askpass-refusal probes. `Scripts/workspace-acceptance.sh full` passed the complete isolated native UI/PTY suite with 104 screenshots. Normal Finder opening showed the saved icon layout, application icon, Applications link, background arrow and bilingual install text. The task's windows and mounts were cleaned afterward.

The published Universal DMG is 14,641,976 bytes, SHA256 `de3251e01146f37dba4a6aebda93dcf613f4e35d23ed7425826a8effb1a1b893`. Its 147 source/resource/build inputs remain frozen. The existing production Keychain key signed the final DMG and Feed; no key was exported or replaced. Intel/macOS 14 hardware, private-server authentication, actual drag installation, Gatekeeper and a production update installation were not newly tested. Developer ID signing and notarization remain unavailable.

[v1.4.3](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.4.3) was published as Latest at 03:48:28 Asia/Shanghai after owner approval of the exact English-first bilingual notes. The tag and Universal DMG correspond to release commit `04d05847a052ae8a048bf7a21cb4b199a50a912e`, whose [same-commit CI](https://github.com/Heisenberg2024/gitpier/actions/runs/38795008167) passed all 280 Core tests with zero failures/skips, ten release-tool gates, application build, temporary DMG, archive and upload on Swift 6.1.2. All 188 committed inputs matched the verified candidate before these post-release documentation updates; the 147 build/resource/tool inputs remain frozen.

The Draft body and three attachments were downloaded and verified before publication. Public Release/Latest, tag SHA, three HTTP 200 downloads, hashes, DMG/Feed signatures and the canonical Latest Feed were verified afterward; the approved notes match the public body and embedded Feed byte for byte. Equal-length tampered DMG and Feed were rejected. Ten historical releases, 26 remote assets, ten tags, 27 local historical files and the production application/preferences/workspace/global configuration remained unchanged. Release validation did not install the update into the production application.

<a id="v144-authentication-development"></a>
### v1.4.4 authentication development

The development checkpoints below used 1.4.4 (24), retaining the production Bundle ID, minimum system version, Feed, EdDSA public key and existing dependencies. These local checkpoints preceded the formal release recorded in the final release-validation section; historical assets remain unchanged.

The audit reproduced native `git config --get-urlmatch credential.helper` returning only the last helper, and command-line `-c` taking precedence over `GIT_CONFIG_COUNT`. The old automatic path lost helper chains; managed profile command-line helpers were not erased by that environment override. Manual native osxkeychain and the guarded GitPier helper use different executable identities, so native-helper ACL access does not imply GitPier access. v1.4.3's no-UI denial was correct but lacked a foreground authorization and target-specific retry path. AuthenticationRequired also excluded the target permanently, and host-key failures were incorrectly grouped with missing credentials.

The new implementation uses ordered read-only helper projections and native Git credential matching, an explicit current-remote authorization/SSH Prepare flow, and a Retry that resets both clocks and rejects old attempts. A directory URL captured before its directory existed exposed a root-validation equality mismatch in the new fixture; GitService now normalizes the directory flag at initialization as well as the canonical path.

Reproducible commands:

```sh
Scripts/test.sh
UNIVERSAL=1 Scripts/build-app.sh
Scripts/auth-acceptance.sh .cache/v144-auth/native
Scripts/workspace-acceptance.sh full .cache/v144-auth/full-ui
```

The authentication script starts a disposable loopback TLS smart-Git server with a test-only certificate; Git trusts that certificate through repository-local `http.sslCAInfo`. It creates no system trust entry and never disables TLS. The application copy has a unique test Bundle ID, isolated workspace/preferences, and no production update trust. Synthetic Keychain items are random or bound to the temporary server port and are deleted by the fixture. Private SSH keys, sockets and repositories used by tests are disposable; user SSH/Git configuration and real credentials are not modified.

Initial focused validation passed 13 new Core tests plus all four existing background-Keychain regressions, with no failures/skips. The new tests cover first automatic TLS Fetch using an existing store credential without manual Fetch, server rejection without credential erasure, manual transport, ordered helpers/reset/URL/account/path/port/useHttpPath/rewrite/cache, unsupported helper refusal, target-scoped two-clock retry, an isolated agent's preparation/reuse/wrong-identity/restart behavior, and strict alias/port/jump-host configuration. Local readiness is explicitly not treated as server authentication success. Final full/native validation results follow; an initial sandbox Keychain creation failure (OSStatus 100001) is not counted as a pass.

Native foreground ACL approval requires a human to answer macOS's own authorization dialog. Automation must not approve it or choose Always Allow. A synthetic ACL refusal proves the guarded process does not prompt; it does not prove compatibility with every real login-Keychain item or across ad-hoc updates. Existing external agents can survive an application restart; the private agent is process-owned and requires preparation again after normal shutdown. Unknown/OAuth interactive helpers and external ProxyCommand/custom SSH executables remain unsupported automatically. Real private servers, production-ID upgrade ACL behavior, Intel/macOS 14 hardware, Gatekeeper, Finder drag installation and production self-update installation require separate evidence.

Primary implementation references: Git's [credential configuration callback](https://github.com/git/git/blob/master/credential.c), [credential helper contract](https://git-scm.com/docs/gitcredentials), [osxkeychain queries](https://github.com/git/git/blob/master/contrib/credential/osxkeychain/git-credential-osxkeychain.c), and OpenSSH's [jump-host invocation](https://github.com/openssh/openssh-portable/blob/master/ssh.c). The shipped system Git is exercised directly by tests; current upstream source is used to explain, not replace, local behavior.

A final temporary configuration probe proved that `ssh -G -oBatchMode=yes` still executes `Match exec`. Preflight now statically validates bounded regular user/system Include files before launching OpenSSH and refuses external execution conditions, dynamic Include expansion and external command/provider directives. The scan is conservative across other Host blocks too; it does not rewrite user files. A real-process negative test verifies included `Match exec`, `!exec` and `Match=exec` never create their marker. Static Include/Host conditions and the builtin `$SSH_SK_PROVIDER` default remain supported; encrypted-key SSH transport still passes.

#### Final local validation

- Complete Core suite: **298 tests, zero failures/skips**, 185.443 seconds (`Scripts/test.sh`). This retains all 280 v1.4.3 tests and adds 17 authentication tests plus one Internet Password account/path regression. The final five Keychain tests were rerun after strengthening exact fixture cleanup: zero failures/skips, 0.520 seconds. Ten release-tool gates passed.
- Universal Release: **1.4.4 (24), arm64 + x86_64**, nested/deep signature and bundle verification passed. Signature remains ad-hoc; production Bundle ID, minimum macOS 14, Feed and EdDSA public key match the v1.4.3 baseline. No dependencies changed. No new Swift 6.1 CI was run because this task does not push.
- Packaged SSH CLI: a temporary identity/config verified Host Alias, selected identity, custom port, BatchMode, strict host verification and refusal of mismatching profile host/port. Core transport tests additionally used a real isolated sshd and encrypted temporary key: explicit preparation enabled first automatic Fetch without manual Fetch; changed Known Hosts was rejected. Native ProxyJump guard configuration was checked for both hosts; a complete real jump chain and separate jump-host unlock UI were not tested.
- Launch Services native HTTPS: default GitPier Token, an explicit repository profile with **another UUID while the default Token was invalid**, and a system Internet Password each completed automatic Fetch without prior manual Fetch. Retry recovered without altering Index, draft or page. A synthetic empty ACL was denied in background; four English/Chinese × light/dark captures passed. CUA verified real scrolling, the displayed authorization target and confirmation cancellation. Triggering foreground authorization returned to a noninteractive refusal; **persistent human-approved ACL recovery was not established** and is not a pass claim.
- Full native UI/PTY: **104 screenshots**, all gates passed. Only the native acceptance fixture was subsequently strengthened to distinguish the repository UUID from the default; that fixture, packaged SSH check, Universal build and temporary DMG structure were rerun. Product UI and authentication behavior were unchanged by that fixture refinement.
- Final temporary DMG checksum, package resources, Applications link and mounted Universal bundle/signature passed. This is a structural fixture, not a production-signed installer or Finder drag/install acceptance. Test windows, servers, agents, mounts and isolated preferences were cleaned.

A cleanup audit found that the legacy file-based Keychain can return success from a broad `SecItemDelete` while deleting only one match. Tests now retain each exact created identity and assert every deletion. A fresh three-item probe reproduced two survivors after broad deletion and zero after exact deletion. Metadata-only ownership checks identified 38 items created during this goal; the original XCTest client removed exactly those, preserving all 26 pre-existing historical synthetic items by metadata digest. No secret value was requested and no ACL was relaxed. The one-time cleanup entry was removed, the normal five tests rerun, and task-owned Internet items across authentication types, managed generic items and the loopback fixture were verified absent. Historical synthetic items were deliberately left unchanged.

Remaining boundaries: real private accounts/servers and credentials were not exercised or migrated; no production-ID v1.4.3→v1.4.4 installation/ACL transfer, positive persistent macOS approval, Intel/macOS 14 hardware, Gatekeeper quarantine, Finder drag installation, or production self-update installation was performed. External/OAuth helpers, dynamic SSH Includes and external command/provider configurations retain the explicit unsupported automatic status. The private agent has a one-hour key lifetime and is terminated on normal app exit; re-prepare after restarting that private agent. No commit, staging, push, tag or public release was performed.


#### Isolated ad-hoc upgrade result

Using one unique test Bundle ID and the same application path, the real v1.4.3 (23) GUI saved one new synthetic Token. Its packaged background helper read that Token successfully. Replacing the application at that exact path with v1.4.4 (24), signed ad-hoc with the same test ID, returned `requiresForegroundAuthorization` and no secret from the new background helper. No approval was automated. This directly demonstrates that keeping the Bundle ID/path does not guarantee legacy ACL trust across an ad-hoc binary change. The original creator was restored solely to delete its own single synthetic item through its normal Credentials UI; the test bundles, workspace credential and unique preference domain were cleaned. Only booleans were recorded for helper responses, never secret output.

This is an isolated same-ID upgrade, not a production-ID installation or proof about every existing login-Keychain item. Persistent positive human approval, real private accounts, Finder drag installation and actual production self-update remain outside the completed evidence.


### v1.4.4 native GitHub CLI credential reuse

The installed candidate rejected the standard URL-scoped empty reset followed by `!/opt/homebrew/bin/gh auth git-credential`. An initial adapter changed the Keychain caller from the original system tool to GitPier, introducing a new access requirement. The owner explicitly selected direct reuse of the original helper, accepting necessary native macOS authorization windows. That supersedes the earlier blanket no-system-UI requirement for recognized native gh and osxkeychain paths.

Automatic Fetch now uses the same gh executable, account/config matching and native Keychain client as manual Fetch. It runs get only, preserves Git helper ordering and URL-specific resets, and disables terminal/browser login and update notifications. GitPier does not decode/copy gh items or request an additional Keychain grant. Unknown shell helpers remain blocked; GitPier-owned credential readers retain their no-UI policy. Native Keychain authorization can appear if the original helper itself requires permission; terminal noninteractive flags do not suppress that OS dialog. Cancellation/rejection pauses the target.

The optional opaque `RemoteCheckRecord.helperCompatibilityVersion` preserves metadata schema version 1. Policy version 2 reevaluates older UnsupportedHelper/RequiresForegroundAuthorization blocks and transport skips once after helper support changes, while retaining ownership, last success/attempt and normal intervals. New failures and AccessDenied/ServerRejected/CredentialMissing are not cleared repeatedly at startup. There is no blanket retry loop.

The earlier GH-only suite included **26 authentication cases**. The new TLS regression creates one synthetic Token through the original `/usr/bin/security` itself, with its native default permissions, without giving GitPier access; its first automatic Fetch succeeds without a prior manual Fetch. Invalid-Token rejection retains the item. A migration regression verifies preserved success history and no repeated retry of new failures. The bounded asynchronous TLS fixture cleanup avoids Process.waitUntilExit on the cooperative executor. Creating the item from XCTest with a cross-program trusted list did not reliably model native security permissions and caused a 15-second timeout in a full run; using security as the actual creator/reader/updater/deleter passed the focused regression in 1.633 seconds. Synthetic secrets are supplied only over stdin, with no -U on creation and exact service/account cleanup. The final full-suite result below uses this corrected fixture.

A one-time read-only diagnostic exercised the complete automatic credential-capability path against the owner's real repository configuration, with all Token environment variables cleared and the GitPier helper executable deliberately nonexistent. It returned **ready / githubCLI** in 0.279 seconds, without Fetch, new authorization or secret logging/persistence. The diagnostic source was removed from Tests after recording evidence; it is not part of the committed test suite. This verifies local credential availability, not private-server access or all future OS permission states.

The previous signed 41b8e67 and separate-reader candidate-2 assets are retained as superseded evidence. They must not be used to ship this direct-reuse implementation. Current evidence is under `.cache/v144-gh-helper/native-reuse`; a new exact-commit Swift 6.1 CI result and formal signing remain required before public release.

The earlier GH-only `Scripts/test.sh` passed **302 tests, zero failures/skips (189.539 seconds)**, after correcting the native creator fixture. All **10 release-tool gates** passed. No temporary real-configuration diagnostic remains in the test target.

Final Universal 1.4.4 (24), nested/deep signatures, packaged CLI guards and the HFS+/ULFO DMG passed. All **109 mounted file/link/mode entries** match dist. Finder normally opened the final DMG with the expected icon view, Applications link, arrow and bilingual background after restoring its public volume name; task windows/mounts were cleaned. The earlier GH-only installer (superseded by the follow-up below) is `.cache/v144-gh-helper/native-reuse/candidate-4/GitPier-1.4.4-macos-universal.dmg`, **14,954,027 bytes**, SHA256 `8f7486c4cc05990321bce19f955efc8092ffc9b972457a9df3532b646bca56b0`. It has no new signed update Feed and has not replaced the user's installation.

Packaging exposed ambiguous Finder disk lookup while older GitPier installers were mounted. `package-dmg.sh` now lays out a unique temporary volume, restores the public GitPier name, then revalidates the exact backing-image identity and device before detach. It accepts partition-first hdiutil metadata and preserves the task directory if detach cannot be confirmed. The prior user installer remained at its original mount through the final run and cleanup. `bash -n`, the ten release gates and actual same-name-volume packaging passed; no existing user volume is selected by its name for modification.

Primary references: [GitHub CLI credential protocol](https://github.com/cli/cli/blob/v2.101.0/pkg/cmd/auth/gitcredential/helper.go), [native macOS Keyring implementation](https://github.com/cli/cli/blob/v2.101.0/docs/macos-keyring.md), and [terminal prompt controls](https://cli.github.com/manual/gh_help_environment).


### v1.4.4 native osxkeychain and HTTP follow-up

Read-only inspection of the owner's eleven registered repositories found three GitHub CLI configurations, five other HTTPS remotes and three HTTP remotes using native osxkeychain, without any GitPier CredentialProfile. The remaining HTTPS failures came from replacing osxkeychain with GitPier's independently authorized reader. The selected Git installation's original helper now handles get itself, retaining its executable identity and existing permissions. No user configuration, credential, or ACL is changed. Native permission UI remains permitted by the owner's direct-reuse choice; managed GitPier readers still prohibit background UI.

The owner separately approved existing HTTP-address support after the unencrypted credential/data consequence was explained. HTTP uses the same ordered get-only helper projection and Git protocol matching, with accurate HTTP transport labels and an English/Chinese warning. It does not borrow HTTPS-only managed Tokens or change remote URLs. Policy version 2 reevaluates old transport skips and alternate-reader authorization blocks once, preserving success history and actual rejection/cancellation.

A temporary diagnostic used the real configurations with all GitHub Token environment variables empty and the GitPier reader path deliberately absent. All eight HTTPS repositories returned ready (three githubCLI, five systemKeychain) without Fetch or secret logging. The three HTTP configurations returned credentialMissing from the original helper, and a credential-free read-only ls-remote check returned an empty server response. HTTP compatibility is verified by the isolated fixture, not claimed as successful authentication to those real servers. The diagnostic source was removed from the test target.

New loopback HTTPS and HTTP regressions create, read, update and precisely delete their synthetic Internet Password through native osxkeychain itself. First automatic Fetch succeeds without a manual Fetch or GitPier grant, wrong account/path/protocol cannot match, and server rejection does not erase the native item. An initial sandboxed fixture creation was denied and is not counted as passing; the permitted native run passed all three focused tests in 2.673 seconds. The native UI fixture now uses the original helper to create its own item; blocked-ACL UI coverage remains on GitPier-owned managed credentials.

Full follow-up validation passed **304 Core tests, zero failures/skips (198.970 seconds)** and all **10 release-tool gates**. The Universal app passed both architectures and nested/deep signature verification. The first sandboxed icon generation failed; the permitted system packaging run completed successfully from unchanged inputs. The isolated Launch Services authentication run passed default/repository managed credentials, first native-osxkeychain automatic HTTPS Fetch, Retry, unchanged Index/draft/page, managed ACL refusal, and HTTP missing-credential/transport/warning settings. It produced eight English/Chinese light/dark captures; HTTP warning and status text were visually checked. No production installation or real private-server Fetch was performed.

The new local HFS+/ULFO candidate is `.cache/v144-native-helpers/candidate-5/GitPier-1.4.4-macos-universal.dmg`, **14,982,002 bytes**, SHA256 `b1bebd156f05ad3c84d344ad429311981b0132efa2609531e94ac7daecd5f32d`. All **109 file/link/mode entries** match the validated Universal app; 178 source/test/build inputs, 13 user Git configuration files and existing mounted images were unchanged. Temporary test bundles/preferences and task mounts were cleaned. The final candidate's normal Finder-open visual check was not repeated; the packaging implementation's prior same-name-volume visual evidence remains separate. No signed update Feed, same-commit Swift 6.1 CI or public release was created.


### Unified native authentication

The owner expanded the requirement to all native Git transports, hosting platforms, public/private repositories and terminal/GitPier Clone or init/push workflows. This supersedes the old helper whitelist and automatic SSH preflight. Actual Fetch now decides whether credentials are needed; public HTTP/HTTPS no longer fail a password-only probe. Retry admits the same native attempt without asserting local credential or Agent readiness. UI distinguishes this from a successful verified Fetch.

The get-only adapter follows [Git's documented command rules](https://git-scm.com/docs/gitcredentials#_custom_helpers) and preserves partial/OAuth responses rather than decoding a password. Native SSH commands/config/Agent/identities/wallets are unchanged; TLS and host verification are not weakened. Named/absolute/shell helpers, Basic/Bearer credentials, HTTP headers, original URL userinfo and native osxkeychain/gh follow one path, independent of hosting brand. Automatic Git does not store/erase; a helper's own refresh behavior remains native.

[Git's default remote resolution](https://github.com/git/git/blob/master/remote.c) is used when no upstream is configured, with local-only snapshot collection and no ambiguous multi-remote guess. This covers init/push and detached HEAD. Clone records its selected account before automatic admission; a prepared private Agent is scoped to the original repository/authentication identity instead of replacing all inherited agents. GUI helper PATH gains standard Homebrew locations while preserving existing precedence. Temporary terminal-only secrets are not imported and shell startup scripts are not sourced.

New temporary fixtures exercise anonymous HTTP/HTTPS without any helper call, named/absolute/shell/partial/Bearer/header/URL authentication, terminal and GitPierCore clones before their first automatic Fetch, init/push with no upstream, git://, real SSH encrypted-key preparation, file identity without an Agent, SCP syntax, core.sshCommand, GIT_SSH, native Match exec and strict changed-host-key refusal. Index, HEAD, FETCH_HEAD, rejection-without-erase and target identity changes remain covered. Native UI adds AppStore Clone binding before its first automatic job and shows HTTP readiness without claiming an unperformed Fetch. Prior candidate-5 evidence describes the earlier narrow implementation and cannot be used to ship this change.

Final full `Scripts/test.sh` passed **308 tests, zero failures/skips (222.028 seconds)**; all **10 release-tool gates** passed. The new matrix reused a stale port file and mismatched HTTP/HTTPS fixture credentials in earlier runs; those fixture errors were corrected before this full result. Canonical repository aliases are normalized for private-Agent ownership. Native `git://` and SSH changed-host-key refusal passed against temporary real servers. No real hosting account or server was changed.

The final audit also included configured core.askPass, GIT_ASKPASS and SSH_ASKPASS as native credential providers. HTTP tests cover all three precedence paths; the real SSH fixture now succeeds with its original Askpass and encrypted identity before Agent preparation. New terminal/GitPier fallback login is still disabled, and managed background helpers retain their no-UI guard. Earlier UI validation passed before this last native-provider extension; final build/UI verification follows.

The Askpass regression identified an additional product restriction: command-scoped credential.interactive=false prevents Git from calling configured Askpass at all. Automatic Fetch now preserves the user's setting, while GIT_TERMINAL_PROMPT=0 and refusal of the application fallback keep new terminal/GitPier login disabled. Original core.askPass/GIT_ASKPASS/SSH_ASKPASS providers are delegated in native order.

The macOS CI fixtures also support older system Git/helper versions: query `git credential capability` and negotiate `authtype` before emitting Bearer fields, falling back to Basic when unavailable. Older native osxkeychain helpers may ignore `store` for existing entries, so rejection tests replace only their exact synthetic identity and verify its new value before Fetch. The gh fixture trusts only its original `/usr/bin/security` client and checks both native readers before automatic Fetch, without logging credentials. CI records system Git and gh versions alongside Swift.

The isolated gh directory includes `config.yml` with `version: 1`, just like an initialized CLI installation. A hosts-only fixture otherwise enters legacy account migration and can lose its active user when the token is stored in Keychain. This was reproduced with the official CI-version gh 2.100.0 binary and gh 2.101.0; adding the schema version lets both original clients read the same synthetic item. `GITPIER_TEST_GH_EXECUTABLE` selects an older CLI only for integration tests, without replacing the installed executable or changing real gh configuration.

An explicitly selected GitPier HTTPS Token remains exclusive: native Askpass must not substitute another account when that Token cannot be read. A server-challenged negative regression verifies this with a valid original Askpass provider and an unavailable selected Token.

The frozen delivery source passed **308 Core tests, zero failures/skips (222.538 seconds)**, including 22 HTTP/HTTPS provider/isolation combinations. All ten release gates passed. Universal 1.4.4 (24) passed both architectures and nested/deep signature verification. These supersede the earlier 222.028-second and pre-exclusive-Askpass runs; no diagnostic fixture remains in the test target.

Final delivery Launch Services acceptance passed on the frozen Universal bundle: eight English/Chinese light/dark captures, default/repository Token and native osxkeychain first automatic Fetch, managed ACL refusal, Retry, and AppStore Clone with the selected account before first automatic admission. HTTP readiness is displayed without claiming server verification, and its warning was visually checked. The local HFS+/ULFO candidate is `.cache/v144-native-all/candidate-6/GitPier-1.4.4-macos-universal.dmg`, **15,012,558 bytes**, SHA256 `ad8fd1ba60bed6d2f01c17aef186fa9342fa73a5674f2653d3ddc0a6722dc380`. All **109 mounted file/link/mode entries** match dist; 178 frozen inputs, 13 user Git config hashes and existing mounts were unchanged. Test bundles/preferences and task mounts were cleaned. No new signed Feed, same-commit Swift 6.1 CI, production installation or real external-host acceptance was performed; the final DMG normal Finder-open visual check was not repeated.


<a id="v144-release-validation--2026-10-16"></a>
### v1.4.4 release validation — 2026-10-16

[v1.4.4](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.4.4) was published as Latest at **2026-10-16 19:00:58 Asia/Shanghai**, from release commit `971f88b527b4531cfacbe13a6c651c13e058ccd7`. Its [same-commit CI](https://github.com/Heisenberg2024/gitpier/actions/runs/38889068493) passed all **308 Core tests with zero failures/skips**, ten release gates, application build, temporary DMG structure, permission-preserving archive and upload using Swift 6.1.2, system Apple Git 2.39.5 and gh 2.100.0. Earlier development-only checkpoints above are superseded by this release.

The release repairs CI fixture compatibility without changing the validated native authentication implementation: negotiate authtype, replace only fixture-owned native osxkeychain entries before rejection, and initialize the isolated gh schema before reading Keychain credentials. Local full Core validation passed 308 tests (241.805 seconds); the final 27 authentication tests also passed with the official gh 2.100.0 binary (45.093 seconds). All application/resource/build inputs are identical across the final test-only correction and the signed Universal build.

Final Universal **1.4.4 (24)** passed arm64/x86_64, nested/deep signatures, packaged CLI guards, eight native authentication/HTTP settings captures, default/repository Token and original osxkeychain first automatic Fetch, managed ACL refusal, Retry and AppStore Clone binding before its first automatic Fetch. The complete isolated native UI/PTY regression also passed on this final bundle (104 captures). Separate automatic-check acceptance passed Worktree deduplication, cancellation after reference updates, activation/lifecycle, enabled reopen, corrupt metadata and reviewed admission, while preserving Index/drafts/pages. All **109 mounted file/link/mode entries** match dist. The final HFS+/ULFO installer was normally opened in Finder and its default icon layout, Applications link, arrow and bilingual background were visually verified.

The final DMG is **15,012,577 bytes**, SHA256 `55be171b1a60f807b6b1c70e44faf734f02416e92344f467e2a4aa4695e44b5f`. The existing production Keychain key signed the archive and Feed without export or replacement. Both equal-length tampered archive/Feed copies were rejected. The Draft and public assets were downloaded and verified against local hashes/signatures; the exact English-first bilingual notes match the public body and embedded Feed. The tag, Latest release, public release page and canonical Latest Feed were verified after publication.

All 11 historical releases, 29 remote assets, 11 old tags, 95 local historical assets, 19 protected production/configuration paths and existing mounts were preserved. Task-only test bundles/preferences/windows/mounts were cleaned. Evidence is in `.cache/releases/v1.4.4-native-final`; this release does not establish real private-server acceptance, production-ID upgrade/ACL transfer, Intel/macOS 14 hardware, Gatekeeper, actual drag installation or production self-update installation. The application remains ad-hoc signed and not notarized.

## v1.5.0 hosting validation

The maintainer-registered GitHub.com and GitLab.com public Client IDs are bundled in `HostingOAuthConfiguration.json`; see [OAuth setup](oauth-setup.md). Self-hosted IDs belong to their instance. No Client Secret, test token or backend belongs in release configuration. Version candidate is 1.5.0 (25), preserving the existing production Bundle ID/feed/EdDSA public key and macOS 14 requirement.

```bash
Scripts/test.sh --filter HostingTests
Scripts/test.sh
python3 Scripts/test-release-tools.py
UNIVERSAL=1 Scripts/build-app.sh
Scripts/workspace-acceptance.sh hosting .cache/ui-acceptance/v150-verified
Scripts/workspace-acceptance.sh full .cache/ui-acceptance/v150-full
Scripts/package-dmg.sh dist/GitPier.app dist/GitPier-1.5.0-macos-universal.dmg
```

Hosting tests inject synthetic provider responses and exercise actual isolated Keychain items and 127.0.0.1 sockets. Native hosting acceptance uses a disposable identity/workspace, mock OAuth/API, real Local Vault AES files and an injected synthetic Keychain backend, visible bilingual Light/Dark windows at 960×640, 1440×900 and larger sizes, device-code copying, create review without POST and preservation of fixture Index/HEAD/remotes/drafts. GitLab callback success here is simulated: no real system-browser consent or provider registration is asserted. `GITPIER_UI_ACCEPTANCE_INTERACTIVE_HOSTING=1` keeps the fixture visible until `finish-gui` is created in the output folder.

The existing 308 Core and 10 release-tool tests remain required. Earlier implementation baseline (2026-10-17, before registered IDs and the real-browser callback fix): 372 Core tests (the original 308 plus 64 Hosting tests), zero failures/skips, 228.260 seconds; 64 focused Hosting tests also passed in 0.421 seconds, and all 10 release-tool gates passed. That earlier Universal build and deep signatures passed with 162 frozen repository build inputs unchanged; the new IDs and real-browser callback fix require their own subsequent build, recorded below. Native hosting acceptance produced 207 complete system-window screenshots, with visible English/Simplified Chinese, Light/Dark, 960×640, 1440×900 and 1800×1100 content sizes. CUA additionally verified saved/manual binding values across account/Remote changes, explicit suggestions, cancellation/reopening, actual account-list scrolling to the bottom, read-only review controls and preserved creation input after a failed preflight. Full existing native UI/PTY acceptance passed (104 render captures). Hosting evidence is in `.cache/ui-acceptance/v150-verified/`; baseline control/PTY evidence is in `.cache/ui-acceptance/v150-full/`. Earlier layer-cache/partial capture folders are superseded and are not visual acceptance evidence. Real GitHub.com/GitLab.com/self-hosted OAuth, private API permissions, fork creation, actual refresh grants and Keychain ACL after a real ad-hoc upgrade remain deferred. Intel/macOS 14 hardware, Developer ID/notarization and production self-update are separate acceptance boundaries. Do not publish a release or alter historical assets from these commands.

Earlier blank-ID local candidate (preserved; does not include the newly registered public IDs): `dist/GitPier-1.5.0-macos-universal.dmg`, 16,620,515 bytes, SHA256 `c5c1397d78f2f68984b1d3d7aca7a414df181f13804245083bf0e8023cc0d3ff`. HFS+/ULFO structure, Universal app/deep signature, mounted file bytes/links/permissions and Finder icon-view background/icons/arrow/bilingual text were checked; 101 regular packaged files match the build, with the complete path/link/permission set preserved. All 31 pre-existing distribution assets remained byte-identical. The task's read-only mount and disposable GUI fixtures were cleaned up. This candidate has no new production EdDSA feed/signature and was not installed, committed, pushed, tagged or released.


### Real public OAuth acceptance — 2026-10-17

The maintainer-provided GitHub.com and GitLab.com public IDs were embedded and verified in a packaged 1.5.0 (25) application. Real HTTPS provider endpoints, system browser sessions and `GitPier.hosting.oauth` Keychain items were used, with no mock transport or exported tokens. Both accounts resolved to `Heisenberg2024`: GitHub Device Flow returned `read:user`; GitLab public S256 PKCE returned through `gitpier://oauth/gitlab` with `read_user read_api`.

Historical system-session checkpoint (superseded by ordinary-browser callbacks below): the first real GitLab callback exposed a Swift 6 executor assertion: AuthenticationServices invoked the legacy completion on a SafariLaunchAgent XPC queue, but a closure constructed in the MainActor authorization method inherited MainActor isolation. At that checkpoint, `HostingBrowserSession.completionHandler(for:)` constructed a nonisolated `@Sendable` completion and explicitly enters MainActor before accessing session state. A compiled off-main callback probe passed, and native Hosting acceptance included a detached callback regression. The actual GitLab browser authorization was repeated successfully after the fix.

After a normal Quit and restart of the same isolated application, both accounts initially displayed **Verify to Unlock**. Explicit **Verify Connection** restored their existing Keychain tokens, preserved account IDs and read the current-user APIs without another browser login. Read-only repository binding and live API acceptance then passed:

| Provider | Public repository/request | Verified reads |
| --- | --- | --- |
| GitHub | `swiftlang/swift#93347` | 50-item PR page, detail, 3 commits, 23 files and native read-only Diff, exact-SHA CI (3 pending checks) |
| GitLab | `gitlab-org/cli!4118` | 50-item MR page, detail, 1 commit, 5 files and native read-only Diff, approvals/discussions, exact-SHA Pipeline `2949086587` (success) |

The final Universal build, both architectures and deep signatures passed. Its arm64 executable matches the real-tested application after removing signatures from comparison copies. The 64 Hosting tests passed with zero failures (0.463 seconds), and all 10 release-tool gates passed. Source/resource changes supersede the earlier 162-input frozen package record. The existing blank-ID DMG was preserved; the updated application is `dist/GitPier.app` and no new installer or release was produced.

Local evidence (public metadata, native AX snapshots and screenshots; no tokens) is in `.cache/oauth-live/evidence.json` and adjacent files. The stable isolated application and workspace are retained there with their account metadata; actual tokens remain only in Keychain. The production workspace/installation was not migrated. Public read access and restart recovery are established; self-hosted providers, private repositories, write grants/creation, actual token-expiry refresh, post-upgrade ACL prompts and Intel/macOS 14 hardware are still separate acceptance boundaries.


Settings ordering convention: **About stays rightmost**. Insert future Settings tabs before About and preserve existing selection IDs (About remains tag 7; Code Hosting remains tag 8). Hosting card artwork is bundled from official sources listed in `THIRD_PARTY_NOTICES.md`, preserving platform colors and GitHub black/white theme variants. Scrollable hosting forms reserve 6 pt around content for native focus rings. Native hosting fixtures inject the browser opener so automatic Device Flow navigation never opens a real authorization page during synthetic tests.


### Hosting settings UI acceptance — 2026-10-17

`GITPIER_UI_ACCEPTANCE_INTERACTIVE_HOSTING=1 GITPIER_UI_ACCEPTANCE_INTERACTIVE_HOSTING_PAGE=accounts Scripts/workspace-acceptance.sh hosting .cache/ui-acceptance/v150-hosting-ui-fixes` passed on the updated native application: **231 system-window captures**, English/Simplified Chinese, Light/Dark and 960/1440/1800 content widths. It verifies official logo loading, a single automatic GitHub verification-URL open through the injected opener, device-code copying, mock callback/creation and unchanged fixture Index/HEAD/remotes/draft. The callback's off-main regression also runs before the matrix.

CUA clicked the blank lower-right area of each provider card and verified the corresponding connection sheet. Actual focused Gitea instance URL, GitLab Client ID/fixed-loopback port and PAT secure fields retained complete left/right native focus rings. The native Settings toolbar places About after Code Hosting while preserving tags 7/8. Connection and request-creation scroll content reserve focus-ring space.

A separate normal application with an isolated empty workspace verified real browser navigation: clicking Authorize with GitHub automatically opened `https://github.com/login/device` (then GitHub's account picker) without clicking Open GitHub. GitLab requested a normal browser session; after the one-time macOS website-login confirmation, an ordinary Chrome window reused the existing GitLab login and showed the OAuth approval page. These navigation checks stopped before granting OAuth again; earlier complete real-provider acceptance remains recorded above. The API URLSession remains ephemeral and does not share browser cookies.

Both native and Universal builds/deep signatures passed. Evidence is in the matrix's `hosting-results.json`, `cua-results.json`, native screenshots and redacted browser AX snapshots. Disposable UI/browser applications, temporary workspace data and preference domains were removed. Existing installation/accounts and historical installers were retained. `dist/GitPier.app` contains these changes; the earlier DMG was not regenerated.


### GitLab ordinary-browser callback acceptance — 2026-10-17

This supersedes the ASWebAuthenticationSession checkpoints above. GitLab opens through `NSWorkspace` in the default browser, and the running application's AppDelegate forwards `gitpier://oauth/gitlab` to `OAuthBrowserCallback`. There is no system web-authentication session, so the repeated macOS website-sharing dialog and dedicated authentication window are avoided. The browser's ordinary tab/window policy is preserved; GitPier does not resize another application's windows, change its preferences or alter the system URL handler. Valid callbacks return focus to the original GitPier window.

`Scripts/test.sh --filter HostingTests` passed **73 tests, zero failures (0.704 seconds)**: the existing 64 plus 9 callback receiver cases covering early delivery, invalid/oversized/token-bearing/foreign callbacks, provider denial, duplicate/concurrent delivery, cancellation, timeout/expiry and previous-session state. The original PKCE exchange/replay and token lifecycle tests remain in the suite. All 10 release-tool gates passed.

`Scripts/workspace-acceptance.sh hosting-browser .cache/ui-acceptance/gitlab-standard-browser/native-delivery` passed. It sends real Get URL AppleEvents to the disposable process itself, exercising AppKit -> AppDelegate -> active receiver -> mock OAuth exchange/current-user validation, with wrong-state and duplicate rejection. Its AppDelegate must be installed before `NSApp.run()`: AppKit installs URL-event routing during launch; the earlier late-delegate fixture timed out and is superseded. This native acceptance changes no default handler and uses an in-memory vault. The broader `hosting` fixture also uses the ordinary-browser receiver; prior 231 layout captures remain the unchanged layout checkpoint.

CUA opened real GitLab.com authorization twice from a separate empty-workspace application. Both attempts went directly to a new ordinary tab beside the existing tabs in the same Chrome window, reused the existing GitLab login and displayed no ASWebAuthenticationSession sharing prompt. Both flows were cancelled before approving OAuth again. The installed URL handler remained `/Applications/GitPier.app`; the new private-scheme callback was validated with the native process-targeted event instead of sending a real code to the unchanged installed application. A new complete public-provider grant/return was not repeated in this checkpoint. Browser permission to open GitPier on return may still require a user confirmation; this is separate from the removed system sharing prompt.

Evidence is in `.cache/ui-acceptance/gitlab-standard-browser/` (`browser-results.json`, redacted browser AX snapshot and `native-delivery/hosting-browser-results.json`) and `.cache/gitlab-*` logs. Disposable browser/UI apps, workspaces and preference domains were cleaned; historical installers and the installed application were retained. The updated build is `dist/GitPier.app`. For ordinary-browser callback delivery, install the updated build at the existing registered GitPier path; do not change the user's URL handler or OAuth registration just to test a development copy.

Final delivery check for this callback change: Universal 1.5.0 (25), arm64/x86_64 and deep signatures passed. The guarded final bundle repeated native Get URL acceptance successfully. A production-identity invocation of the fixture exits before AppStore/delegate startup. The installed default URL handler remained unchanged.


### Dual credential storage validation — 2026-10-17

New OAuth/PAT accounts default to Local Encrypted Vault; legacy accounts retain Keychain. Each account persists its own mode in v2 hosting metadata. Changing the global default or reconnecting an existing user from the new-account entry never migrates that account. Only an explicitly reviewed per-account change/reauthorization can switch storage. See [storage, security and migration](credential-storage.md).

The final complete Core suite passed **424 tests, zero failures/skips (237.593 seconds)**. The final focused suite passed **116 Hosting tests (73 existing + 43 new), zero failures/skips (0.836 seconds)**; all ten release-tool tests passed. The new xcrun/xctest process restores real encrypted local files, actual isolated Keychain items and a migrated account, then the parent precisely deletes both synthetic Keychain items and verifies absence. Coverage includes tag/key/AAD tampering, private permissions/link refusal, crash checkpoints, key rotation, all three providers and both refresh backends, per-account concurrency, migration rollback/cancellation, deferred cleanup, session-only persistence failure from the initial journal through metadata commit, and stale/foreign OAuth context rejection. Cancelling reauthorization never replaces the original session.

Final Universal **1.5.0 (25)** passed arm64/x86_64 and deep signatures. Production Bundle ID, macOS 14 minimum, Sparkle feed/public key and existing public Client IDs remain intact. The delivered application is `dist/GitPier.app`; existing DMGs were preserved. Build source/resource/test fingerprints were checked after packaging. Local compiler: Apple Swift 6.4.

The full hosting layout/flow checkpoint produced **262 system-window captures**. After the duplicate-connection compatibility correction, the final focused native run produced **22 English/Simplified Chinese, Light/Dark captures** and confirmed both migration directions, stable bindings, local PAT without OAuth Keychain reads, retained session/recovery markers after denied persistence, explicit previous-copy cleanup and unchanged existing modes on duplicate connection. CUA additionally used the actual default popup, scrolled to the last account/footer, cancelled migration, confirmed both directions and postponed old-copy cleanup. The final existing **native UI/PTY suite passed (104 captures)**. Native Get URL AppleEvent/AppDelegate/state-bound receiver/mock exchange and duplicate rejection passed again. No real provider authorization was repeated in these storage checks.

```bash
Scripts/test.sh
Scripts/test.sh --filter 'Hosting(Credential)?Tests'
python3 Scripts/test-release-tools.py
UNIVERSAL=1 Scripts/build-app.sh
Scripts/workspace-acceptance.sh hosting .cache/ui-acceptance/v150-dual-final
GITPIER_HOSTING_STORAGE_ONLY=1 Scripts/workspace-acceptance.sh hosting .cache/ui-acceptance/v150-dual-delivery
Scripts/workspace-acceptance.sh full .cache/ui-acceptance/v150-dual-complete
Scripts/workspace-acceptance.sh hosting-browser .cache/ui-acceptance/v150-dual-callback-verified
```

Evidence is under the named `.cache/ui-acceptance/` directories and `.cache/dual-*` logs. Test applications, preference domains and temporary credential directories were removed through the disposable workflow. This does not establish a new real-platform Local Vault OAuth grant, real server expiry rotation/private writes, ad-hoc production-upgrade authorization, Intel/macOS 14 hardware, same-commit Swift 6.1 CI or a production update installation. Keychain continues to follow macOS authorization; local key plus ciphertext disclosure permits recovery, and ordinary SSD deletion is not secure physical erasure. No repository commit, push, tag, release, production key change or historical installer replacement was performed.


### v1.5.0 release preparation — 2026-10-17

The owner committed the implementation as `0f07e5659f089102b9ba10448b88e42af89a97ba` (the implementation checkpoint before the release documentation commit). [Same-commit CI run 38998495004](https://github.com/Heisenberg2024/gitpier/actions/runs/38998495004) passed on Swift 6.1.2: 424 Core tests with zero failures/skips (473.506 seconds), ten release-tool gates, application build, temporary DMG structure and permission-preserving artifact upload. This established CI compatibility for the implementation checkpoint. The release-document commit and its main/tag CI were subsequently completed as recorded below.

Both READMEs now introduce v1.2.0, v1.3.0, v1.4.0 and v1.5.0 in ascending order; within the v1.4 overview, v1.4.3 precedes v1.4.4. The v1.5.0 Changelog is dated 2026-10-17 and the hosting, OAuth and credential-storage documentation headings no longer use Unreleased. At this preparation checkpoint, English-first bilingual release notes were a local draft awaiting owner confirmation, with no internal testing section.

The existing verified Universal 1.5.0 (25) app was reused: all 149 tracked files in its frozen source/resource/test/package input set match HEAD; the three remaining frozen entries are ignored Finder/Python cache metadata. No application source, production public IDs, update identity or dependency changed during this preparation. Ten local release-tool tests, README order/relative links and diff checks passed. The new candidate is in `.cache/releases/v1.5.0/prepare-20261017-114553/`, with **17,137,747 bytes**, SHA256 `76ccd5acb6dae7a75d1651afc6940572785c048ec3e177ddd5e361f16960660c`.

The final HFS+/ULFO DMG passed Universal/deep signatures, all 105 packaged regular files plus the complete link/permission inventory against dist, normal Finder-open icon view/background/arrow/bilingual text, and production EdDSA archive/feed signatures. Embedded notes match the draft byte-for-byte; equal-length archive/feed tampering is rejected. Existing production signing material was used without export or replacement. The 34 prior local distribution assets remain byte-identical; existing releases/tags were recorded and left unchanged. Two task-owned mounts and the task's Finder windows were cleaned; no app launch, drag installation or production update was performed. The existing `gitpier://` handler still resolves to `/Applications/GitPier.app`.

This preparation was subsequently published after the owner approved the notes and release. See the completed publication record below; the preparation checkpoint is retained as historical evidence.


### v1.5.0 published — 2026-10-17

[GitPier v1.5.0](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.5.0), build 25, was published as Latest at **2026-10-17 12:16:09 Asia/Shanghai**, Release ID `415571997`. Tag `v1.5.0` targets `01848fec98265712e2cff47a7a1517f5eecbf430`, including the implementation and release documentation. [Main CI 39000949146](https://github.com/Heisenberg2024/gitpier/actions/runs/39000949146) and [tag CI 39000952115](https://github.com/Heisenberg2024/gitpier/actions/runs/39000952115) succeeded; main CI ran 424 Core tests with zero failures/skips on Swift 6.1.2, all ten release-tool gates, application build, temporary DMG verification and artifact upload.

The approved English-first bilingual notes and three attachments were uploaded to Draft and downloaded for readback before publication. Public attachment and canonical Latest Feed checks passed after publication. The released Universal DMG is **17,137,747 bytes**, SHA256 `76ccd5acb6dae7a75d1651afc6940572785c048ec3e177ddd5e361f16960660c`; the production EdDSA archive/feed checks and equal-length tamper rejection passed without exporting signing material. All 105 packaged regular files and the complete links/permissions inventory matched the frozen application. Finder layout/background/icons/bilingual text were visually checked; task-owned mounts/windows were cleaned. Historical releases, tags and local distribution assets were preserved.

This release did not establish a new real-platform Local Vault OAuth grant, private writes, actual refresh-token expiry, Intel/macOS 14 hardware, Developer ID/notarization or production update installation. Historical real Keychain-based GitHub/GitLab acceptance and simulated dual-storage acceptance remain distinguished above. Publication evidence is retained locally in `.cache/releases/v1.5.0/prepare-20261017-114553/`. During v1.5.1 work the public release API was read again: release ID, publication timestamp and all three asset sizes/digests match that record.

简体中文：v1.5.0（25）已于 2026-10-17 12:16:09（Asia/Shanghai）正式发布为 Latest，发布提交为 `01848fec98265712e2cff47a7a1517f5eecbf430`。Main/Tag CI 均成功；经 Draft 附件回读、公开下载与生产签名核验后发布。该记录不代表已新增真实 Local Vault OAuth、私有写入、真实到期轮换或 Intel/macOS 14 真机验收。


## v1.5.1 hosting stability validation

Released: **1.5.1 (26)** at commit `75b1552e88020bef2327c5e8eeb54be36978c746`. The local audit below preceded the owner-authorized publication recorded at the end of this section. The v1.5.0 record remains historical. Audit progress is in `.local/v1.5.1-progress.md`; publication progress is in `.local/v1.5.1-release-progress.md`.

Disconnect stops the account session and owned API work before cleanup. Active-storage and historical-copy deletion have independent outcomes; disconnected metadata retains denied copies across restart for explicit retry. Historical Keychain denial cannot restore a Local Vault session or hide a remaining copy. Original Git credentials are unaffected.

Overview immediately renders the selected list snapshot. Commits, Files, Reviews and CI independently load their first page on selection, with separate errors, cancellation, cache and retry. Later pages remain explicit. Empty GitHub statuses continue only to the first Checks page, and cancelled requests do not restart themselves. Review failures do not block commits/files; CI denial stays an error. Remote Diff remains read-only; malformed/overflowing hunk ranges or mismatched body counts retain their raw preview without actionable hunks, preserving CRLF bytes.

Real Gitea acceptance found additional provider differences and led to repairs: Branch uses `commit.id`, the official DTO and synthetic cases establish that nonempty commit statuses use `status`, and a real successful empty combined status may contain `statuses: null` with numeric `total_count: 0`. SHA validation remains strict and malformed/null nonempty responses remain errors. Fork creation uses the full reviewed `owner/repo:branch`; owner-only addressing could select another repository. Upstream full-repository syntax is verified for [Gitea 1.26](https://github.com/go-gitea/gitea/blob/v1.26.0/routers/api/v1/repo/pull.go#L1030-L1038) and 1.27; older servers that reject it stop without fallback or another POST. Same-repository creation is unchanged.

### Automated and native fixture evidence

| Check | Recorded result |
| --- | --- |
| Complete Core suite | **494 tests, zero failures/skips (268.676 seconds)**; final Core sources and tests, `core-final-494.log`. |
| Focused Hosting/Diff/callback suite | **186 tests, zero failures/skips (1.334 seconds)**, including 22 provider compatibility, 20 detail and eight callback tests. |
| Release-tool gates | **10 passed (1.614 seconds)**; release scripts remained unchanged. |
| Universal build and signatures | **1.5.1 (26), arm64 + x86_64**, nested/deep signatures passed; all 209 frozen inputs match, `universal-preview-final.log`. |
| Native Hosting / full UI / browser callback | **33 focused Hosting captures** (22 storage, four disconnect, seven detail), including an intentionally late cancelled Gitea 403 while its replacement preview remains loading, followed by a read-only Diff; mock ordinary-browser callback passed. Final full native UI/PTY regression passed with **104 captures**, `native-full-v4`; all these runs use the final Universal bundle. |
| DMG | **17,712,102 bytes**, SHA256 `0b36324a8f9d0d2280dd2deed06da089c64941efd43054d4ce056357713ececc`. HFS+/ULFO structure, Universal/deep signatures, all 105 regular files and complete links/modes match dist. Normal Finder DMG-file open shows the intended icons/background/arrow/bilingual instructions; task windows closed and image detached. The final local candidate is `.cache/v151/candidate-v3/GitPier-1.5.1-macos-universal.dmg`; earlier candidates remain marked SUPERSEDED. |

Tests cover migrated historical-copy denial, immediate disconnect, restart/retry, late refresh/write completions, request/account generations, shared cache readers, slow networks, 403/404/429/5xx, cancellation/retry, large-PR pagination and rapid tab/PR switching. Provider creation fixtures revalidate exact source/target SHA and account identity before POST, including same-owner forks and older Gitea rejection. Callback tests use real local loopback HTTP with synthetic OAuth: valid provider errors finish immediately, malformed/ambiguous or foreign callbacks are rejected, and response bodies contain no callback secrets. Diff tests cover invalid/overflowing coordinates, count mismatches, later malformed hunks, zero ranges and CRLF.

The complete Hosting fixture matrix passed with **271 system-window captures** across English/Simplified Chinese, Light/Dark and 960/1440/1800 widths. The final focused rerun covers storage, denied cleanup and detail loading. Injected OAuth/API and Keychain denial in these fixtures are simulations, not real-platform authorization or actual macOS refusal.

```bash
Scripts/test.sh
Scripts/test.sh --filter 'Hosting.*Tests|DiffParserSafetyTests'
python3 Scripts/test-release-tools.py
UNIVERSAL=1 Scripts/build-app.sh
GITPIER_HOSTING_STORAGE_ONLY=1 Scripts/workspace-acceptance.sh hosting .cache/v151/native-hosting-v4
Scripts/workspace-acceptance.sh full .cache/v151/native-full-v4
Scripts/workspace-acceptance.sh hosting-browser .cache/v151/native-browser-v4
```

### Real platform OAuth, restart, migration and refresh

The owner personally approved first-use Local Vault OAuth on **GitHub.com, GitLab.com and code.superecloud.com (Gitea 1.27.3)**. All three real current-user APIs passed before and after a complete process exit/restart. Vault pointers remained unchanged across exit/restart. OAuth Keychain read/save/replace/delete counters were zero during initial authorization, restoration and refresh. This is new Local Vault evidence, distinct from v1.5.0's historical Keychain login.

One GitLab account migrated **Local Vault → real isolated Keychain → Local Vault** while the other accounts remained available. All three identities passed in the mixed-storage checkpoint. The historical Keychain copy was explicitly retained for cleanup. A later real disconnect removed the account/binding and both its Local Vault and historical Keychain copy; the other two identities still passed. macOS allowed deletion without an authorization-refusal dialog, so this is a real cleanup success, not real OS-denial evidence. Reconnecting with the same existing `api` grant produced a new account UUID and three verified identities again. Synthetic denied-cleanup/restart/retry coverage is recorded separately.

At the owner's chosen boundary, all providers passed **real server Refresh Grants after controlled client expiration**. Access and Refresh Tokens changed, remote identity remained correct, and the persisted pair matched the refreshed pair. Refresh kept the installed seed key and changed its vault generation. Reports explicitly record `controlledClientExpiry: true` and `naturalServerExpiry: false`; natural server expiry remains unverified.

GitHub `public_repo` and GitLab `api` browser reauthorization preserved their account UUIDs, rotated the corresponding Local Vault keys and preserved other accounts' keys. Gitea rejected expansion of its existing grant with `server_error` / `a grant exists with different scope`, matching the [upstream restriction](https://github.com/go-gitea/gitea/blob/v1.27.0/routers/web/auth/oauth2_provider.go#L395-L402). This exposed the fixed loopback error-completion defect. The application does not revoke or retry grants automatically. The owner personally revoked only the test grant, then a new `write:repository` authorization succeeded on the repaired application. Gitea retained its account UUID, rotated its key, preserved the GitHub key and passed real identity verification. Eight callback regressions cover error handling; a second real failed scope expansion was not deliberately induced.

Redacted results are in `.cache/v151/oauth-live/run-f_k6qinw/`, including refresh, reauthorization, migration, request and checkpoint reports. They contain only public metadata, booleans, counts, expiry times and opaque pointer IDs. Real tokens, Refresh Tokens, keys and private credential files must never be uploaded. The temporarily redirected `gitpier://` handler was restored to `/Applications/GitPier.app` and independently read back.

### Real requests within the authorized repository boundary

Writes were limited to these three disposable repositories. Each request creation used **one POST**, followed by matching ID/source-SHA readback. All three returned Overview, one commit, one changed file and a parsed read-only Diff; Gitea obtains its patch through the separate read-only Diff endpoint.

| Provider | Real request and behavior | CI / permission result |
| --- | --- | --- |
| GitHub | [PR #1](https://github.com/Heisenberg2024/test/pull/1): created Draft; one ordinary comment and one comment-only review; Closed, reopened/ready and Merged read back through HostingAPI. Native Reviews displays both kinds. | Native CI exhausted empty statuses and Checks pages before No Checks. With the test repository temporarily private, `public_repo` access returned Not Found, preserving the error; public visibility was restored and read back. |
| GitLab | [Draft MR !1](https://gitlab.com/wipe-group/test/-/merge_requests/1): created/read back; native Commits, Files and read-only Diff passed. Original main README preserved. | Successful empty Pipeline response gives No Checks. No real pipeline job was created. |
| Gitea | [PR #1](https://code.superecloud.com/Heisenberg/test/pulls/1): created/read back after write authorization; commits/files/reviews/read-only Diff passed. Portable creation has no Draft flag. | The repaired API exhausted the real empty status response and returned No Checks. Its issue-conversation endpoint returned Permission Required under `write:repository`; that error remains isolated from readable reviews/files/commits, and no extra issue scope was requested. |

### Unverified real-environment boundaries

Real PAT authentication, Fork repository creation, other private-repository permission combinations, GitLab/Gitea review/comment writes, natural token expiry and actual macOS Keychain refusal remain unverified. Creating a real Fork would require a repository outside the authorized three URLs, so it was not attempted. Protocol fixtures cover those request formats, errors and state mappings; empty CI responses are not evidence of a real build job or pipeline execution. Self-hosted GitLab was not supplied.

The final isolated application restored all three real identities again after restart with zero OAuth Keychain calls, and passed native Gitea Files/Overview switching, read-only Diff, empty CI and comment-403 isolation. All three isolated accounts were then explicitly disconnected; credential/key files, temporary application copies and the run-specific preference domain were removed. The historical isolated Keychain item had already been deleted successfully. Public checkpoints and the authorized test requests remain for review; remote grants were not revoked. The callback handler was read again after cleanup and still resolves to `/Applications/GitPier.app`.

The v1.4.4 HTTPS/SSH path, Automatic Fetch, Credential Helper, `GitPier.credentials`, default Local Vault/optional Keychain, production Bundle ID, Sparkle feed/public key and macOS 14+ Universal format remain preserved. The final invariant check compares 39 protected files and 34 historical local distribution files against the task baseline. Intel/macOS 14 hardware execution, Developer ID/notarization, Gatekeeper/quarantine, production installation and production self-update remain unverified. Same-commit Swift 6.1 CI and the subsequent authorized publication are recorded below.

简体中文：v1.5.1（26）已正式发布，发布记录见下。已修账号立即断开/历史副本独立清理、PR详情按需隔离加载、OAuth错误回调终结、Gitea分支/CI字段和Fork源仓库精确定位，以及Diff畸形边界。真实三平台首次Local授权、完全退出恢复、重授权密钥轮换、受控客户端到期后的真实Refresh Grant及三专用仓库请求创建均通过；GitLab真实双向迁移、断开删净旧副本、重连与其他账号隔离通过。macOS本次未拒绝删除，拒绝/重启重试仍仅合成覆盖；自然到期、真实PAT/Fork和其余权限/写入矩阵保留未验。GitHub真实评论/审查、Closed→Merged和私有仓库拒绝已回读。临时回调路由恢复原应用。v1.5.0正式发布记录保持，测试与真实验收边界分开记录；后续发布已获所有者明确授权，详情如下。


### v1.5.1 publication — 2026-10-17

[GitPier v1.5.1](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.5.1) was published as **Latest** at **2026-10-17 21:22:49 (Asia/Shanghai)**, release ID **415807601**. The tag points to `75b1552e88020bef2327c5e8eeb54be36978c746`, matching the approved main commit. [Main CI 39031961317](https://github.com/Heisenberg2024/gitpier/actions/runs/39031961317) and [Tag CI 39035045400](https://github.com/Heisenberg2024/gitpier/actions/runs/39035045400) passed. Main CI used Swift 6.1.2 and passed 494 Core tests with zero failures/skips (417.687 seconds), 10 release-tool gates (0.955 seconds), the application build, temporary DMG checks and signature/permission-preserving archive upload; Tag CI also passed the complete workflow.

The released Universal DMG reuses the accepted candidate: **17,712,102 bytes**, SHA256 `0b36324a8f9d0d2280dd2deed06da089c64941efd43054d4ce056357713ececc`. All 209 frozen build inputs matched both the working files and tagged commit. The existing production Keychain key signed the DMG and appcast; independent verification and equal-length tamper rejection passed. The three Draft assets were downloaded by asset ID and checked before publication. After publication, all three anonymous public downloads and the canonical Latest feed returned HTTP 200 with exact expected bytes; signatures, embedded English-first bilingual notes, version/build/minimum OS, Tag and Latest were checked again.

The 13 historical releases, 35 historical assets and 13 prior tags retained their recorded metadata/digests; all 34 local historical artifacts and 39 protected files remained unchanged. No application was installed, no production keys or credentials were exported, and publication adds no new real-platform OAuth, natural-expiry, Intel/macOS 14 hardware or production self-update evidence. Publication evidence is local in `.cache/releases/v1.5.1/release-20261017-204316/`.

简体中文：v1.5.1（26）已于 **2026-10-17 21:22:49（Asia/Shanghai）**正式发布为 Latest，Release **415807601**，标签指向已通过 Main/Tag CI 的 `75b1552e88020bef2327c5e8eeb54be36978c746`。复用 209 项输入完全匹配的已验收 Universal 候选；原生产密钥签署、独立验签与等长篡改拒绝通过。先回读 Draft 三附件，再发布并验证公开三附件、canonical Latest Feed、正文、版本与标签。13 个历史版本、35 个远端历史附件、13 个旧标签及本地历史资产和保护文件保持；真实 OAuth、受控客户端过期刷新和模拟拒绝验收边界保持上文所述，本次发布未新增自然过期、Intel/macOS 14 真机或生产升级验收。

## Review stability acceptance commands (v1.6.1)

Use `Scripts/test.sh`, `python3 Scripts/test-release-tools.py`, `python3 Scripts/test-ci-validation.py` and `python3 Scripts/test-review-upgrade-fixture.py` for automated checks. After `UNIVERSAL=1 Scripts/build-app.sh`, keep GUI runs serial and use `Scripts/workspace-acceptance.sh full`, `Scripts/workspace-acceptance.sh review`, `Scripts/workspace-acceptance.sh review-stability` and `Scripts/workspace-acceptance.sh hosting-browser`, each with a fresh evidence directory. The wrapper copies and re-signs only a uniquely identified disposable application, uses temporary repositories/workspaces and removes its own preferences/copy. The `review` menu-entry subset still requires its documented explicit GUI-assisted Picker selection; automatic provider fixtures do not claim that interaction.

For actual 27 → 28 updating, start `Scripts/serve-update-test.py` on a fresh ignored `.cache/update-acceptance/<name>/server`, then run `python3 Scripts/prepare-review-upgrade-test.py .cache/update-acceptance/<name> --old-app <real-1.6.0-app> --new-app dist/GitPier.app`. This rejects substituted versions, source code changes, existing outputs and unrelated server files; it records code-section hashes before/after test re-signing and replaces the callback scheme with an isolated test scheme. It creates a new private `/private/tmp/GitPier-update-acceptance-*` runtime. The installed old app belongs in the private runtime, outside Documents privacy-gated paths; the downloadable new app stays in the ignored fixture directory. Only a test flag, isolated identity/private path and explicit fixed synthetic marker can enable `HostingReviewUpgradeProbe`; production identity and environment variables alone cannot select it. The probe checks actual application Local Vault restoration and unknown-operation recovery, never unlocks Keychain or invokes provider APIs. An independent external data probe is separate evidence. Confirm installation/relaunch and all result files before reporting an update passed, then quit test apps, detach only owned mounts, stop the loopback server and remove the disposable keys/runtime.

简体中文：上述命令分别检查自动化、隔离原生 UI 与真实 27→28 测试更新。GUI 串行运行，生产应用/偏好/Feed/更新私钥不参与；测试副本使用独立身份与 scheme。新应用探针只能由严格测试身份、私有路径和固定合成 marker 开启，只在应用内验证 Local Vault/元数据/Journal，绝不解锁 Keychain 或访问平台 API。外部解密、读取 Feed 或挂载镜像不能单独证明实际安装升级成功。

### Workflow live-update and CLI window regression

`Scripts/workspace-acceptance.sh workflow170` keeps one Operations Center mounted across asynchronous running/progress/cancellation/final events; a begin-and-finish pair in the same run-loop turn cannot detect stale rows. It also exercises deferred/minimized window presentation and the actual Terminal settings form at 760 points in both languages/themes. Static SwiftUI text must be read through AXValue as well as AXLabel.

Cold URL launches explicitly request the original workspace using SwiftUI’s [OpenWindowAction](https://developer.apple.com/documentation/swiftui/openwindowaction) when no managed window exists; the window hook then fulfils foreground presentation.

For external CLI acceptance, check both the foreground PID and a visible workspace window before using any GUI tool that might open or raise GitPier. A successful Launch Services callback, an active process, or an early navigation snapshot with zero windows is insufficient. Use only disposable app identities and fixture repositories; never install/uninstall the user's real launcher during UI acceptance.
