<p align="center">
  <img src="Resources/Branding/gitpier-icon-1024.png" width="112" alt="GitPier 应用图标">
</p>
<h1 align="center">GitPier</h1>
<p align="center">
  <strong>Native Git Client for macOS</strong><br>
  All Your Repositories. One Workspace.
</p>
<p align="center"><a href="README.md">English</a> · 简体中文</p>

GitPier 将仓库管理、变更审查、提交和集成终端汇集在一个专注的 macOS 工作空间中。应用采用 Swift、SwiftUI 和 AppKit 开发，直接使用本地仓库和已安装的 Git。

![提交工作台：已跟踪与未跟踪变更、双栏 Diff 和终端](docs/screenshots/commit-workspace.png)

## 功能

- **多仓库管理。** 切换仓库和 Worktree，通过组织管理项目，在侧栏和组织页面拖动仓库并保存顺序。从组织内打开的仓库会自动归属该组织。
- **专注的提交流程。** 使用独立文件复选框选择变更，审查选中内容，执行提交或提交并推送。保留已有部分暂存和其他工具暂存的变更。
- **处理推送拒绝。** 远程分支有新提交时，确认“合并并推送”即可获取、合并后重试推送。本地提交始终保留；出现冲突时停止推送，交由你解决。合并前请先提交或 Stash 剩余的已跟踪文件修改。
- **应用内解决冲突。** 对照当前版本与传入版本、预览共同祖先，逐块采用一侧或保留双方，并编辑合并结果。保存并标记文件解决后，审查并继续合并；待完成的合并推送保持原目标。二进制和大型文件支持整文件版本或删除选择。
- **双栏 Diff。** 通过行号、语法着色、同步垂直滚动和轻量滚动条比较代码；Index 一侧为空时，工作区占满宽度。对支持的 Hunk 执行暂存、取消暂存或丢弃，并通过标签保留文件。
- **统一滚动体验。** 列表、设置、帮助、提交说明、标签栏和终端缓冲区统一使用 Diff 的短覆盖滑块，滚动时加深，停顿后淡化。
- **集成终端。** 在真实 PTY 中运行已安装的 Shell，支持多标签、分屏和搜索。每个仓库保留自己的会话和工作目录。
- **历史与分支。** 浏览提交图，管理分支、远程、Stash 和标签，通过 Git 执行获取、拉取、推送、合并和变基。
- **全历史与 Stash 预览。** Git 原生全历史分页查询支持消息、Hash、作者、日期与分支过滤；Stash 预览复用文件列表与双栏 Diff。
- **历史审查与布局。** 历史页复用提交页的 Diff 渲染和滚动条，按仓库保存详情高度与文件列表宽度；再次点击选中记录或按 Esc 关闭详情。
- **编辑器与帮助。** 按优先级从带应用图标的下拉列表选择默认编辑器，并添加自定义 App。仓库和提交文件的右键菜单通过“在编辑器中打开”子菜单选择本次使用的编辑器，并保留应用图标。帮助菜单提供内置的中英文离线使用指南。
- **凭证管理。** 使用 macOS Keychain 保存 HTTPS Token，并选择 SSH 身份配置。支持既有 Git 凭证助手、SSH 配置、Hooks 和提交签名。

支持英语与简体中文界面、深浅主题及跟随系统外观。点击仓库或应用切回前台时主动刷新，也可使用 **⌘R** 手动刷新；可选文件监听会提示外部变更。完成通知在传输结束后展示最终操作结果。

打开或选择仓库时始终进入提交页，不持久化当前页面。侧栏支持一键收起或展开全部组织的仓库。

## 专业 Git 工作流 — v1.2.0

已发布的 [v1.2.0](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.2.0) 增加引用日志恢复、安全的 Worktree 生命周期管理、任意本地 / 远程跟踪分支比较及 Git Blame，复用 Git 原生查询和现有 macOS 面板。恢复优先创建新分支，比较与 Blame 保持只读；未知或存在修改的工作树目录不可删除。Blame 支持最大 4 MiB 的 UTF-8 文本，每页查询 400 行。详情见[变更记录](CHANGELOG.md)及[开发验证说明](docs/development.md)。通过 GitHub Latest Release 安装，或从 v1.1.0 使用“检查更新”升级。

## 提交与仓库工作流 — v1.3.0

