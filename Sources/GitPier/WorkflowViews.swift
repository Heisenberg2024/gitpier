import GitPierCore
import SwiftUI

struct BranchesView: View {
  @ObservedObject var model: RepositoryModel
  @EnvironmentObject var store: AppStore
  @State private var search = ""
  @State private var creating = false
  @State private var name = ""
  @State private var startingAt = ""
  @State private var workflowContext: ContextWorkflowReview?
  @State private var retainingHead: String?
  @State private var renaming: String?
  @State private var renamed = ""
  @State private var upstreamFor: String?
  @State private var upstreamName = ""
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(store.text("Branches", "分支")).font(.title3.weight(.semibold))
        Spacer()
        TextField(store.text("Search branches", "搜索分支"), text: $search).frame(width: 200)
        Button(store.text("Compare Branches", "比较分支")) { model.setPage("compare") }
        Button(store.text("New Branch…", "新建分支…")) { workflowContext = nil; retainingHead = nil; creating = true }
      }.padding(18)
      Divider()
      if let retainingHead {
        HStack {
          Text(store.text("Local branches retaining ", "保留此提交的本地分支：") + String(retainingHead.prefix(12))).font(.callout)
          Spacer()
          Button(store.text("Show all branches", "显示全部分支")) { self.retainingHead = nil }
        }.padding(.horizontal, 18).padding(.bottom, 8)
      }
      List {
        Section(store.text("Local", "本地")) {
          ForEach(
            model.branches.filter {
              !$0.remote && (retainingHead == nil || $0.hash == retainingHead) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
            }
          ) { branch in row(branch) }
        }
        Section(store.text("Remote", "远程")) {
          ForEach(
            model.branches.filter {
              retainingHead == nil && $0.remote && !$0.name.hasSuffix("/HEAD")
                && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
            }
          ) { branch in row(branch) }
        }
      }.listStyle(.inset).disabled(model.busy)
    }
    .onAppear { consumeWorkflowRequest() }
    .onChange(of: model.workflowBranchRequest?.id) { _, _ in consumeWorkflowRequest() }
    .alert(store.text("Create Branch", "创建分支"), isPresented: $creating) {
      TextField(store.text("Branch name", "分支名称"), text: $name)
      TextField(store.text("Start at (empty = HEAD)", "起点（留空为 HEAD）"), text: $startingAt)
      Button(store.text("Create", "创建")) {
        let name = name
        let reference = startingAt
        let context = workflowContext
        model.run { git in
          try model.validateWorkflowSelection(context)
          try await git.createBranch(name, at: reference.isEmpty ? nil : reference, context: context)
        }
        self.name = ""
        startingAt = ""
      }
      Button(store.text("Cancel", "取消"), role: .cancel) {}
    }
    .alert(
      store.text("Set Branch Upstream", "设置分支 Upstream"),
      isPresented: Binding(get: { upstreamFor != nil }, set: { if !$0 { upstreamFor = nil } })
    ) {
      TextField("origin/branch", text: $upstreamName)
      Button(store.text("Save", "保存")) {
        if let branch = upstreamFor {
          let upstream = upstreamName, context = workflowContext
          model.run { git in
            try model.validateWorkflowSelection(context)
            try InputValidation.reference(upstream)
            try await git.perform(["branch", "--set-upstream-to=" + upstream, branch], context: context)
          }
        }
        upstreamFor = nil
      }
      Button(store.text("Cancel", "取消"), role: .cancel) { upstreamFor = nil }
    }
    .alert(
      store.text("Rename Branch", "重命名分支"),
      isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    ) {
      TextField(store.text("New name", "新名称"), text: $renamed)
      Button(store.text("Rename", "重命名")) {
        if let old = renaming {
          let new = renamed
          model.run(updatesCommitState: old == model.status.branch ? .checkout : nil) { git in
            try InputValidation.reference(new)
            try await git.perform(["check-ref-format", "--branch", new])
            try await git.perform(["branch", "-m", old, new])
          }
        }
        renaming = nil
      }
      Button(store.text("Cancel", "取消"), role: .cancel) { renaming = nil }
    }
  }
  private func consumeWorkflowRequest() {
    guard let request = model.workflowBranchRequest else { return }
    model.workflowBranchRequest = nil
    workflowContext = request.context
    search = ""; retainingHead = nil
    switch request.intent {
    case .create:
      name = ""; startingAt = request.context.status.head ?? ""; creating = true
    case .upstream:
      upstreamFor = request.context.status.branch
      upstreamName = request.context.status.upstream ?? ""
    case .retainingCommit: retainingHead = request.context.status.head
    }
  }
  func row(_ branch: GitBranch) -> some View {
    HStack(spacing: 12) {
      Image(systemName: branch.current ? "checkmark.circle.fill" : "arrow.triangle.branch")
        .foregroundStyle(branch.current ? Color.mint : .secondary)
      VStack(alignment: .leading, spacing: 4) {
        Text(branch.name).font(uiFont(size: 13, weight: .medium))
        if !branch.upstream.isEmpty {
          Text(branch.upstream + " " + branch.tracking).font(uiFont(size: 10)).foregroundStyle(
            .secondary)
        }
      }
      Spacer()
      Text(String(branch.hash.prefix(8))).font(uiFont(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
      if !branch.current {
        Button(store.text("Switch", "切换")) {
          model.run(updatesCommitState: .checkout) { git in try await git.switchBranch(branch.name, remote: branch.remote) }
        }.controlSize(.small)
      }
    }.padding(.vertical, 8)
      .contextMenu {
        if !branch.current {
          Button(store.text("Switch", "切换")) {
            model.run(updatesCommitState: .checkout) { git in try await git.switchBranch(branch.name, remote: branch.remote) }
          }
        }
        Button(store.text("Compare with Current Branch", "与当前分支比较")) {
          model.comparisonRight = branch.reference
          model.setPage("compare")
        }
        Button(store.text("Copy Name", "复制名称")) { copyText(branch.name) }
        if !branch.remote {
          Button(store.text("Rename…", "重命名…")) {
            renaming = branch.name
            renamed = branch.name
          }
          Button(store.text("Set Upstream…", "设置 Upstream…")) {
            workflowContext = nil
            upstreamFor = branch.name
            upstreamName = branch.upstream
          }
        }
        Divider()
        Button(store.text("Merge into ", "合并至 ") + model.status.branch + "…") {
          model.perform(
            ["merge", "--no-edit", branch.reference],
            confirmation: store.text(
              "Merge this branch into the current branch? Git will retain conflict state if resolution is needed.",
              "合并至当前分支？如需解决冲突，Git 会保留冲突状态。"))
        }.disabled(branch.current)
        Button(localizedUI("Rebase onto…")) {
          model.perform(
            ["rebase", branch.reference],
            confirmation: store.text(
              "Replay the current branch onto this branch? This rewrites local history.",
              "将当前分支变基到此分支？这会重写本地历史。"))
        }.disabled(branch.current)
        if !branch.remote {
          Button(store.text("Delete Branch…", "删除分支…"), role: .destructive) {
            model.perform(
              ["branch", "-d", branch.name],
              confirmation: store.text(
                "Delete this local branch? Unmerged branches are protected by Git.",
                "删除此本地分支？Git 会保护未合并分支。"))
          }.disabled(branch.current)
        } else {
          let parts = branch.name.split(separator: "/", maxSplits: 1).map(String.init)
          if parts.count == 2 {
            Button(store.text("Delete Remote Branch…", "删除远程分支…"), role: .destructive) {
              model.confirmRemoteDeletion(remote: parts[0], reference: "refs/heads/" + parts[1], expectedHash: branch.hash)
            }
          }
        }
      }
  }
}

struct RemotesView: View {
  @ObservedObject var model: RepositoryModel
  @EnvironmentObject var store: AppStore
  @State private var editing = false
  @State private var workflowContext: ContextWorkflowReview?
  @State private var original: GitRemote?
  @State private var name = ""
  @State private var fetchURL = ""
  @State private var pushURL = ""
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(store.text("Remotes", "远程")).font(.title3.weight(.semibold))
        Spacer()
        Button(store.text("Fetch All", "获取全部")) { model.network("fetch") }
        Button(store.text("Add Remote…", "添加 Remote…")) {
          workflowContext = nil
          original = nil
          name = ""
          fetchURL = ""
          pushURL = ""
          editing = true
        }
      }.padding(18)
      Divider()
      List(model.remotes) { remote in
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Label(remote.name, systemImage: "network").font(uiFont(size: 14, weight: .semibold))
            Spacer()
            Button(localizedUI("Fetch")) { model.network("fetch", remote: remote.name) }
            Button(localizedUI("Edit…")) {
              workflowContext = nil
              original = remote
              name = remote.name
              fetchURL = remote.configuredFetchURLs.first ?? remote.fetchURL
              pushURL = remote.configuredPushURLs.first ?? ""
              editing = true
            }
          }
          Text("Fetch  " + remote.fetchURL).font(uiFont(size: 11, design: .monospaced))
            .textSelection(.enabled)
          Text("Push   " + remote.pushURL).font(uiFont(size: 11, design: .monospaced))
            .textSelection(.enabled).foregroundStyle(.secondary)
          HStack {
            Button(localizedUI("Push Tags")) { model.perform(["push", remote.name, "--tags"]) }
            Button(localizedUI("Set Upstream…")) { model.needsUpstream = true }
            Button(localizedUI("Force with Lease…")) {
              model.confirmForcePush(remote: remote.name)
            }
            Spacer()
            Button(store.text("Remove…", "移除…"), role: .destructive) {
              model.perform(
                ["remote", "remove", remote.name],
                confirmation: store.text(
                  "Remove the remote configuration and tracking references? The server repository is preserved.",
                  "移除 Remote 配置及跟踪引用？服务器仓库将保留。"))
            }
          }.controlSize(.small)
        }.padding(.vertical, 14)
      }.listStyle(.inset).disabled(model.busy)
    }.onAppear { consumeWorkflowRequest() }
      .onChange(of: model.workflowRemoteRequest?.id) { _, _ in consumeWorkflowRequest() }
      .sheet(isPresented: $editing) {
      VStack(alignment: .leading, spacing: 14) {
        Text(localizedUI(original == nil ? "Add Remote" : "Edit Remote")).font(.title2)
        TextField(localizedUI("Name"), text: $name).disabled(original != nil)
        TextField(localizedUI("Fetch URL"), text: $fetchURL)
        TextField(localizedUI("Push URL (optional)"), text: $pushURL)
          .disabled((original?.configuredPushURLs.count ?? 0) > 1)
        if let original, original.configuredPushURLs.count > 1 {
          Text(store.text("Multiple push URLs are preserved. Use the terminal to edit them.",
                          "保留全部 Push URL；请在终端编辑多个推送地址。"))
            .font(.caption).foregroundStyle(.secondary)
        } else {
          Text(store.text("Leave Push URL empty to use the fetch URL.", "Push URL 留空时使用 Fetch URL。"))
            .font(.caption).foregroundStyle(.secondary)
        }
        Text(
          store.text("Secrets belong in Credentials, not remote URLs.", "请在凭证中保存秘密，不要将其写入 URL。 ")
        ).font(.callout).foregroundStyle(.secondary)
        HStack {
          Spacer()
          Button(localizedUI("Cancel")) { editing = false }
          Button(localizedUI("Save")) {
            let name = name
            let fetch = fetchURL
            let push = pushURL
            let original = original, context = workflowContext
            model.run { git in
              try model.validateWorkflowSelection(context)
              try await git.saveRemote(name: name, fetchURL: fetch, pushURL: push, expected: original, context: context)
            }
            editing = false
          }.buttonStyle(.borderedProminent).disabled(name.isEmpty || fetchURL.isEmpty || model.busy)
        }
      }.textFieldStyle(.roundedBorder).padding(24).frame(width: 550)
    }
  }
  private func consumeWorkflowRequest() {
    guard let request = model.workflowRemoteRequest else { return }
    model.workflowRemoteRequest = nil
    workflowContext = request.context
    original = nil; name = ""; fetchURL = ""; pushURL = ""; editing = true
  }

}

