# GitPier Roadmap

**Native Git Client for macOS** · *All Your Repositories. One Workspace.*

Reviewed: 2026-11-02. Current stable: [v2.0.0 (33)](https://github.com/Heisenberg2024/gitpier/releases/tag/v2.0.0). Next milestone: **Trusted Distribution**, planned separately with no release date.

GitPier develops the existing SwiftUI/AppKit workspace through focused, verifiable improvements. Milestones describe scope and acceptance conditions; they do not promise release dates. / GitPier 以现有原生工作空间为基础，持续改进可靠性、交互与性能；路线图说明范围和验收条件，不承诺发布日期。

## Released foundation / 已发布基础

| Version | Delivered product capabilities |
| --- | --- |
| [v1.0.0–v1.0.3](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.0.3) | Native multi-repository workspace, reviewed commits/partial staging, Diff, real PTY, bilingual UI and shared overlay scrolling. 原生多仓库、精确提交、Diff、终端和统一滚动。 |
| [v1.1.0](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.1.0) | Sparkle updates and a single version configuration with preserved update trust. 应用内更新与统一版本配置。 |
| [v1.2.0](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.2.0) | Reviewed Worktree lifecycle, Reflog recovery, Blame and branch comparison. 工作树生命周期、引用日志恢复、溯源与比较。 |
| [v1.3.0](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.3.0) | Interactive Rebase, selective line staging, Patch, LFS and Submodule workflows. 交互式变基、逐行暂存与扩展 Git 工作流。 |
| [v1.4.0–v1.4.4](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.4.4) | Dashboard, bounded local scans/search, reviewed batch/automatic Fetch and native authentication reuse. 多仓库总览、有界扫描/搜索、获取及原生认证复用。 |
| [v1.5.0–v1.5.1](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.5.1) | GitHub/GitLab/Gitea accounts, OAuth/PAT, Local Vault/Keychain choices and on-demand hosting detail. 代码托管、多账号与凭证存储选择。 |
| [v1.6.0–v1.6.1](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.6.1) | Native code review, provider-specific collaboration and durable unknown-result recovery. 原生代码审查、平台协作与未知结果恢复。 |
| [v1.7.0](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.7.0) | Operations Center, contextual workflows, command/navigation and optional CLI integration. 操作中心、上下文工作流、命令与 CLI。 |
| [v1.8.0](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.8.0) | Worktree Task Workspaces and optional Codex CLI through the existing user environment. 任务工作树与可选 Codex CLI。 |
| [v1.8.1](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.8.1) | Large staged assets, native file scrolling and merge/mainline reliability. 大资源、原生多文件滚动与合并可靠性。 |
| [v1.9.0](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.9.0) | Ordered Cherry-pick, unified Revert recovery, six-state Branch Health and large-history graph optimization. 有序重放、统一撤销恢复、分支健康与历史图优化。 |
| [v2.0.0](https://github.com/Heisenberg2024/gitpier/releases/tag/v2.0.0) | Coherent Index review, retained local commit results, bounded Diff reads, operation diagnostics, native History/locale refinements and measured scheduling. 一致审查、部分成功反馈、有界 Diff、诊断和原生体验。 |

Maintenance releases and exact changes are recorded in the [changelog](CHANGELOG.md). Released status does not imply all hardware, private accounts or distribution paths have been validated. / 维护版及具体差异见变更记录；已发布状态不等同于全部硬件、私有账号与分发路径均已验收。

## v2.0.0 — Production Quality & Native Experience

**Released / 已发布：2026-11-02，2.0.0（33）.** [Release](https://github.com/Heisenberg2024/gitpier/releases/tag/v2.0.0) · [Implementation record](docs/v2.0.0-plan.md) · [Validation and remaining limits](docs/v2.0.0-testing.md).

The release improves existing capabilities without introducing another Git engine, hosting platform or major business module. / 本版本打磨既有功能，不增加另一套 Git 引擎、新托管平台或大型业务模块。

| Workstream | Intended user result |
| --- | --- |
| Workflow reliability / 工作流可靠性 | Coherent Index review, accurate partial-success feedback, native recovery and protected worktree/task ownership. 一致的审查、准确的部分成功反馈和原生恢复。 |
| Native experience / 原生体验 | Consistent operation semantics, readable context, useful history selection/keyboard controls, native presentations and shared scrolling. 一致状态、清晰上下文、历史键盘体验和原生弹窗。 |
| Accessibility and languages / 无障碍与双语 | Meaningful labels and counts, selected-language dates/numbers, Light/Dark and increased-contrast checks. 明确标签与数量、语言适配、深浅色和增强对比度检查。 |
| Measured performance / 量化性能 | Bounded work and fewer scheduling allocations with reproducible algorithm and real UI measurements. 有界任务、更少调度开销及可复现测量。 |
| Quality evidence / 质量证据 | Real temporary Git scenarios, full Core/native acceptance, stable-source Universal builds and an honest RC decision. 真实临时 Git、完整回归、固定源码通用构建与可信 RC 判断。 |

Release acceptance includes independent source review, full same-source Swift 6.1.2 CI and the verified Universal/ad-hoc DMG with production Sparkle signatures. Final snapshot checks retain about 59 ms of measured refresh cost. Intel/macOS 14 hardware, full VoiceOver, long soak, private services and production self-update remain unverified. / 独立源码审核、同源完整 CI、通用包及生产更新签名已核实；保留约 59 ms 刷新成本，并明确硬件、完整无障碍、长时、私有服务和生产升级未验范围。

## Later: Trusted Distribution / 后续独立工作：可信分发

**Planned / 计划中.** Developer ID production signing, Apple notarization, Hardened Runtime production adaptation, staple/ticket validation, Gatekeeper distribution and related production-key/pipeline work form a separate milestone. They are excluded from v2.0.0 development. Existing Universal/ad-hoc/DMG/Sparkle behavior and production update trust remain in place.

Developer ID 生产签名、Apple 公证、Hardened Runtime 生产适配、公证票据、Gatekeeper 分发及相关生产密钥和流水线作为后续独立里程碑，不属于 v2.0.0。现有 Universal、ad-hoc、DMG 和 Sparkle 体系继续沿用。

## Future exploration / 后续探索

Other hosting platforms, issue/task integrations and optional AI assistance remain exploratory. No automatic remote writes or credential migration follow from this roadmap. / 其他平台、Issue/Task 集成和可选 AI 辅助仍处于探索阶段；路线图不授权自动远端写入或凭证迁移。

Implementation and publication follow the existing [development](docs/development.md), [contribution](CONTRIBUTING.md) and [security](SECURITY.md) boundaries. / 开发与发布继续遵守现有开发、贡献和安全边界。
