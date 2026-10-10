import GitPierCore
import SwiftUI

struct HistoryView: View {
  @ObservedObject var model: RepositoryModel
  @EnvironmentObject var store: AppStore
  @Environment(\.colorScheme) var scheme
  @FocusState private var searchFocused: Bool
  @State private var search = ""
  @State private var selected: CommitRecord?
  @State private var branchAt: String?
  @State private var branchName = ""
  var records: [CommitRecord] {
    model.history.filter {
      search.isEmpty || $0.subject.localizedCaseInsensitiveContains(search)
        || $0.author.localizedCaseInsensitiveContains(search) || $0.hash.hasPrefix(search)
    }
  }
  var graph: [String: GraphRow] { model.historyGraph }
  var body: some View {
    VSplitView {
      VStack(spacing: 0) {
        HStack {
          Text(store.text("History", "历史")).font(uiFont(size: 13, weight: .semibold))
          if let fileFilter = model.historyPath {
            Badge(text: fileFilter)
            IconButton("xmark", help: localizedUI("Clear File Filter")) {
              model.historyPath = nil
              Task { await model.loadHistory(reset: true) }
            }
          }
          Spacer()
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField(store.text("Search loaded commits", "搜索已加载提交"), text: $search).textFieldStyle(
            .plain
          ).frame(width: 200)
        }.font(uiFont(size: 11)).padding(12).background(Theme.panel(scheme))
        Divider()
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(records) { commit in
              HStack(spacing: 12) {
                GraphRowView(row: graph[commit.hash]).frame(width: 92, height: 43)
                VStack(alignment: .leading, spacing: 4) {
                  Text(commit.subject).font(uiFont(size: 12, weight: .medium)).lineLimit(1)
                  if !commit.decorations.isEmpty {
                    Text(commit.decorations).font(uiFont(size: 9)).foregroundStyle(.mint)
                      .lineLimit(1)
                  }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(commit.author).font(uiFont(size: 11)).foregroundStyle(.secondary).frame(
                  width: 125, alignment: .leading
                ).lineLimit(1)
                Text(commit.date, style: .date).font(uiFont(size: 10)).foregroundStyle(.secondary)
                  .frame(width: 92)
                Text(String(commit.hash.prefix(8))).font(uiFont(size: 11, design: .monospaced))
                  .foregroundStyle(.secondary).frame(width: 70)
              }.padding(.trailing, 12).frame(height: 43).background(
                selected?.hash == commit.hash ? Color.accentColor.opacity(0.14) : Color.clear
              ).contentShape(Rectangle())
                .onTapGesture { selected = commit }.contextMenu { historyMenu(commit) }
            }
            if model.historyHasMore {
              Button(store.text("Load more commits", "加载更多提交")) {
                Task { await model.loadHistory(path: model.historyPath) }
              }.padding(15)
            }
            if model.history.isEmpty {
              EmptyState(symbol: "clock", title: store.text("No commits yet", "尚无提交"), detail: "")
            }
          }
        }
      }.frame(minHeight: 160)
      if let selected {
        CommitDetailView(model: model, commit: selected).id(selected.hash).frame(minHeight: 220)
      } else {
        EmptyState(
          symbol: "clock", title: store.text("Select a commit", "选择一个提交"),
          detail: store.text(
            "Inspect parents, changed files and patches. Context menus provide history operations.",
            "查看父提交、变更文件和 Diff；右键菜单提供历史操作。")
        ).frame(minHeight: 220)
      }
    }
    .task { await model.ensureHistory() }.onReceive(
      NotificationCenter.default.publisher(for: .gitpierSearch)
    ) { event in if event.object == nil { searchFocused = true } }
    .onReceive(NotificationCenter.default.publisher(for: .gitpierFileHistory)) { notification in
      if let path = notification.object as? String {
        model.historyPath = path
        selected = nil
        Task { await model.loadHistory(reset: true, path: path) }
      }
    }
    .alert(
      store.text("Create Branch Here", "从此处创建分支"),
      isPresented: Binding(get: { branchAt != nil }, set: { if !$0 { branchAt = nil } })
    ) {
      TextField(store.text("Branch name", "分支名称"), text: $branchName)
      Button(store.text("Create", "创建")) {
        if let branchAt {
          model.run { git in try await git.createBranch(branchName, at: branchAt) }
        }
        branchAt = nil
      }
      Button(store.text("Cancel", "取消"), role: .cancel) { branchAt = nil }
    }
  }
  @ViewBuilder func historyMenu(_ commit: CommitRecord) -> some View {
    Button(store.text("Copy Hash", "复制 Hash")) { copyText(commit.hash) }
    Button(store.text("Create Branch Here…", "从此处创建分支…")) {
      branchName = ""
      branchAt = commit.hash
    }
    Divider()
    Button(store.text("Checkout Commit…", "检出提交…")) {
      model.perform(
        ["switch", "--detach", commit.hash],
        confirmation: store.text("Enter detached HEAD at ", "在此提交进入分离 HEAD：")
          + String(commit.hash.prefix(8)))
    }
    Button(localizedUI("Cherry-pick…")) {
      model.perform(
        ["cherry-pick", commit.hash],
        confirmation: store.text("Apply this commit to the current branch?", "将此提交应用到当前分支？"))
    }
    Button(localizedUI("Revert…")) {
      model.perform(
        ["revert", "--no-edit", commit.hash],
        confirmation: store.text("Create a new commit reversing this commit?", "创建反向提交以撤销此提交？"))
    }
    Menu(localizedUI("Reset…")) {
      Button(localizedUI("Soft…")) {
        model.perform(
          ["reset", "--soft", commit.hash],
          confirmation: store.text(
            "Move HEAD and keep Index and working tree. This rewrites local history.",
            "移动 HEAD，保留 Index 与工作区，会改写本地历史。"))
      }
      Button(localizedUI("Mixed…")) {
        model.perform(
          ["reset", "--mixed", commit.hash],
          confirmation: store.text(
            "Move HEAD and reset the Index. Working files remain; staging choices are lost.",
            "移动 HEAD 并重置 Index，保留工作文件，但会丢失暂存选择。"))
      }
      Button(localizedUI("Hard…"), role: .destructive) {
        model.perform(
          ["reset", "--hard", commit.hash],
          confirmation: store.text(
            "PERMANENTLY discard tracked working changes and reset HEAD and Index to ",
            "永久丢弃跟踪文件修改，并将 HEAD 和 Index 重置到：") + commit.hash)
      }
    }
  }
}

