import GitPierCore
import SwiftUI

struct WorkspaceFetchPresentation: ViewModifier {
  @EnvironmentObject var store: AppStore
  @ObservedObject var workspace: WorkspaceModel
  func body(content: Content) -> some View {
    content.sheet(isPresented: Binding(get: { workspace.showFetchReview }, set: {
      if !$0 { workspace.cancelFetchReview() }
    })) { WorkspaceFetchReview(workspace: workspace).environmentObject(store).interactiveDismissDisabled(workspace.submittingFetch) }
  }
}

struct WorkspaceFetchReview: View {
  @EnvironmentObject var store: AppStore
  @ObservedObject var workspace: WorkspaceModel
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(store.text("Fetch Selected Repositories", "获取已选仓库")).font(.title2.weight(.semibold))
      Text(store.text("Review each physical repository and remote. Related worktrees share one Fetch. The working tree and Index remain intact.", "请审查每个物理仓库及远程。关联工作树共用一次获取，工作区和暂存区保持不变。"))
      if workspace.preparingFetch { ProgressView(store.text("Reading remote configuration…", "正在读取远程配置…")) }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 14) {
          ForEach(workspace.fetchTargets) { target in
            VStack(alignment: .leading, spacing: 4) {
              Text(target.record.name + " · " + target.remote.name).fontWeight(.semibold)
              Text(target.record.path).foregroundStyle(.secondary)
              Text(target.remote.fetchURL).textSelection(.enabled)
              if target.repositoryIDs.count > 1 { Text(store.text("\(target.repositoryIDs.count) selected entries share this remote", "\(target.repositoryIDs.count) 个所选条目共用此远程")).foregroundStyle(.secondary) }
            }.font(.system(size: 12))
            Divider()
          }
          ForEach(Array(workspace.fetchReviewErrors.enumerated()), id: \.offset) { _, error in Text(error).foregroundStyle(.orange).textSelection(.enabled) }
        }
      }
      HStack {
        Spacer()
        Button(store.text("Cancel", "取消")) { workspace.cancelFetchReview() }.disabled(workspace.submittingFetch).keyboardShortcut(.cancelAction)
          .keyboardShortcut(.defaultAction)
        Button(store.text("Fetch", "获取")) { workspace.startReviewedFetch() }
          .disabled(workspace.preparingFetch || workspace.submittingFetch || workspace.fetchTargets.isEmpty)
      }
    }.padding(24).frame(width: 650, height: 470)
  }
}

struct WorkspaceFetchTray: View {
  @EnvironmentObject var store: AppStore
  @ObservedObject var workspace: WorkspaceModel
  @State private var expanded = false
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.down" : "chevron.right") }.buttonStyle(.plain)
        if workspace.manuallyFetching { ProgressView().controlSize(.mini) }
        Text(summary)
        Spacer()
        if workspace.fetchJobs.contains(where: { $0.state == .failed }) {
          Button(store.text("Review Failed…", "审查失败项…")) { workspace.retryFailedFetch() }
        }
        if workspace.manuallyFetching { Button(store.text("Cancel Fetch", "取消获取")) { workspace.cancelFetch() } }
      }
      if expanded {
        ScrollView {
          LazyVStack(alignment: .leading) {
            ForEach(workspace.fetchJobs) { job in
              HStack(alignment: .top) {
                Text(job.target.record.name + " · " + job.target.remote.name)
                Text(stateName(job.state)).foregroundStyle(job.state == .failed ? .orange : .secondary)
                if !job.summary.isEmpty { Text(job.summary).lineLimit(3).textSelection(.enabled).help(job.summary) }
                Spacer()
                if job.state == .failed { Button(store.text("Retry…", "重试…")) { workspace.prepareFetch(job.target.repositoryIDs) } }
              }
            }
          }
        }.frame(maxHeight: 105)
      }
    }.font(uiFont(size: 11)).padding(.horizontal, 24).padding(.bottom, workspace.fetchTrayExpanded ? 12 : 4)
      .onChange(of: workspace.fetchTrayExpanded) { _, value in if !value { expanded = false } }
      .onChange(of: expanded) { _, value in if value { workspace.revealFetchTray() } }
  }
  var summary: String {
    let success = workspace.fetchJobs.filter { $0.state == .succeeded }.count
    let failed = workspace.fetchJobs.filter { $0.state == .failed }.count
    let cancelled = workspace.fetchJobs.filter { $0.state == .cancelled }.count
    let active = workspace.fetchJobs.filter(\.active).count
    if !workspace.fetchTrayExpanded { return store.text("Last Fetch · \(success) succeeded · Show details", "上次获取 · \(success) 成功 · 展开详情") }
    return store.text("Fetch · \(success) succeeded · \(failed) failed · \(cancelled) cancelled · \(active) pending",
      "获取 · \(success) 成功 · \(failed) 失败 · \(cancelled) 取消 · \(active) 待完成")
  }
  func stateName(_ state: WorkspaceFetchState) -> String {
    switch state {
    case .queued: return store.text("Queued", "等待中")
    case .running: return store.text("Fetching", "正在获取")
    case .succeeded: return store.text("Succeeded", "成功")
    case .failed: return store.text("Failed", "失败")
    case .cancelled: return store.text("Cancelled", "取消")
    }
  }
}
