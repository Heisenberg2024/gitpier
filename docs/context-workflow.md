# Contextual workflow — v1.7.0

Click the **lightbulb to the left of the branch name** in the repository toolbar. It opens a native macOS popover with one prioritized suggestion, its reason and relevant existing actions. The toolbar stays 43pt high; the former permanent advice region is removed and its space belongs to the file list, Diff and commit controls again. The popover never opens automatically.

| Toolbar state | Meaning |
| --- | --- |
| Neutral outline lightbulb | No priority suggestion, including ordinary changes already open on the Commit page |
| Accent filled lightbulb | An ordinary next step is available |
| Orange circle in a subtle capsule | Review needed: incoming commits, divergence, stale/unavailable context or unreliable tracking information |
| Orange triangle with a small marker | Preserve local changes before integration, or retain detached HEAD work |
| Red octagon with a small marker | Real unmerged paths, or a Git operation that must be completed/aborted first |

All five states reserve the same 30×23pt toolbar slot and share their semantics with the popover heading, native tooltip and accessibility value. A branch behind its local tracking snapshot by 240 commits is attention, never an invented conflict. The entry has existing hover/pressed feedback. There are no repeating animations or motion-dependent warnings.

The popover is 400pt wide and measures its content up to 440pt high, letting the native host follow its measured SwiftUI height so short content needs no unnecessary scrolling. Longer content scrolls inside that bound. Its background, arrow, border and shadow belong to the system NSPopover material; no SwiftUI presentation-background override or whole-window alpha is applied. This retains one continuous native surface that follows appearance, increased contrast and Reduce Transparency. Content uses the existing appearance anchors and Diff overlay scrollbars. Repository, branch, path, tracking snapshot/counts and last Fetch have distinct text levels; actions reuse the main workspace button feedback. Escape, outside click and a second activation of the entry dismiss it; there is no close button. Escape/entry dismissal restores keyboard focus. Changing repository, Worktree, branch or window closes the old presentation and cancels its pending review. Same-branch updates refresh open content in place.

On the Commit page, ordinary staged/unstaged/untracked changes are quiet and do not produce another “View changes” navigation button. Opening the assistant still explains the actual counts and that the changes remain uncommitted. Conflicts and integration risks stay prominent on that page. A clean local-only repository is not told to add a remote just to populate the popover. Aligned state means the recorded **local tracking snapshot** matches; unknown, skipped, failed or expired Fetch information is never called synchronized.

Advice reuses `ContextWorkflowAdvice`, `RepositoryModel` and the existing remote-check metadata. Filesystem identity is cached off the main thread during the existing refresh; toolbar/popover rendering performs no filesystem scan, Git command or authentication/network request. A one-minute clock only ages cached Fetch information. Commit, Stash/Restore, Fetch/Pull/Push, conflict resolution, foreground refresh and opt-in external-change notifications use the existing refresh/invalidation paths. No new automatic Fetch policy or settings are introduced.

Clicking an action dismisses the popover before opening the original page, form, Fetch review, recovery UI or confirmation. The immutable target review and original write queue checks remain: current selection/page/status, filesystem identities, working tree/Common/Git directories, HEAD/branch, Index, unfinished operation, remotes/configuration and resolved upstream tip. Late or cancelled results cannot create a confirmation for a newer context. Read-only comparison opens immediately, resolves the configured upstream in the background and pins both resolved commits for results, pagination and Diff; it does not scan the Index/worktree or wait for write review. Pull/Push review presents the existing PendingAction immediately in a native sheet that updates preparation, details and the disabled/enabled write button in place; the original guarded action and queue checks remain unchanged. Cancelling that loading review prevents late results from reopening it. Fetch still requires its original explicit start; Merge/Rebase do not automatically Push. Broad/custom Push and multiple-merge Pull configurations remain outside this recommendation path. Hooks, signing, credentials, SSH/TLS checks, partial staging and original advanced controls stay intact.

