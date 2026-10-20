# Task Workspaces — v1.8.0 development

Task Workspaces organize an independent linked worktree, branch, immutable local baseline, optional Codex CLI session and review state. GitPier manages the Git workspace; the optional installed Codex CLI performs coding. This is a local integration, without a GitPier model backend or unattended agent scheduler.

## Create and open

Open a repository → **Worktrees → Tasks → New Task**. Choose a name, local branch/commit baseline, new task branch and a new absolute directory whose parent already exists. The default directory is a UUID-named sibling of the repository. Creation uses existing local objects, without Fetch. Existing directories, symlink ancestors, nested repositories, occupied branches and unfinished source Git operations are refused.

Alternatively, associate an existing linked worktree. An external association stays external. Only a matching original GitPier creation receipt and marker can establish managed lifecycle ownership. An externally created worktree cannot acquire removal permission by creating task metadata.

Tasks show branch/path, HEAD, staged/unstaged/conflict counts, timestamps and independent agent state. Only visible task summaries and the selected detail are queried, through the shared query budget. Opening Tasks or Dashboard never starts Codex. Missing/replaced worktrees are unavailable. Use the normal reviewed Worktree repair workflow after moving a directory; task rebinding additionally verifies its original filesystem and metadata identities.

## Optional Codex CLI

