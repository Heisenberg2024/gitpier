# GitPier CLI — v1.8.0 development

The `gitpier` command opens a local repository or Worktree in your chosen GitPier application. It only navigates. Commit, Pull, Push, Merge, Rebase and other writes remain in their existing app workflows.

```sh
gitpier --help
gitpier --version
gitpier open .
gitpier open ../project --page history
gitpier open "/path/with spaces/项目" --page commit
gitpier open . --page branches
gitpier open . --page worktrees
gitpier open . --page compare
```

`open` brings the selected GitPier copy and its workspace window to the foreground, restoring a minimized window when needed. It defaults to the current directory and Commit page. Paths can be relative, absolute or symbolic links to accessible local working directories. The launcher checks local Git identity; the app repeats validation before navigation. Common directories are metadata and are not substituted for a linked Worktree's working directory. Bare repositories and inaccessible/non-Git directories are refused. `--help` and `--version` do not start the GUI. Launch Services acceptance means a request was delivered; app validation errors remain visible in GitPier.

Use **Settings → Terminal → Install Command Line Tool** to install in `~/.local/bin/gitpier`. Install, Uninstall and Choose GitPier App share one row in the Terminal tab. GitPier copies its signed standalone launcher and creates a private ownership receipt beside it. It does not ask for administrator rights or edit shell files. If necessary, manually add this directory to your shell's PATH:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Existing files, scripts, broken launchers, links and unknown receipts are preserved. The installer refuses symlink directory components and unsafe ownership/permissions. **Uninstall Command Line Tool** verifies the receipt, current file hash, regular-file type and ownership. Changed or missing files need manual inspection. It does not remove any directory or unrelated file.

The receipt records the selected installation location, bookmarks the explicitly selected app and verifies its Bundle ID; the launcher does not silently pick another copy by global Bundle ID. A valid replacement at the selected location takes precedence over a bookmark that follows the old app into a moved-aside location. If that location is absent, the bookmark can follow an app move on the same volume. Installation from read-only volumes, including mounted installer images, is refused. If the app is unavailable, reinstall from your chosen GitPier copy. To select another copy, uninstall, choose **Choose GitPier App…**, then reinstall. A launcher installed while testing remains bound to that test app.

The SwiftPM product is deliberately named **GitPierCommandLine**. Default macOS filesystems cannot safely place separate `GitPier` and `gitpier` build products in the same directory. Packaging installs the distinct product as `Contents/Helpers/gitpier` and signs it before the app.

Requests use `gitpier://navigate/open` with an exact versioned vocabulary. OAuth remains `gitpier://oauth/gitlab` with its original state/PKCE checks. Unknown/duplicate fields, credential fields and mutation pages are rejected. Requests are serialized and deduplicated in memory across running windows. This is not an HTTP control service. No shell command is constructed from arguments. The CLI does not accept tokens, passwords or arbitrary Git commands.

URL schemes cannot prove the sender is the official CLI. Registered repositories still navigate normally; adding an unknown repository from any external URL requires explicit consent with Cancel as the default. The app displays the canonical path, then rechecks root/common-directory identities after confirmation. The CLI cannot start Codex or execute commands. See [Task Workspaces](task-workspaces.md).

## 简体中文

URL Scheme 无法证明请求来自官方 CLI。已登记仓库仍正常导航；任何外部 URL 添加陌生仓库前都需要明确确认，默认取消，展示规范路径并在确认后复核根目录/Common 身份。CLI 不提供启动 Codex 或执行命令的入口；[任务工作空间](task-workspaces.md)中的启动继续独立确认。

`gitpier` 仅唤起选定的 GitPier 并定位仓库/工作树和页面。Commit、Pull、Push、Merge、Rebase 等写入继续使用应用中的既有工作流。`open` 将选定的 GitPier 及工作空间窗口切换到前台，必要时恢复最小化窗口；默认当前目录和提交页；支持相对/绝对路径、空格、中文和可访问目录的符号链接。启动器和接收端分别验证 Git 仓库，关联工作树不会被替换为 Common Directory。非 Git、裸仓库、无权限或不存在的目录被拒绝。

在**设置 → 终端 → 安装命令行工具**安装到 `~/.local/bin/gitpier`。安装、卸载、选择 GitPier 应用三个按钮位于同一行。复制独立启动器并保存私有归属凭据；不请求管理员权限，不修改 Shell 配置。PATH 缺少该目录时，请自行使用上方示例配置。帮助和版本命令不会启动 GUI。

已有同名文件、脚本、损坏启动器、符号链接和未知归属文件均保留。卸载须核实文件哈希、类型、归属和安装凭据，无法验证时保留并提示人工检查。不会删除目录或无关文件。

启动器记录选定安装位置，并使用应用书签和 Bundle ID，避免测试版/正式版或多份应用之间静默切换。优先使用原位置有效替换版本，避免跟随被移走的旧应用；原位置不存在时支持同卷书签移动，拒绝从只读安装镜像安装；目标失效时从选定应用重新安装。切换另一份 GitPier 时先卸载，再选应用并重新安装。SwiftPM 内部产物名为 `GitPierCommandLine`，防止大小写不敏感文件系统与主程序 `GitPier` 互相覆盖。

原生 Launch Services 支持冷/热启动请求。导航 URL 与 OAuth 路径严格隔离，禁止危险页面、重复/未知字段和凭证参数；运行中按请求 UUID 去重并顺序处理。CLI 成功退出表示系统接受唤起请求，后续验证错误在应用内展示。不会开放本机 HTTP 控制接口或拼接 Shell。