struct GraphRowView: View {
  var row: GraphRow?
  let colors: [Color] = [.accentColor, .mint, .orange, .purple, .pink, .cyan]
  var body: some View {
    Canvas { context, size in
      guard let row else { return }
      func x(_ lane: Int) -> CGFloat {
        12 + CGFloat(lane) * min(14, 72 / CGFloat(max(1, row.width)))
      }
      for edge in row.edges {
        var path = Path()
        let start = CGPoint(x: x(edge.from), y: edge.startsAtNode ? size.height / 2 : 0)
        let end = CGPoint(x: x(edge.to), y: edge.endsAtNode ? size.height / 2 : size.height)
        path.move(to: start)
        path.addCurve(
          to: end, control1: CGPoint(x: start.x, y: (start.y + end.y) / 2),
          control2: CGPoint(x: end.x, y: (start.y + end.y) / 2))
        context.stroke(
          path, with: .color(colors[edge.color % colors.count].opacity(0.8)), lineWidth: 1.5)
      }
      let rect = CGRect(x: x(row.node) - 3.5, y: size.height / 2 - 3.5, width: 7, height: 7)
      context.fill(Path(ellipseIn: rect), with: .color(colors[row.node % colors.count]))
    }
  }
}

struct CommitDetailView: View {
  @ObservedObject var model: RepositoryModel
  let commit: CommitRecord
  @EnvironmentObject var store: AppStore
  @Environment(\.colorScheme) var scheme
  @State private var files: [FileChange] = []
  @State private var selected: String?
  @State private var diff = DiffDocument.empty
  @State private var parent = ""
  @State private var customParent = ""
  @State private var loading = false
  @State private var generation = 0
  var body: some View {
    HSplitView {
      VStack(alignment: .leading, spacing: 10) {
        Text(commit.subject).font(uiFont(size: 13, weight: .semibold)).textSelection(.enabled)
        Text(commit.author + " <" + commit.email + ">").font(uiFont(size: 11)).foregroundStyle(
          .secondary
        ).textSelection(.enabled)
        Text(commit.date.formatted()).font(uiFont(size: 10)).foregroundStyle(.secondary)
        if !commit.body.isEmpty {
          ScrollView {
            Text(commit.body).font(uiFont(size: 11)).textSelection(.enabled).frame(
              maxWidth: .infinity, alignment: .leading)
          }.frame(maxHeight: 85)
        }
        HStack {
          Text(localizedUI("Compare")).font(uiFont(size: 10))
          TextField(localizedUI("Parent or commit"), text: $customParent).textFieldStyle(
            .roundedBorder
          ).font(
            .system(size: 10))
          Button(localizedUI("↵")) {
            parent = customParent
            Task { await loadFiles() }
          }.controlSize(.mini)
        }
        if commit.parents.count > 1 {
          Picker(localizedUI("Parent"), selection: $parent) {
            ForEach(commit.parents, id: \.self) { Text(String($0.prefix(8))).tag($0) }
          }.onChange(of: parent) { Task { await loadFiles() } }
        }
        Divider()
        List(files, selection: $selected) { file in
          HStack {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            Text(file.path).font(uiFont(size: 11)).lineLimit(1)
            Spacer()
            Badge(
              text: String(file.index),
              color: file.kind == .added ? .mint : file.kind == .deleted ? .red : .accentColor)
          }.tag(file.path)
        }.listStyle(.plain)
      }.padding(12).frame(minWidth: 240, idealWidth: 280, maxWidth: 350)
      VStack(spacing: 0) {
        HStack {
          Text(
            parent.isEmpty
              ? "Empty tree → " + String(commit.hash.prefix(8))
              : String(parent.prefix(8)) + " → " + String(commit.hash.prefix(8)))
          Spacer()
          if let selected {
            Button(localizedUI("Copy Patch")) { copyText(diff.raw) }
            Text(selected).lineLimit(1)
          }
        }.font(uiFont(size: 10)).padding(10).background(Theme.panel(scheme))
        Divider()
        if loading {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if selected == nil {
          EmptyState(
            symbol: "doc.text", title: store.text("Select a changed file", "选择变更文件"), detail: "")
        } else if diff.binary {
          EmptyState(
            symbol: "doc.richtext", title: store.text("Binary changes", "二进制变更"), detail: diff.raw)
        } else {
          DiffTable(
            document: diff, path: selected ?? "",
            key: model.record.id.uuidString + commit.hash + (selected ?? "") + parent,
            settings: store.settings, dark: scheme == .dark, selectedHunk: 0)
        }
      }.frame(minWidth: 300)
    }.task {
      parent = commit.parents.first ?? ""
      customParent = parent
      await loadFiles()
    }.onChange(of: selected) { Task { await loadPatch() } }
  }
  func loadFiles() async {
    do {
      files = try await model.git().commitFiles(commit.hash, parent: parent.isEmpty ? nil : parent)
      selected = files.first?.path
      await loadPatch()
    } catch { model.error = error.localizedDescription }
  }
  func loadPatch() async {
    generation += 1
    let request = generation
    diff = .empty
    guard let selected else { return }
    loading = true
    do {
      let bytes = try await model.git().commitPatch(
        commit.hash, path: selected, parent: parent.isEmpty ? nil : parent)
      guard request == generation else { return }
      diff = DiffParser.parse(bytes)
      loading = false
    } catch {
      if request == generation {
        loading = false
        model.error = error.localizedDescription
      }
    }
  }
}
