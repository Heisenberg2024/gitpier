# Operations Center

## v2.1.0 development: explicit Push verification

An ordinary single-branch Push retains a session-only `PushCheckpoint`: original working tree, source branch/full commit, named remote, exact destination ref and opaque configuration/directory identities. No raw URL or credential is copied into operation history. Broad/custom multi-ref, mirror, follow-tags or recursive-writing configurations require manual inspection. Chained URL rewrites, a URL interpreted as another named remote, custom URL helpers and named custom transports are also excluded from automatic completion proof. Authentication-context changes invalidate the checkpoint.

**Verify Remote** explicitly resolves the current effective **Push URL**, checks the captured target, runs bounded read-only `ls-remote --refs` for the exact ref, and revalidates identity. Only a complete exact Hash match confirms the saved checkpoint. A different/absent ref, malformed/truncated output, changed target or connection error leaves the result unconfirmed. Fetch snapshots do not prove Push completion.

**Review Retry Push…** opens the existing confirmation. The service rechecks the original source branch/HEAD and target, queries the remote first and sends only the fixed saved commit if needed. A matching remote skips another transfer. It never repeats Commit, silently changes the target or forces an update. Verification resolves only the matching original record and preserves its diagnosis. Copy Commit Hash and Open History are read-only conveniences.

Active, waiting, unknown and needs-attention results survive the 100 completed-summary limit. These checkpoints remain session-only; no second durable journal or restored running process is introduced.

简体中文：2.1.0 开发版按操作保留原工作树、分支、完整提交、命名 Remote、精确引用及不透明身份，不保存原 URL/凭证。**核实远端**仅由用户主动触发，复核实际 Push URL、目录与配置后只读查询精确引用并再次复核；完整且相同的 Hash 才确认，不同/缺失/截断/异常均维持未确认。**审查重试推送**通过原确认框重新核对原分支/HEAD/目标，先查询远端，需要时仅推送固定已保存提交，已匹配则不再次发送；不重复 Commit、不 Force、不静默改目标。完整 Hash 复制、历史入口和原诊断保持可用。活动、等待、未知及需处理记录不受最近 100 条已完成摘要限制，仍仅保留本次会话。

## v2.0.0 diagnostics and native presentation

Operations capture the working-tree path and a successful local commit's full-hash checkpoint, so later Push failure/cancellation retains its local result. **Details** can retain each operation's user-facing diagnostic, redacted before truncation to both 4,096 characters and 16 KiB UTF-8. Later successful work preserves that earlier cause. Closing a visible error Sheet remains respected after final refresh. These records stay session-only.

Shared state symbols preserve the distinctions between success, failure, cancellation, waiting and attention; Branch Health keeps its separate synchronization/ancestry model. Progress labels, dates and numbers follow the selected interface language. Native sheets and nested diagnostic views use the existing overlay scrollbars on both axes.

简体中文：v2.0.0记录实际工作树和本地提交完整Hash；推送准备失败或取消仍保留本地结果。每次操作的详情先脱敏，再同时限4,096字符和16KiB UTF-8；后续成功操作保留原诊断，最终刷新尊重已关闭的错误弹窗。普通历史仍只在会话内；图标、语言适配、原生弹窗和双轴嵌套滚动复用既有实现。

Open **Operations Center** from the main toolbar's task-count button or **Quick Open → Commands**. It shows Active, Attention and Recent records shared by all workspace windows. Opening or closing this panel does not start, repeat or stop Git work.

The center observes existing Clone, repository Git actions, manual/batch/automatic Fetch, Commit, Pull, Push, Merge, Rebase, Worktree creation/removal and confirmed Review submissions. Local status/Diff/history scans do not create user task records. Automatic Fetch replaces its previous completed summary for the same repository to avoid a periodic history flood.

Queued and running tasks are distinct. A cancellation request remains **Cancelling…** until the existing execution owner finishes. The final result can still be success, failure, cancellation or a request for attention. Cancellation does not promise rollback of local changes or non-delivery of remote writes. Non-cancellable commit phases remain protected. There is no generic replay button.

