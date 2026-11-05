# GitPier CLI

The optional `gitpier` command opens a local repository or Worktree in your chosen GitPier application. It navigates only; Git writes retain their normal app review and confirmation flows.

## Install

Move GitPier to Applications and open **Settings → Terminal → Install Command Line Tool**. The app installs its standalone launcher at `~/.local/bin/gitpier` with a private ownership receipt. It does not request administrator access or edit shell configuration. Add `~/.local/bin` to your shell's PATH yourself if needed.

Existing files, scripts, symlinks, broken launchers, and unknown receipts are preserved. Installation rejects unsafe directory ownership/permissions and symlink directory components. Installing from a read-only volume, including a mounted DMG, is refused.

## Commands

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

`open [path] [--page page]` defaults to the current directory and `commit`. Supported pages are `commit`, `history`, `branches`, `worktrees`, and `compare`. Paths may be relative, absolute, or accessible symbolic links to local working directories. Non-Git, bare, inaccessible, or missing directories are refused. Both launcher and app validate repository identity; a linked Worktree opens its working directory, not its shared Git metadata directory.

The command brings the chosen app/workspace to the foreground and restores a minimized window when needed. `--help` and `--version` do not start the GUI. Successful delivery means Launch Services accepted the request; any later repository-validation error appears in GitPier.

## Choose an app or uninstall

The launcher records the explicitly selected app using its installation location, bookmark, and Bundle ID. A valid app replacement at the selected location takes precedence; if that location disappears, a bookmark can follow a move on the same volume. It does not silently select another installed copy.

Use **Uninstall Command Line Tool** in Settings → Terminal. Uninstall verifies the current file hash, type, ownership, and receipt; a changed or unverified file is retained for manual inspection. No directory or unrelated file is removed. To change the selected GitPier copy, uninstall, use **Choose GitPier App…**, then reinstall. If the target app is unavailable, reinstall the tool from the copy you intend to use.

## Boundaries

Requests use a versioned `gitpier://navigate/open` URL, separate from OAuth callbacks. The app rejects unknown/duplicate fields, credentials, and mutation pages, then serializes and deduplicates requests. URL schemes cannot prove sender identity: adding an unknown repository from an external URL requires confirmation of its canonical path and another repository-identity check.

The CLI accepts no tokens/passwords, arbitrary Git commands, shell commands, or Codex launch requests. It does not run a local HTTP control service or construct a shell command from paths. Task Workspaces and external-agent launches remain separate confirmed app actions. See [Security](../SECURITY.md#local-metadata-diagnostics-and-optional-tools).

The SwiftPM product is named `GitPierCommandLine` to avoid a collision with `GitPier` on case-insensitive filesystems. Packaging installs it as `Contents/Helpers/gitpier` and signs it before the app.

## 简体中文

可选的 `gitpier` 命令在选定的 GitPier 应用中打开本地仓库或 Worktree，仅负责导航。提交、拉取、推送等写入继续通过应用中的审查和确认流程执行。

将应用移入“应用程序”后，在**设置 → 终端 → 安装命令行工具**安装至 `~/.local/bin/gitpier`。安装同时保存私有归属凭据，不请求管理员权限，也不改 Shell 配置；如 PATH 未包含该目录，请自行添加。已有文件、脚本、符号链接、损坏的启动器和未知凭据均保留；目录权限或归属不安全、目录包含符号链接、应用位于只读 DMG 等情况会拒绝安装。

命令示例见上方。`open [path] [--page page]` 默认当前目录和 `commit` 页面，支持 `commit`、`history`、`branches`、`worktrees`、`compare`。可使用相对路径、绝对路径或可访问目录的符号链接，支持空格和中文。启动器和应用分别核验身份；关联 Worktree 打开实际工作目录。裸仓库、非 Git、缺失或无权限目录会被拒绝。

命令将选定应用及工作空间切至前台，必要时恢复最小化窗口；帮助和版本命令不会启动 GUI。命令成功退出表示系统接受了导航请求，之后的仓库校验错误会在应用中显示。

启动器通过安装位置、应用书签和 Bundle ID 绑定明确选定的应用，优先使用原位置的有效替换版本；原位置不存在时可跟随同卷移动，不静默选择其他副本。切换应用时，先在“设置 → 终端”卸载，再点“选择 GitPier 应用…”并重新安装；目标失效时，从准备使用的应用重新安装工具。

卸载须核对当前文件哈希、类型、所有权和归属凭据；变化或无法核实的文件会保留，交由人工检查。不删除目录或无关文件。

导航 URL 与 OAuth 分离，拒绝重复或未知字段、凭证及写操作页面，并顺序处理和去重。URL Scheme 不能证明发送者身份，外部请求添加陌生仓库前须确认规范路径并重新核验仓库身份。CLI 不接受 Token、密码、任意 Git/Shell 命令或 Codex 启动请求，不提供本地 HTTP 控制服务，也不拼接 Shell。任务工作空间和外部代理仍通过应用单独确认。

SwiftPM 内部产物名为 `GitPierCommandLine`，避免在大小写不敏感的文件系统中与 `GitPier` 冲突；打包时安装为 `Contents/Helpers/gitpier`，先签名再签主应用。