struct StashView: View {
  @ObservedObject var model: RepositoryModel
  @EnvironmentObject var store: AppStore
  @Environment(\.colorScheme) var scheme
  @State private var creating = false
  @State private var message = ""
  @State private var includeUntracked = false
  @State private var selected: GitStash?
  var body: some View {
    VSplitView {
      VStack(spacing: 0) {
        HStack {
          Text(localizedUI("Stashes")).font(.title3.weight(.semibold))
          Spacer()
          Button(localizedUI("Create Stash…")) { creating = true }
        }.padding(18)
        Divider()
        List(model.stashes) { stash in
          HStack {
            VStack(alignment: .leading, spacing: 5) {
              Text(stash.reference).font(uiFont(size: 11, design: .monospaced)).foregroundStyle(
                .secondary)
              Text(stash.message).font(uiFont(size: 12))
            }
            Spacer()
            Button(localizedUI("Apply")) {
              model.run(updatesCommitState: .index) { git in model.output = try await git.stashOperation("apply", stash: stash)
              }
            }
            Button(localizedUI("Pop…")) {
              model.confirmation = PendingAction(
                title: store.text("Pop Stash?", "应用并移除 Stash？"),
                detail: store.text(
                  "Apply and remove this stash? Conflicts keep the stash intact.",
                  "应用并移除此 Stash？发生冲突时保留 Stash。") + "\n" + stash.message
              ) {
                model.run(updatesCommitState: .index) { git in model.output = try await git.stashOperation("pop", stash: stash)
                }
              }
            }
            Button(localizedUI("Drop…"), role: .destructive) {
              model.confirmation = PendingAction(
                title: store.text("Drop Stash?", "丢弃 Stash？"),
                detail: store.text("Permanently remove these saved changes?", "永久移除这些保存的修改？") + "\n"
                  + stash.message
              ) {
                model.run { git in model.output = try await git.stashOperation("drop", stash: stash)
                }
              }
            }
          }.padding(.vertical, 8).contentShape(Rectangle()).onTapGesture {
            selected = stash
          }.listRowBackground(selected?.hash == stash.hash ? Color.accentColor.opacity(0.12) : Color.clear)
        }.listStyle(.inset).disabled(model.busy)
      }.frame(minHeight: 180)
      if let selected {
        StashPreviewView(model: model, stash: selected).id(selected.hash)
          .frame(minHeight: 240)
      } else {
        EmptyState(
          symbol: "tray", title: store.text("Select a stash", "选择一个 Stash"),
          detail: store.text(
            "Saved changes remain available if applying them causes conflicts.", "应用发生冲突时，保存的修改会保留。"
          )
        ).frame(minHeight: 200)
      }
    }.onChange(of: model.stashes) { _, stashes in
      if let selected, !stashes.contains(where: { $0.hash == selected.hash }) { self.selected = nil }
    }.sheet(isPresented: $creating) {
      VStack(alignment: .leading, spacing: 16) {
        Text(localizedUI("Create Stash")).font(.title2)
        TextField(localizedUI("Message"), text: $message)
        Toggle(localizedUI("Include Untracked Files"), isOn: $includeUntracked)
        HStack {
          Spacer()
          Button(localizedUI("Cancel")) { creating = false }
          Button(localizedUI("Stash")) {
            let message = message
            let untracked = includeUntracked
            model.perform(
              ["stash", "push"] + (untracked ? ["--include-untracked"] : []) + ["-m", message])
            creating = false
          }.buttonStyle(.borderedProminent)
        }
      }.padding(24).frame(width: 460)
    }
  }
}