Recent completed non-sensitive summaries are bounded to 100 in memory. Active/waiting tasks, unknown/needs-attention results and unresolved Review journal entries are retained while needed. Normal transient tasks are not restored as running after restart. Review recovery uses the existing v1.6.1 journal alone; the center does not copy Review request bodies, commands or stored credential data into history or create a second journal. Unknown Review results link to the existing **Review History** inspection and acknowledgement UI, with no automatic replay.

**Open Repository** returns to the existing repository workflow. Conflict/Rebase/upstream recovery snapshots revalidate repository root, Common Directory, HEAD/Index/operation identity and remotes before reuse. Changed contexts require a fresh repository review. Mutating buttons continue to perform their original confirmations and in-queue checks. Ahead/behind counts describe local tracking references from Fetch snapshots, not live server state.

Repository-level [contextual advice](context-workflow.md) explains the next useful step and reuses existing reviews and confirmations.

**⌘⇧P Quick Open** remains the single palette, with Repositories, Commands, Recent and Favorites. Commands reuse existing navigation and panels; unavailable commands show their reason. Up/Down, Return and Esc remain sheet-local. The global shortcut retains the terminal focus guard. Recent command choices stay in memory.

## History retention decision

Ordinary operations remain **session-only**. They summarize work owned by existing executors; restoring those summaries would not restore a process or establish whether an interrupted Git command completed. Periodic automatic Fetch would also duplicate the existing persisted last-check/backoff metadata. Its repository status is refreshed from Git on the next launch. The panel states this boundary explicitly and retains at most 100 recent summaries.

Confirmed remote Review writes have a different recovery requirement: an interrupted request may already have reached the server. Their existing durable Review Journal remains the authority across restarts, including Unknown results. It is not replaced or duplicated by operation history. If cross-session diagnostics become a requirement, add a separately designed opt-in diagnostic export rather than replayable task records.

## 简体中文

主工具栏的任务数量按钮和快速打开的命令页均可进入**操作中心**。正在执行、需要处理、最近完成三个分区在所有工作空间窗口间共享。打开/关闭面板不会启动、重复或取消 Git 操作。

汇总既有 Clone、Git 操作、手动/批量/自动 Fetch、Commit、Pull、Push、Merge、Rebase、工作树创建/移除和确认后的审查提交。本地状态、Diff、历史扫描不生成用户任务。自动 Fetch 按仓库合并上次完成摘要。

取消中仍等待执行方返回最终结果；成功、失败、取消或需要处理均可能成为最终状态。取消不表示本地变更已回滚，也不能证明远端未收到写入。提交原子阶段不可取消，没有通用“重放上次命令”。

内存保留最近100条已完成普通摘要；活动/等待、未知/需处理任务和未决审查日志按需要保留。重启不恢复普通运行中假象，审查继续复用v1.6.1唯一持久化日志，审查请求正文/命令或已存凭证不复制到操作摘要；有界脱敏的用户可见诊断按上述会话规则保留。结果未知只能进入既有审查历史核查，不自动重发。

恢复入口复核仓库、Common Directory、HEAD、Index、Git操作身份和Remote；变化后要求重新审查。原写入确认与队列检查保持。[仓库上下文建议](context-workflow.md)解释当前状态、原因并复用既有审查与确认；远程跟踪计数明确来自 Fetch 快照。

**⌘⇧P**继续使用原有快速打开，增加仓库/命令/最近/收藏。命令复用原页面和弹窗，禁用项展示原因；方向键、回车和Esc限定于当前面板窗口，终端焦点保护保持。最近命令仅保存在内存。

持久化评估：普通操作继续采用**会话级记录**。操作摘要无法恢复已经结束的进程，也不能证明中断的 Git 命令是否完成；启动后仍需从 Git 重新读取真实状态。自动获取已有最近检查、认证和退避元数据，长期保存每次任务会重复记录。界面明确说明本次会话及最近 100 条的边界。

远端审查可能已经送达服务器，必须保留跨重启核实能力，因此继续由唯一的持久化 Review Journal 保存 Unknown 等恢复信息，操作中心只展示该权威来源。后续若需要跨会话排障，宜另行设计主动导出诊断，不将历史摘要恢复为可执行任务。