Install Codex separately using the [official CLI guide](https://developers.openai.com/codex/cli). GitPier never installs a package, changes PATH/shell files, edits Codex configuration or reads Codex login credentials. Ordinary task and Git features do not require an OpenAI account.

Settings → Terminal accepts an optional executable path; an empty path searches absolute PATH entries plus standard macOS CLI locations. Explicit detection runs bounded `--version` and `--help` probes, checks the `codex-cli` version format and supported safe interactive options, and captures executable filesystem identity. It does not inspect login state. Login remains Codex's own workflow.

**Start Codex…** first displays task, worktree, branch, HEAD, uncommitted count, executable/version and configuration. After confirmation, GitPier revalidates the task, branch, HEAD, common directory, filesystem identity and executable, then launches through the existing SwiftTerm/PTY using an internal foreground exec helper. A one-time pipe gate holds that helper until the PTY process identity is captured; the helper opens and verifies the task directory, uses `fchdir`, closes its descriptors and rechecks executable identity immediately before executing the fixed argument array:

```text
--no-daemon --sandbox workspace-write --ask-for-approval on-request
```

Safe interactive options are documented in the [official CLI reference](https://developers.openai.com/codex/cli/reference); detection additionally requires the installed CLI's foreground `--no-daemon` option. Existing Codex configuration also applies. No task description or prompt is interpolated into a shell command. No auto-resume, bypass-approval or unrestricted-sandbox flag is added. Agent sessions do not receive GitPier's managed Git authentication injection.

Codex can read files and execute commands under its own permissions and approval rules. GitPier's native Git confirmations cannot govern each command Codex executes. A worktree isolates Git working files; it is not an OS security boundary.

## Sessions and review

The existing TerminalManager owns PTY/view lifetime. Switching pages preserves sessions; input, Ctrl+C and resize remain terminal operations. Explicit Stop checks process start identity, signals verified attached processes and waits for cleanup. Quit and last-window close prompt for running agents and allow cancellation. GitPier remains open if cleanup cannot be verified. Processes that deliberately detach/reparent may need separate manual inspection; complete control over every possible daemon is not claimed.

Restart recovers an unfinished session as **Interrupted**, without executing anything. Waiting for input is an explicit user annotation, not an inference from terminal text. A zero exit code means **Agent Exited**, never that development or tests succeeded. Operations Center observes the same sessions and offers task/terminal/review navigation; it does not add a Git execution queue.

Review both views:

- **Baseline → Current HEAD / Commits** reuses fixed-SHA branch comparison, including commits created during agent work and paged commit/file Diff.
- **Current HEAD → Index / Working Tree** opens the normal commit workspace for staged, unstaged, untracked and conflicted changes. Partial staging and the external Index remain intact.

**Mark Current Snapshot Reviewed** is an explicit user acknowledgement. Its opaque digest covers task/baseline/HEAD, Index/operation and changed-file content/permissions (bounded to 200 changed files and 64 MiB). Dirty submodules and other changed directory entries cannot generate a receipt until recursive review is supported. Refresh checks whether that receipt still matches; the last reviewed snapshot remains historical metadata. It is not a test result or automatic completion. GitPier currently records no independently verified task test result; use the terminal to run tests. Existing Stage/Commit/Push/PR workflows retain their own confirmations and checks.

## Archive and removal

Archive changes metadata only. Worktree, branch, commits, ignored/untracked files and unsaved changes stay on disk; archived tasks can be reopened. Active agents cannot be archived.

**Review Worktree Removal…** navigates managed tasks to the existing Worktrees removal workflow. It checks original ownership, unchanged task metadata/filesystem identity, active agents/terminals, drafts, Git state and the existing status/ignored-file/detached-commit protections. Confirmation is separate; changes invalidate the review. No force remove, prune, branch deletion or automatic cleanup is added. External associations have no removal action.

## Local metadata and limits

Default metadata directory: `~/Library/Application Support/GitPier/workspace.tasks/`. A custom workspace uses the adjacent `<workspace-basename>.tasks/` directory. At most 512 UUID-named task records use schema-1 JSON envelopes; schema-zero imports are read without an automatic rewrite and migrate on explicit save. A lifetime exclusive owner lock prevents a second application instance from recovering live sessions or removing worktrees through an unavailable task module. A canonical-path lifecycle reservation also blocks process starts while reviewed removal/repair is queued. Descriptor-relative file access, locking and atomic replacement reuse existing private IO; directories are 0700 and files 0600. Invalid permissions, links, oversized/corrupt records and unsupported schemas stop changes and preserve originals.

Metadata includes task/repository UUIDs, paths, common/Git directories, creation receipt, dev/inode identity, branch, baseline SHA, dates/status, optional explicitly saved description, current session metadata and optional review receipt. It excludes prompts/transcripts, source contents, terminal output, tokens, keys and full environments. Descriptions are local metadata, never automatically written into a repository.

## 简体中文

从**工作树 → 任务 → 新建任务**创建独立工作树，选择本地基准、新分支和父目录已存在的新绝对路径。默认使用仓库旁的 UUID 目录，不自动 Fetch 或启动 Codex。可关联已有工作树；外部关联始终保持外部归属，任务元数据不能授予删除权限。移动后复用原工作树安全修复，并核对原目录/Git/Common 的设备与 inode 身份。

Codex 完全可选。**设置 → 终端**可指定可执行文件，留空搜索绝对 PATH 与常用目录。主动检测只执行有界版本/帮助查询，核对身份格式、安全交互参数及文件身份，不安装、不改 PATH/Shell/Codex 配置、不读认证。未登录时使用 Codex 自身的登录流程。

**启动 Codex…**先展示任务、目录、分支、HEAD、未提交修改、可执行文件/版本和配置。确认后重新核对身份，复用现有 SwiftTerm/PTY，通过一次性管道门捕获进程身份，再由内部启动器打开/核对目录、fchdir 并在执行前复核可执行文件身份，按固定数组运行 `--no-daemon --sandbox workspace-write --ask-for-approval on-request`。检测要求当前工具支持前台模式，不连接共享后台会话。不拼接描述/Prompt，不跳过审批，不放开全部沙箱，不自动恢复执行；Codex 仍使用其原配置与权限机制。GitPier 的 Git 确认无法约束 Codex 内部每条命令，独立 Worktree 也不是系统沙箱。

切页保留会话；显式停止核对进程启动身份并等待关联进程清理。退出或关闭最后窗口会提示，可取消；无法核验清理则保持应用打开。主动脱离/重设父进程的后台进程可能需要手动检查，不承诺回收所有可能的守护进程。异常重启将活动会话恢复为“已中断”，不会重新执行。等待输入由用户手动标记，不解析终端文字猜测。退出码 0 仅表示 Agent 会话退出，不表示任务或测试成功。

审查同时包含**基准 → HEAD / 提交**与**HEAD → Index / 工作树**；复用原比较、提交历史、Diff 与部分暂存。手动“将当前快照标为已审查”只保存有界的内容/Index/HEAD 摘要，刷新时检查是否仍匹配；脏子模块或目录条目目前拒绝生成回执。这不是测试通过或任务自动完成。目前没有已核验的任务测试记录，可打开终端运行。提交、推送及 PR 继续使用原确认流程，操作中心仅观察和导航，不新增 Git 队列。

归档只改变任务元数据，保留工作树、分支、提交及所有文件，可重新打开；活动 Agent 不可归档。移除为单独操作，进入原工作树审查，继续核对任务 UUID/快照、原始归属、文件系统身份、活动会话、草稿、Git 操作、未跟踪/忽略文件和分离提交保留条件。外部关联不提供移除，不使用 force/prune，不自动删分支或清理。

默认任务元数据位于 `~/Library/Application Support/GitPier/workspace.tasks/`，自定义 workspace 使用旁边的同名 `.tasks/` 目录。schema-1、最多512条、目录0700/文件0600、锁与原子写；实例生命周期独占锁防止第二进程接管活动会话，路径生命周期保留锁防止排队移除/修复期间启动进程；损坏、未来版本、不安全链接/权限等保留原文件并停止修改。保存任务身份、路径、基准、时间/状态、当前会话、审查摘要及用户主动保存的私有描述；不保存对话/Prompt、源码、终端输出、Token/密钥或环境变量全文。
