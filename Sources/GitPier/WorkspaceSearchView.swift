import AppKit
import GitPierCore
import SwiftUI

struct WorkspaceSearchView: View {
  typealias Scope = WorkspaceSearchScope
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  @State private var query = ""
  @State private var scope = Scope.all
  @State private var kinds: Set<WorkspaceSearchKind> = [.repository, .file, .commit]
  @State private var hits: [WorkspaceSearchHit] = []
  @State private var errors: [UUID: String] = [:]
  @State private var more: Set<UUID> = []
  @State private var page = 0
  @State private var loading = false
  @State private var generation = UUID()
  @FocusState private var focused: Bool
  private let service = WorkspaceSearchService()
  var records: [RepositoryRecord] {
    scope.records(from: store.repositories, dashboard: store.showDashboard, organization: store.dashboardOrganization,
      currentID: store.selectedID, selected: store.workspace.selected)
  }
  var requestID: String { query + ":" + scope.rawValue + ":" + kinds.map(\.rawValue).sorted().joined() + ":" + records.map { $0.id.uuidString + $0.path }.joined() }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(store.text("Workspace Search", "工作空间搜索")).font(.title2.weight(.semibold))
      TextField(store.text("Repository, tracked path, commit message or hash", "仓库、已跟踪路径、提交信息或哈希"), text: $query)
        .textFieldStyle(.roundedBorder).focused($focused)
      HStack {
        Picker(store.text("Scope", "范围"), selection: $scope) {
          Text(store.text("All Repositories", "所有仓库")).tag(Scope.all)
          Text(store.text("Current Organization", "当前组织")).tag(Scope.organization)
          Text(store.text("Current Repository", "当前仓库")).tag(Scope.current)
          Text(store.text("Selected Repositories", "已选仓库")).tag(Scope.selected)
        }.frame(width: 240)
        ForEach(WorkspaceSearchKind.allCases, id: \.self) { kind in
          Toggle(kindName(kind), isOn: Binding(get: { kinds.contains(kind) }, set: {
            if $0 { kinds.insert(kind) } else { kinds.remove(kind) }
          })).toggleStyle(.checkbox)
        }
      }
      Text(store.text("File and commit queries start after two characters. Results are local, bounded and never uploaded.", "输入两个字符后按需查询文件和提交。结果仅来自本地，数量受限且不会上传。"))
        .font(.system(size: 11)).foregroundStyle(.secondary)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          ForEach(WorkspaceSearchKind.allCases, id: \.self) { kind in
            let results = hits.filter { $0.kind == kind }
            if !results.isEmpty {
              Text(kindName(kind)).font(.headline)
              ForEach(results) { hit in
                Button {
                  Task { if await store.workspace.openSearchHit(hit) { dismiss() } }
                } label: {
                  VStack(alignment: .leading, spacing: 3) {
                    Text(kind == .commit ? hit.detail : hit.value).lineLimit(2)
                    Text((store.repositories.first { $0.id == hit.repositoryID }?.name ?? "") + " · " + (kind == .commit ? String(hit.value.prefix(12)) : hit.detail))
                      .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                  }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.workspace)
              }
              Divider()
            }
          }
          ForEach(records.filter { errors[$0.id] != nil }) { record in
            Text(record.name + ": " + (errors[record.id] ?? "")).foregroundStyle(.orange).font(.system(size: 11)).textSelection(.enabled)
          }
          if hits.isEmpty && !loading { Text(store.text("No results", "没有结果")).foregroundStyle(.secondary) }
        }
      }
      HStack {
        if loading { ProgressView().controlSize(.small); Text(store.text("Searching…", "正在搜索…")) }
        Spacer()
        if !more.isEmpty { Button(store.text("Load More", "加载更多")) { page += 1 }.disabled(loading) }
        Button(store.text("Close", "关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
      }
    }.padding(24).frame(width: 760, height: 550)
      .onAppear { focused = true }
      .onReceive(store.workspace.$entries) { entries in
        guard kinds.contains(.repository) else { return }
        let values = records.map { entries[$0.id] ?? WorkspaceEntry(record: $0) }
        hits = WorkspaceSearchService.metadata(values, query: query) + hits.filter { $0.kind != .repository }
      }
      .task(id: requestID) { await search(reset: true) }
      .task(id: page) { if page > 0 { await search(reset: false) } }
  }
  private func kindName(_ kind: WorkspaceSearchKind) -> String {
    switch kind {
    case .repository: return store.text("Repositories", "仓库")
    case .file: return store.text("Files", "文件")
    case .commit: return store.text("Commits", "提交")
    }
  }
  private func search(reset: Bool) async {
    let ticket = UUID(); generation = ticket
    let requestedQuery = query, requestedKinds = kinds, requestedRecords = records
    if reset { page = 0; hits = []; errors = [:]; more = []; loading = true }
    else { loading = true }
    defer { if generation == ticket { loading = false } }
    do {
      if reset {
        let entries = requestedRecords.map { store.workspace.entries[$0.id] ?? WorkspaceEntry(record: $0) }
        if requestedKinds.contains(.repository) { hits = WorkspaceSearchService.metadata(entries, query: requestedQuery) }
        try await Task.sleep(for: .milliseconds(250))
      }
      let result = try await service.search(records: reset ? requestedRecords : requestedRecords.filter { more.contains($0.id) },
        query: requestedQuery, kinds: requestedKinds, page: page)
      guard !Task.isCancelled, generation == ticket else { return }
      var seen = Set(hits.map(\.id)); hits += result.hits.filter { seen.insert($0.id).inserted }
      errors.merge(result.errors) { _, new in new }; more = result.moreRepositories
    } catch is CancellationError {} catch {
      if generation == ticket, !Task.isCancelled { store.error = error.localizedDescription }
    }
  }
}

extension WorkspaceModel {
  func openSearchHit(_ hit: WorkspaceSearchHit) async -> Bool {
    guard let record = store.repositories.first(where: { $0.id == hit.repositoryID }), let model = store.models[record.id] else {
      store.error = store.text("The repository was removed from this workspace.", "仓库已从工作空间移除。"); return false
    }
    store.select(record.id)
    await model.activate(refresh: true)
    guard store.selectedID == record.id, store.repositories.contains(where: { $0.id == record.id && $0.path == record.path }), model.available else {
      store.error = store.text("The repository is unavailable or changed while opening the result.", "打开结果时仓库不可用或已发生变化。"); return false
    }
    if hit.kind == .file {
      if let file = model.status.files.first(where: { $0.path == hit.value }) { model.select(file, permanent: true) }
      else {
        model.historyPath = hit.value; model.setPage("history")
        await model.loadHistory(reset: true, path: hit.value)
      }
    } else if hit.kind == .commit {
      do {
        let commit = try await model.git().commitDetail(hit.value)
        guard store.selectedID == record.id else { return false }
        model.historyPath = nil; model.setPage("history"); await model.ensureHistory()
        model.selectedHistoryCommit = commit
      } catch { store.error = GitService.redact(error.localizedDescription); return false }
    }
    return true
  }
}