struct TagsView: View {
  @ObservedObject var model: RepositoryModel
  @EnvironmentObject var store: AppStore
  @State private var creating = false
  @State private var name = ""
  @State private var message = ""
  @State private var reference = ""
  @State private var annotated = false
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(store.text("Tags", "标签")).font(.title3.weight(.semibold))
        Spacer()
        Button(store.text("Create Tag…", "创建标签…")) { creating = true }
      }.padding(18)
      Divider()
      List(model.tags, id: \.self) { tag in
        HStack {
          Label(tag, systemImage: "tag").font(uiFont(size: 12))
          Spacer()
          Menu(localizedUI("Push")) {
            ForEach(model.remotes) { remote in
              Button(remote.name) { model.perform(["push", remote.name, "refs/tags/" + tag]) }
            }
          }
          Menu(localizedUI("Delete…")) {
            Button(localizedUI("Delete Local Tag…"), role: .destructive) {
              model.perform(
                ["tag", "-d", tag],
                confirmation: store.text("Delete local tag ", "删除本地标签 ") + tag + "?")
            }
            ForEach(model.remotes) { remote in
              Button(
                store.text("Delete from ", "从此 Remote 删除：") + remote.name + "…", role: .destructive
              ) {
                model.confirmRemoteDeletion(remote: remote.name, reference: "refs/tags/" + tag)
              }
            }
          }
        }.padding(.vertical, 8)
      }.listStyle(.inset).disabled(model.busy)
    }.sheet(isPresented: $creating) {
      VStack(alignment: .leading, spacing: 14) {
        Text(localizedUI("Create Tag")).font(.title2)
        TextField(localizedUI("Tag name"), text: $name)
        TextField(localizedUI("Commit (empty = HEAD)"), text: $reference)
        Toggle(localizedUI("Annotated Tag"), isOn: $annotated)
        if annotated { TextField(localizedUI("Message"), text: $message) }
        HStack {
          Spacer()
          Button(localizedUI("Cancel")) { creating = false }
          Button(localizedUI("Create")) {
            let name = name
            let ref = reference
            let message = message
            let annotated = annotated
            model.run { git in
              try InputValidation.reference(name)
              try await git.perform(["check-ref-format", "refs/tags/" + name])
              if !ref.isEmpty { try InputValidation.reference(ref) }
              try await git.perform(
                ["tag"] + (annotated ? ["-a", "-m", message] : []) + [name]
                  + (ref.isEmpty ? [] : [ref]))
            }
            creating = false
          }.buttonStyle(.borderedProminent).disabled(model.busy || name.isEmpty || annotated && message.isEmpty)
        }
      }.textFieldStyle(.roundedBorder).padding(24).frame(width: 460)
    }
  }
}
