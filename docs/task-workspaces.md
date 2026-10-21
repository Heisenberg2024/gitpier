# Task Workspaces — v1.8.0 development

Task Workspaces organize an independent linked worktree, branch, immutable local baseline, optional Codex CLI session and review state. GitPier manages the Git workspace; the optional installed Codex CLI performs coding. This is a local integration, without a GitPier model backend or unattended agent scheduler.

## Create and open

Open a repository → **Worktrees → Tasks → New Task**. Choose a name, local branch/commit baseline, new task branch and a new absolute directory whose parent already exists. The default directory is a UUID-named sibling of the repository. Creation uses existing local objects, without Fetch. Existing directories, symlink ancestors, nested repositories, occupied branches and unfinished source Git operations are refused.

Alternatively, associate an existing linked worktree. An external association stays external. Only a matching original GitPier creation receipt and marker can establish managed lifecycle ownership. An externally created worktree cannot acquire removal permission by creating task metadata.

New tasks first reserve a private creation record, before Git changes the repository. After Git creates the worktree, GitPier captures its original directory/Git/common identities before writing its ownership marker. Task metadata and application ownership must both persist before registration is reported complete; the original pending record remains until both writes succeed. Failures distinguish incomplete Git creation from an existing worktree whose registration is incomplete. No rollback deletes a worktree, branch or user file.

Incomplete creations remain visible in Tasks after restart. **Resume Registration** verifies the saved original identities, repository family, branch and baseline before completing a missing marker or task record. Different markers and replaced directories are refused. Without a captured original identity, inspect Worktrees, explicitly forget only the private creation record, then associate the existing tree as external if appropriate. Repeated registration cannot create another task for the reserved path.

Tasks show branch/path, HEAD, staged/unstaged/conflict counts, timestamps and independent agent state. Only visible task summaries and the selected detail are queried, through the shared query budget. Opening Tasks or Dashboard never starts Codex. Missing/replaced worktrees are unavailable. Use the normal reviewed Worktree repair workflow after moving a directory; task rebinding additionally verifies its original filesystem and metadata identities.

## Optional Codex CLI