已发布的 [v1.3.0](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.3.0)（构建号 19）增加交互式变基，支持经过审查的 Pick/Reword/Squash/Fixup/Drop 计划、提交顺序调整、Git 原生冲突处理和需要审查的 Continue/Skip/Abort 恢复，最多处理 200 个线性提交。Hooks、签名、部分暂存和生产更新身份继续受到保护。本地与发布验证结果见[开发指南](docs/development.md#v130-release-validation--2026-10-15)。

菜单使用不带附加指示箭头的紧凑标签，变基操作控件与拖动图标对齐，关于页完整显示在一个设置页面。开启自动检查后，会在启动时及 Sparkle 的定时计划中检查，并提供原生更新提醒；下载和安装仍需要确认。

在 Diff 行号区选择修改行，逐行暂存或取消暂存，同时保留其他暂存与工作区修改。逐行操作支持有大小限制的常规文本修改、CRLF 和末尾无换行；复杂文件变更和过滤器继续使用文件 / 差异块流程。刷新或切换文件、对比方式会清除选区。

导出文件、差异块、选中行、提交或两端提交范围补丁；应用普通 Diff 补丁前先预览并校验，工作区与 Index 是独立目标。提交邮件导出使用 format-patch；邮件导入 / git am、重命名 / 复制 / 符号链接 / gitlink 导入及二进制 delta 仍交由终端处理。导入限制为 8 MiB / 200 个文件，并限制字面量二进制数据大小。

Git LFS 页面检测可选工具，展示规则 / 文件 / OID / Pointer，审查根目录 .gitattributes 修改，并通过现有凭据执行需确认的 Fetch/Pull。不安装 LFS、过滤器或 Hooks，不自动转换已有文件或暂存规则。子模块展示声明 / 登记 URL 与 HEAD / Index / 父 gitlink，支持审查后的 Init/Sync/Add、独立的记录 / 远程提交检出，并可在 GitPier、编辑器或终端打开子仓库。嵌套条目先保持只读，打开其父仓库后再管理；不提供 Deinit / 移除及自动递归更新。

## 工作空间总览 — v1.4.0

已发布的 [v1.4.0](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.4.0)（构建号 20）增加本地工作空间总览，显示已扫描 / 全部数量，支持修改 / 暂存 / 领先 / 落后 / 冲突 / 不可用 / 收藏筛选、多选和关联 Worktree 展开收起。卡片使用独立内存缓存及有界后台查询；打开 Dashboard 不会读取每个仓库的 Diff 或历史。启动扫描仅查询本地。领先 / 落后依据本地跟踪引用，不代表服务器实时状态；无上游及不可用仓库明确区分。可选外部监听仍只标记需要刷新。

[v1.4.1](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.4.1)（构建号 21）采用居中自适应布局，增加五项可点击概览、搜索框与紧凑筛选、对齐的仓库 / 分支 / 修改 / 同步信息列，以及上下文选择栏。概览与筛选沿用同时匹配规则。小窗口将分支放在仓库名称下方；折叠 Worktree 仍计入匹配数和选择范围。不可用行可查看完整错误并刷新。克隆、组织管理和快速打开位于顶部更多菜单。

选择单个条目、组织匹配项或全部匹配项，再通过“获取已选仓库”审查每个仓库和远程。搜索或筛选时保留选择，并明确显示当前结果之外的所选数量。有界获取队列对远程配置一致的关联 Worktree 去重，保留工作区、Index 和 FETCH_HEAD，并独立显示成功 / 失败 / 取消结果，失败可审查后重试。不增加批量 Pull、Push、Reset 或 Rebase。

已发布的 [v1.4.2](https://github.com/Heisenberg2024/gitpier/releases/tag/v1.4.2)（构建号 22）新增原生三态“选择匹配项”，范围包括折叠 Worktree。审查 Fetch 并确认后清除已被队列接受的选择，取消或未提交的错误项保留。手动获取全部成功后五秒收起详情，失败保留审查与重试入口。

**设置 → Git → 自动远程检查**默认关闭，与本地文件监听独立。开启后仅在 GitPier 活动期间连接已配置远程：当前仓库默认15分钟（另可选10/30/60），工作空间其他仓库约45分钟，分批最多两并发。可限制范围或排除当前仓库。仅检查上游远程，同配置 Worktree 共享获取；失败后退避5–60分钟，需要认证时停止自动重试，等待手动获取。后台使用已有非交互凭据，未知/自定义凭据助手和SSH命令可能需要手动获取。工作文件、Index、分支、标签及清理仍由你控制。

本地扫描保持离线。Dashboard 区分“跟踪引用一致”和已成功联网检查的同步状态，Tooltip提供远程/本地时间及失败原因。Fetch显示检查中/过期/失败，Pull和Push显示非零数量及分叉/无上游提示；后台更新跟踪计数时保留草稿、Diff标签和仓库页面。

**v1.4.3 发行候选（23，尚未发布）：**专用后台凭证进程禁止传统登录钥匙串授权窗口，无法静默读取时停止检查并等待手动认证，修复 v1.4.2 自动获取期间反复授权的问题。在安装修复版前，受影响的 v1.4.2 用户请先关闭自动获取。保留手动认证和既有凭证访问控制。

“工作空间搜索”支持名称、路径、组织、分支、远程名称，以及按需查询已跟踪文件路径和提交信息 / 哈希。范围可选全部 / 当前组织 / 当前仓库 / 已选仓库，结果打开仓库、已有 Diff / 文件历史或提交详情。Git 查询可取消、分页并限制结果及输出，不建立源码内容索引或上传到第三方。**⌘⇧P** 打开快速切换，支持最近 / 收藏仓库、组织匹配、上下方向键、回车和 Esc；终端焦点保留原有按键。Universal DMG 是当前正式下载，发布验证结果见[开发指南](docs/development.md#v142-release-validation--2026-10-16)。

## 界面截图


### 双栏 Diff

![带行号和 Hunk 暂存控件的 Swift 代码差异](docs/screenshots/diff-viewer.png)

### 集成终端

![多终端标签和 Git 输出](docs/screenshots/integrated-terminal.png)

### 仓库总览

![包含四个演示仓库的工作空间总览](docs/screenshots/repository-dashboard.png)

## 安装

GitPier 要求 **macOS 14 或更高版本**。

从 [GitHub Latest Release](https://github.com/Heisenberg2024/gitpier/releases/latest) 下载当前正式版。请选择最新发行版附带的通用 DMG。打开 DMG，将真实的 GitPier 图标拖入 Applications，然后从 Applications 启动。

v1.1.0 的内置更新采用 Sparkle 2、GitHub Releases 和 EdDSA 签名 DMG；自动检查默认关闭，下载与安装需要确认。生产公钥已配置，发行资产必须在发布前完成签名和验证。v1.0.3 没有内置更新，需要手动升级一次。

当前采用 ad-hoc 签名，未使用 Apple Developer ID，也未完成 Apple 公证。首次安装可能遇到 Gatekeeper 提示；请核实来源并遵循 macOS 提供的安全选项，不要关闭 Gatekeeper 或移除隔离属性。


## 从源码构建

需要 macOS、**Xcode 16 或更高版本**及其命令行工具、**Swift 6.0 或更高版本**和 Git。依赖通过 Swift Package Manager 管理，并由 `Package.resolved` 锁定。可在 Xcode 中打开 `Package.swift` 浏览工程，或在仓库根目录构建应用：

```bash
Scripts/build-app.sh
open dist/GitPier.app
```

脚本为当前架构构建 Release 应用、打包资源并执行本地 ad-hoc 签名。生成包含 Apple silicon 和 Intel 二进制的本地通用 DMG 候选包（需要 Finder 图形会话）：

```bash
Scripts/package-release.sh --unsigned-candidate
```

测试与构建选项见[开发说明](docs/development.md)，实现细节见[架构说明](docs/architecture.md)。

## 安全与隐私

Git 操作在本机执行。受管理的 HTTPS Token 保存在 macOS Keychain 中，工作空间元数据和草稿保存在本地。GitPier 没有仓库上传或分析服务；远程操作连接用户选择的 Git Remote。Git Hooks、凭证助手和终端命令以当前用户权限执行，也可能访问网络。

提交审查保留外部 Index 和部分暂存内容。破坏性操作需要确认。GitPier 不会自动修改全局 Git、SSH 或 Shell 配置。分享日志或报告凭证问题前，请阅读[安全说明](SECURITY.md)。

## 参与贡献

欢迎提交问题报告与 Pull Request。请先阅读[贡献指南](CONTRIBUTING.md)，使用临时仓库复现 Git 问题，并移除附件中的私人数据。

## 许可证

GitPier 采用 [MIT License](LICENSE)。Copyright (c) 2026 Heisenberg2024。

第三方组件保留各自许可证，详见[第三方声明](THIRD_PARTY_NOTICES.md)。
