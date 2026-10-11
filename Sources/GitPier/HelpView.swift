import SwiftUI

struct HelpView: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.colorScheme) var scheme
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 8) {
          Label(store.text("GitPier Help", "GitPier 帮助"), systemImage: "questionmark.circle")
            .font(.largeTitle.weight(.semibold))
          Text(store.text("A guide to your local Git workspace", "本地 Git 工作空间使用指南"))
            .font(.title3).foregroundStyle(.secondary)
        }
        section("Get Started", "开始使用", symbol: "folder") {
          paragraph(
            "Open an existing Git repository or worktree with ⌘O, or choose Clone Repository to download a remote repository. Opening or selecting a repository shows the Commit page. The current page is not saved.",
            "按 ⌘O 打开现有 Git 仓库或 Worktree，也可选择“克隆仓库”下载远程仓库。打开或选择仓库时默认进入提交页，不保存上次页面。")
          paragraph(
            "Create organizations with the folder-plus button. Use the Collapse / Expand All Organizations button to hide or show every organization's repositories. Move repositories through their context menu, and drag within an organization to save their order. Removing a workspace entry preserves its folder on disk.",
            "通过文件夹加号按钮创建组织，使用“收起 / 展开全部组织”按钮隐藏或显示各组织的仓库。使用仓库右键菜单移动组织，在同一组织内拖动以保存顺序。从工作空间移除仓库会保留磁盘目录。")
        }
        section("Review & Commit", "审查与提交", symbol: "checkmark.circle") {
          paragraph(
            "Click a changed file to preview its Diff; double-click to keep the tab open. Use the file checkboxes to choose the files for your next commit, then write a commit message and choose Commit or Commit & Push.",
            "点击变更文件预览 Diff，双击保留标签。勾选要提交的文件，填写提交说明，然后选择“提交”或“提交并推送”。")
          paragraph(
            "Checkboxes do not change the Git Index. Existing partial staging and changes staged by other tools are preserved. Stage / Unstage and hunk actions explicitly change the Index. Destructive actions ask for confirmation.",
            "勾选不会修改 Git Index，并保留已有部分暂存和其他工具的暂存内容。“暂存 / 取消暂存”和差异块操作会明确修改 Index，破坏性操作需要确认。")
          paragraph(
            "The Diff settings menu controls unified view, wrapping, line numbers and whitespace. Each side scrolls horizontally; vertical scrolling is synchronized. An empty old side is hidden for newly added files.",
            "Diff 设置菜单提供统一视图、换行、行号和空白选项。两侧独立水平滚动并同步垂直滚动；新增文件的旧侧为空时自动隐藏。")
          paragraph(
            "Lists, settings, help, commit messages, tabs and terminal scrollback use the same compact overlay scrollbars. Scroll or drag a thumb to brighten it; it fades after scrolling pauses.",
            "列表、设置、帮助、提交说明、标签栏和终端缓冲区使用相同的短覆盖滑块。滚动或拖动滑块时加深，停顿后淡化。")
        }
        section("Resolve Conflicts", "解决冲突", symbol: "arrow.triangle.merge") {
          paragraph(
            "New conflicts open Resolve Conflicts automatically. You can also open it from the operation banner, a conflicted file's Diff or context menu, or the toolbar menu. Compare Current (Ours), Incoming (Theirs), and the optional Base preview. During rebase, Current is the rebase target; Incoming is the replayed commit.",
            "出现新冲突时会自动进入“解决冲突”，也可从操作提示条、冲突文件的 Diff 或右键菜单、工具栏菜单打开。对照当前版本（Ours）、传入版本（Theirs），可选择预览共同祖先。变基时，当前版本是变基目标，传入版本是重放的提交。"
          )
          paragraph(
            "Use the arrows to select a conflict and choose Current, Incoming or Both, or edit the Result directly. Drafts stay with each repository and file while switching pages. Save & Mark Resolved asks before writing and staging that file. Remove all conflict markers first. External changes require Reload and another review; the existing draft is kept until you confirm reloading. Closing the last window or quitting asks before discarding unsaved conflict drafts.",
            "使用箭头选择冲突块，采用当前、传入或双方内容，也可直接编辑合并结果。切换页面或文件时，草稿随仓库和文件保留。“保存并标记解决”会先确认，再写入并仅暂存此文件；保存前必须清除冲突标记。外部修改发生后需重新加载并审查，确认重新加载前会保留原草稿。关闭最后一个窗口或退出时，会先确认是否丢弃未保存的冲突草稿。"
          )
          paragraph(
            "After saving every file, review the staged merge result and continue. If the conflict came from Merge & Push, choose Review, Continue & Push to finish the original destination. UTF-8 text up to 1 MiB is editable. Binary and larger files allow Current, Incoming or Delete choices. Symlink, submodule and file-type conflicts use your external editor or terminal.",
            "保存所有冲突文件后，审查已暂存结果并继续合并。若冲突来自“合并并推送”，可选择“审查、继续并推送”完成原目标。内置编辑支持 1 MiB 以内的 UTF-8 文本；二进制和更大文件可选择当前、传入版本或删除。符号链接、子模块及文件类型冲突需使用外部编辑器或终端。"
          )
        }
        section("History & Layout", "历史与布局", symbol: "clock") {
          paragraph(
            "Select a history row to inspect changed files and compare the commit with its parent or another commit. Click the same row again, press Esc, or use the close button to dismiss the details.",
            "点击历史记录查看变更文件，并与父提交或其他提交比较。再次点击同一条记录、按 Esc 或点击关闭按钮可收起详情。")
          paragraph(
            "Drag the history divider to resize the details, and the vertical divider to resize its file list. These sizes are saved per repository and restored after switching pages or restarting GitPier.",
            "拖动历史分隔线调整详情高度，拖动竖向分隔线调整文件列表宽度。尺寸按仓库保存，在切换页面或重启 GitPier 后恢复。")
          paragraph(
            "Use ⌘R to refresh. Clicking a repository or returning to GitPier also refreshes visible data. Optional external-change watching shows a reminder. Restore pane sizes in Settings → Appearance.",
            "按 ⌘R 刷新。点击仓库或切回 GitPier 也会刷新可见数据；可选外部变更监听会显示提示。可在“设置 → 外观”重置面板尺寸。")
        }
        section("Editors, Terminal & Credentials", "编辑器、终端与凭证", symbol: "terminal") {
          paragraph(
            "Settings → General lists installed editors with their application icons in priority order. Select your default editor, or use Choose Application at the bottom to add a custom App. In repository and commit-file context menus, expand Open in Editor and select an application from its native submenu. This choice applies only to the current action.",
            "“设置 → 常规”按优先级列出已安装编辑器及其应用图标。选择默认编辑器，或通过下拉末尾的“选择应用”添加自定义 App。在仓库和提交文件的右键菜单中，展开“在编辑器中打开”，从带应用图标的原生子菜单选择编辑器，仅为本次操作指定应用。"
          )
          paragraph(
            "Toggle the terminal with ⌥F12. Shell commands run in the repository with your user permissions. Hidden sessions keep running; closing a session stops its shell and attached jobs.",
            "按 ⌥F12 显示或隐藏终端。Shell 命令以当前用户权限在仓库中运行；隐藏时会话继续运行，关闭会话会停止 Shell 和关联作业。")
          paragraph(
            "Add HTTPS tokens or SSH profiles in Settings → Credentials, then select them in Repository Settings. Tokens are stored in macOS Keychain. Existing Git helpers, hooks and signing remain enabled; GitPier does not automatically change global Git or SSH configuration.",
            "在“设置 → 凭证”添加 HTTPS Token 或 SSH 配置，并在仓库设置中选择。Token 保存在 macOS Keychain 中。既有 Git 凭证助手、Hooks 和签名仍有效；GitPier 不会自动修改全局 Git 或 SSH 配置。"
          )
        }
        section("Keyboard Shortcuts", "键盘快捷键", symbol: "keyboard") {
          shortcut("⌘O", "Open repository", "打开仓库")
          shortcut("⌘R", "Refresh current repository", "刷新当前仓库")
          shortcut("⌘1 / ⌘2 / ⌘3", "Commit / History / Branches", "提交 / 历史 / 分支")
          shortcut("⌘F", "Search the current page or terminal", "搜索当前页面或终端")
          shortcut("⌥F12", "Toggle terminal", "显示 / 隐藏终端")
          shortcut("⌘T", "New terminal tab while terminal is focused", "终端获得焦点时新建标签")
          shortcut("⌘W", "Close active Diff or focused terminal tab", "关闭当前 Diff 或获得焦点的终端标签")
          shortcut("Esc", "Close history details outside the terminal", "终端以外关闭历史详情")
          shortcut("⌘⇧/", "Open GitPier Help", "打开 GitPier 帮助")
        }
        section("Troubleshooting", "问题排查", symbol: "wrench.and.screwdriver") {
          paragraph(
            "Check the final operation message after a fetch, pull or push. If Commit & Push fails during push, the local commit remains. When the remote branch has new commits, confirm Merge & Push to fetch, merge, then push. Commit or stash remaining tracked changes first. Conflicts stop the push: resolve and stage the files, Continue the merge, then retry Push. Cancelling the confirmation preserves your local commit. Other remote errors can be corrected before retrying Push; choose an upstream when prompted.",
            "获取、拉取或推送后请查看最终操作结果。“提交并推送”在推送阶段失败时，本地提交仍保留。远程分支有新提交时，确认“合并并推送”即可获取、合并后推送；剩余的已跟踪文件修改需先提交或 Stash。出现冲突时停止推送：解决并暂存文件，点击“继续”完成合并，再重试推送。取消确认会保留本地提交。其他远程错误解决后可重试推送，缺少 Upstream 时按提示选择。")
          paragraph(
            "If authentication fails, check the selected credential and remote URL. If Git cannot start, check Settings → Git → Git Executable. Share a reproducible example and remove private paths, tokens and repository content from reports.",
            "认证失败时检查所选凭证与远程地址。Git 无法启动时检查“设置 → Git → Git 可执行文件”。报告问题时提供可复现示例，并移除私人路径、Token 和仓库内容。")
          Link(
            store.text("Report an Issue on GitHub", "在 GitHub 报告问题"),
            destination: URL(string: "https://github.com/Heisenberg2024/gitpier/issues")!)
        }
      }.padding(28).frame(maxWidth: 760).frame(maxWidth: .infinity, alignment: .center)
    }.textSelection(.enabled).background(Theme.editor(scheme))
  }
  private func section<Content: View>(
    _ english: String, _ chinese: String, symbol: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(store.text(english, chinese), systemImage: symbol).font(.title3.weight(.semibold))
      content()
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func paragraph(_ english: String, _ chinese: String) -> some View {
    Text(store.text(english, chinese)).fixedSize(horizontal: false, vertical: true)
      .foregroundStyle(.secondary)
  }
  private func shortcut(_ keys: String, _ english: String, _ chinese: String) -> some View {
    HStack {
      Text(keys).font(.system(.body, design: .monospaced)).frame(width: 150, alignment: .leading)
      Text(store.text(english, chinese))
    }
  }
}