The assistant answers “what matters next, and why.” Operations Center remains the owner of task progress, results and history; the popover contains no duplicate task list, executor or journal.

## 简体中文

入口是**仓库内容区工具栏中、分支名称左边的灯泡图标**。点击后打开原生 Popover，按优先级突出一条建议、原因及关联操作。工具栏仍为 43pt，原顶部常驻区域已移除，文件列表、Diff 和提交控件获得释放的空间；普通状态变化不会自动弹出。

状态分五级：中性空心灯泡表示无优先建议；强调色实心灯泡表示普通建议；橙色圆形提示配浅胶囊表示需审查的传入提交、分叉或不可靠上下文；橙色三角形配小标记表示整合前需保留修改或游离 HEAD；红色八边形配小标记表示真实冲突或必须先完成/中止的 Git 操作。落后跟踪快照 240 个提交属于注意，不会伪装成冲突。五级均占固定 30×23pt，入口、标题、系统 Tooltip 和可访问性文字共享状态来源。复用主界面 Hover/Pressed 反馈，无持续动画，也不依赖动画表达风险。

浮层宽 400pt，直接测量内容并交给原生托管器自动适配高度，上限 440pt；较短内容完整展示，较长内容在限定高度内滚动。背景、箭头、边缘和阴影交给系统 NSPopover 的原生材质，移除 SwiftUI presentationBackground 覆盖，不降低整个窗口的 alpha；材质随主题、高对比度和降低透明度设置响应。内容继续安装原外观锚点和 Diff 覆盖滚动条。仓库、分支、路径、跟踪快照/计数和上次获取分层展示，操作复用主界面按钮反馈。已移除关闭按钮；Esc、外部点击和再次激活入口可关闭，Esc/入口关闭后恢复键盘焦点。切换仓库、Worktree、分支或窗口会关闭旧浮层并取消待处理审查；同分支状态变化在已展开浮层内更新。

已经位于提交页时，普通已暂存/未暂存/未跟踪修改不会重复突出“查看修改”按钮；主动打开后仍显示实际数量，并明确修改尚未提交。冲突等风险不因打开相关页面而降级或被认为已解决。干净的本地仓库也不会被强行要求添加 Remote。上游一致仅描述本地获取快照，未知、失败、跳过或过期的远端信息不显示为已同步。

继续复用原建议模型、仓库状态和远端检查元数据。文件系统身份随既有刷新在主线程外缓存；工具栏和浮层渲染不扫描文件、不执行 Git、不访问凭证或网络。一分钟界面时钟只更新获取新鲜度。提交、Stash/Restore、获取/拉取/推送、冲突处理、前台刷新和已启用的外部变更通知继续使用原更新路径，不增加自动 Fetch 策略或设置。

点击动作先关闭浮层，再进入原页面、表单、Fetch 审查、恢复界面或确认框。保留不可变目标审查及原队列内的路径/文件系统/Common/Git 目录、HEAD/分支、Index、操作身份、Remote/配置和上游提交复核，并检查当前页面及状态；迟到或取消的结果不能为新上下文创建确认。只读比较先立即打开页面，后台解析实际配置的上游，并固定结果、分页及 Diff 使用的两端提交；不扫描 Index/工作区，也不等待写操作复核。拉取/推送先在原 PendingAction 的原生 Sheet 中显示准备状态，原位置更新审查资料，完整审查通过后才启用原写入动作；取消后迟到结果不会重新打开确认框。不自动暂存、提交、Stash、同步或重放命令；保留 Hooks、签名、认证、TLS/SSH 校验、部分暂存和原高级操作。外部 Git 在检查后仍可改变状态，最终由原安全检查及 Git 冲突/拒绝规则处理。

上下文工作流回答“当前最值得处理什么及原因”；操作中心继续负责执行过程、结果和历史。浮层不复制完整任务列表，也不建立第二套执行器或日志。