Install Codex separately using the [official CLI guide](https://developers.openai.com/codex/cli). GitPier never installs a package, changes PATH/shell files, edits Codex configuration or reads Codex login credentials. Ordinary task and Git features do not require an OpenAI account.

Settings → Terminal accepts an optional executable path; an empty path searches absolute PATH entries plus standard macOS CLI locations. Explicit detection runs bounded version/help probes, validates the complete safe argument combination through the installed parser, and captures executable filesystem identity. Incompatible versions remain unavailable; GitPier never weakens sandbox or approvals as a fallback.

**Check Login Status** explicitly runs `codex login status` with the same executable and effective environment. Checks are cancellable, limited to eight seconds and 16 KiB per output stream, and never run during startup, Dashboard refresh or background polling. Exit zero means CLI credentials are available; network, account permissions and model calls remain unverified. Only the explicit `Not logged in` response with exit one requests login; other failures and timeouts remain unconfirmed. Output is discarded, never displayed or saved. GitPier does not inspect authentication files or Keychain entries and never calls `codex logout`. Use the official CLI login flow for ChatGPT, API keys or other CLI-supported authentication.

Probes, login checks and the confirmed PTY share one in-memory environment snapshot. Existing HOME, inherited CODEX_HOME, proxy and official authentication variables are preserved; GitPier Git credential/helper overrides are removed. Standard command folders are appended to PATH without loading shell profiles. Without inherited CODEX_HOME, Codex chooses its own default. Finder/Dock may lack shell-only variables. Optional **Advanced Environment → Codex Home** accepts an existing absolute directory without symlink traversal, only for GitPier's Codex children. No private Codex home is created, no credentials copied, and no shell/system/Codex configuration changed. Diagnostics show the setting's source rather than credential or proxy values.

**Start Codex…** first displays task, worktree, branch, HEAD, uncommitted count, executable/version and configuration. After confirmation, GitPier revalidates the task, branch, HEAD, common directory, filesystem identity and executable, then launches through the existing SwiftTerm/PTY using an internal foreground exec helper. A one-time pipe gate holds that helper until the PTY process identity is captured; the helper opens and verifies the task directory, uses `fchdir`, closes its descriptors and rechecks executable identity immediately before executing the fixed argument array:

```text
--no-daemon --sandbox workspace-write --ask-for-approval on-request
```

Sandbox/approval options and login status are documented in the [official CLI reference](https://developers.openai.com/codex/cli/reference). Foreground `--no-daemon` support varies by version and is required here; parser acceptance does not replace a real PTY test. Existing Codex configuration also applies. No task description or prompt is interpolated into a shell command. No auto-resume, bypass-approval or unrestricted-sandbox flag is added. Agent sessions do not receive GitPier's managed Git authentication injection. Linked-worktree writes to shared Git metadata outside the worktree may require Codex approval; GitPier never adds unrestricted access to bypass it.

Codex can read files and execute commands under its own permissions and approval rules. GitPier's native Git confirmations cannot govern each command Codex executes. A worktree isolates Git working files; it is not an OS security boundary.

Codex may request a saved folder-trust decision before the first interactive session. GitPier does not accept that decision automatically. If an acceptance environment prohibits changes to existing Codex configuration, cancel at this prompt and record interactive coding as unverified.

## Sessions and review

The existing TerminalManager owns PTY/view lifetime. Switching pages preserves sessions; input, Ctrl+C and resize remain terminal operations. Explicit Stop checks process start identity, signals verified attached processes and waits for cleanup. Quit and last-window close prompt for running agents and allow cancellation. GitPier remains open if cleanup cannot be verified. Processes that deliberately detach/reparent may need separate manual inspection; complete control over every possible daemon is not claimed.

Restart recovers an unfinished session as **Interrupted**, without executing anything. Waiting for input is an explicit user annotation, not an inference from terminal text. A zero exit code means **Agent Exited**, never that development or tests succeeded. Operations Center observes the same sessions and offers task/terminal/review navigation; it does not add a Git execution queue.

Review both views:

- **Baseline → Current HEAD / Commits** reuses fixed-SHA branch comparison, including commits created during agent work and paged commit/file Diff.
- **Current HEAD → Index / Working Tree** opens the normal commit workspace for staged, unstaged, untracked and conflicted changes. Partial staging and the external Index remain intact.

**Mark Current Snapshot Reviewed** is an explicit user acknowledgement. Its opaque digest covers task/baseline/HEAD, Index/operation and changed-file content/permissions (bounded to 200 changed files and 64 MiB). Dirty submodules and other changed directory entries cannot generate a receipt until recursive review is supported. Regular files are streamed through bounded descriptors with replacement/modification checks and no retained editor contents. Routine list refreshes invalidate the current badge and read lightweight status; selected-detail refreshes revalidate content. Concurrent requests for the same immutable task record share only the in-flight scan within the workspace budget. Cancelled subscribers leave immediately; the final subscriber cancels the underlying scan, while remaining subscribers keep their result. Completed receipts and modification times never substitute for future content checks. Failed snapshots cannot show a current Reviewed badge; the last receipt remains historical metadata. It is not a test result or automatic completion. GitPier currently records no independently verified task test result; use the terminal to run tests. Existing Stage/Commit/Push/PR workflows retain their own confirmations and checks.

## Archive and removal

Archive changes metadata only. Worktree, branch, commits, ignored/untracked files and unsaved changes stay on disk; archived tasks can be reopened. Active agents cannot be archived.

**Review Worktree Removal…** navigates managed tasks to the existing Worktrees removal workflow. It checks original ownership, unchanged task metadata/filesystem identity, active agents/terminals, drafts, Git state and the existing status/ignored-file/detached-commit protections. Confirmation is separate; changes invalidate the review. No force remove, prune, branch deletion or automatic cleanup is added. External associations have no removal action.

## Local metadata and limits

Default metadata directory: `~/Library/Application Support/GitPier/workspace.tasks/`. A custom workspace uses the adjacent `<workspace-basename>.tasks/` directory. At most 512 tasks/creation reservations use UUID-named schema-1 JSON envelopes (`.json` for tasks, `.creation` for pending records); schema-zero imports are read without an automatic rewrite and migrate on explicit save. A lifetime exclusive owner lock prevents a second application instance from recovering live sessions or removing worktrees through an unavailable task module. A canonical-path lifecycle reservation also blocks process starts while reviewed removal/repair is queued. Descriptor-relative file access, locking and atomic replacement reuse existing private IO; directories are 0700 and files 0600. Invalid permissions, links, oversized/corrupt records and unsupported schemas stop changes and preserve originals.

Metadata includes task/repository UUIDs, paths, common/Git directories, creation receipt, dev/inode identity, branch, baseline SHA, dates/status, optional explicitly saved description, current session metadata and optional review receipt. It excludes prompts/transcripts, source contents, terminal output, tokens, keys and full environments. Descriptions are local metadata, never automatically written into a repository.

## 简体中文

从**工作树 → 任务 → 新建任务**创建独立工作树，选择本地基准、新分支和父目录已存在的新绝对路径。默认使用仓库旁的 UUID 目录，不自动 Fetch 或启动 Codex。可关联已有工作树；外部关联始终保持外部归属，任务元数据不能授予删除权限。移动后复用原工作树安全修复，并核对原目录/Git/Common 的设备与 inode 身份。

创建前先持久化私有待登记记录；Git 创建工作树后，在写入所有权标记前记录原目录/Git/Common 身份。任务与应用所有权均持久化后才报告登记成功，在此之前保留原待登记记录。部分失败明确展示保留路径，不自动删除工作树、分支或文件。重启后可继续登记，核对原身份、仓库族、分支和基准；被替换目录或不同标记会被拒绝。没有捕获原身份时，只能显式忘记私有记录后检查并以外部工作树关联，不能提升所有权。

Codex 完全可选。**设置 → 终端**可指定可执行文件，留空搜索绝对 PATH 与常用目录。主动检测执行有界版本/帮助及完整安全参数组合解析，核对身份及文件，不兼容时拒绝启动。主动“检查登录状态”通过同一可执行文件/环境运行 codex login status，限8秒及每输出流16KiB，可取消；0表示CLI凭证可用，只有退出1并明确返回Not logged in才提示登录，其余错误/超时保持无法确认。输出丢弃，不读认证文件/钥匙串，不调用logout，不后台轮询；登录可用不等于网络、权限或模型成功。登录由Codex官方流程负责。

检测/登录/PTY共享内存中的有效环境，保留HOME、CODEX_HOME、代理和官方认证变量，移除GitPier的Git凭证注入；PATH补充标准目录，不读取Shell配置。Finder/Dock可能缺少Shell变量；高级环境可主动指定已存在、无符号链接的绝对Codex Home，仅影响本应用子进程，不创建专属目录、不复制凭证、不改系统/Shell/Codex配置。未指定时继承CODEX_HOME或遵循CLI默认值，诊断只展示来源。

**启动 Codex…**先展示任务、目录、分支、HEAD、未提交修改、可执行文件/版本和配置。确认后重新核对身份，复用现有 SwiftTerm/PTY，通过一次性管道门捕获进程身份，再由内部启动器打开/核对目录、fchdir 并在执行前复核可执行文件身份，按固定数组运行 `--no-daemon --sandbox workspace-write --ask-for-approval on-request`。检测要求当前工具支持前台模式，不连接共享后台会话。不拼接描述/Prompt，不跳过审批，不放开全部沙箱，不自动恢复执行；Codex 仍使用其原配置与权限机制。GitPier 的 Git 确认无法约束 Codex 内部每条命令，独立 Worktree 也不是系统沙箱。

首次交互会话中，Codex 可能要求保存目录信任决定，GitPier 不会自动接受。验收环境若禁止修改已有 Codex 配置，应在此取消，并将交互编码标为未验证。

切页保留会话；显式停止核对进程启动身份并等待关联进程清理。退出或关闭最后窗口会提示，可取消；无法核验清理则保持应用打开。主动脱离/重设父进程的后台进程可能需要手动检查，不承诺回收所有可能的守护进程。异常重启将活动会话恢复为“已中断”，不会重新执行。等待输入由用户手动标记，不解析终端文字猜测。退出码 0 仅表示 Agent 会话退出，不表示任务或测试成功。

审查同时包含**基准 → HEAD / 提交**与**HEAD → Index / 工作树**；复用原比较、提交历史、Diff 与部分暂存。手动“将当前快照标为已审查”只保存有界的内容/Index/HEAD 摘要，列表刷新只读轻量状态并使当前徽标失效，详情刷新重新读取内容；同一任务并发请求只合并正在执行的扫描，并受共享预算限制；取消订阅者立即返回，最后一人取消时停止底层扫描，其他订阅者不受影响，不按mtime或旧回执跳过内容。普通文件以有界描述符流式读取并核对替换/修改，失败不显示当前已审查；脏子模块或目录条目拒绝生成回执。这不是测试通过或任务自动完成。目前没有已核验的任务测试记录，可打开终端运行。提交、推送及 PR 继续使用原确认流程，操作中心仅观察和导航，不新增 Git 队列。

归档只改变任务元数据，保留工作树、分支、提交及所有文件，可重新打开；活动 Agent 不可归档。移除为单独操作，进入原工作树审查，继续核对任务 UUID/快照、原始归属、文件系统身份、活动会话、草稿、Git 操作、未跟踪/忽略文件和分离提交保留条件。外部关联不提供移除，不使用 force/prune，不自动删分支或清理。

默认任务元数据位于 `~/Library/Application Support/GitPier/workspace.tasks/`，自定义 workspace 使用旁边的同名 `.tasks/` 目录。schema-1任务及待登记记录合计最多512条、目录0700/文件0600、锁与原子写；实例生命周期独占锁防止第二进程接管活动会话，路径生命周期保留锁防止排队移除/修复期间启动进程；损坏、未来版本、不安全链接/权限等保留原文件并停止修改。保存任务身份、路径、基准、时间/状态、当前会话、审查摘要及用户主动保存的私有描述；不保存对话/Prompt、源码、终端输出、Token/密钥或环境变量全文。
