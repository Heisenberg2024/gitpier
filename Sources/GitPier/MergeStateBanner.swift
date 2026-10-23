import GitPierCore
import SwiftUI

/// Merge progress belongs to the repository, even when there are no changed files.
struct MergeStateBanner: View {
  @ObservedObject var model: RepositoryModel
  @EnvironmentObject var store: AppStore
  private var conflicts: Int { model.status.files.filter(\.isConflicted).count }
  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: "arrow.triangle.merge").foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 3) {
        Text(store.text(
          conflicts > 0 ? "Merge in progress · unresolved conflicts" : "Merge awaiting completion",
          conflicts > 0 ? "合并进行中 · 存在未解决冲突" : "合并尚待完成"))
          .font(.callout.weight(.semibold))
        Text(detail).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }.frame(maxWidth: .infinity, alignment: .leading)
      if conflicts > 0 {
        Button(store.text("Resolve Conflicts…", "解决冲突…")) { model.openConflicts() }
          .disabled(model.busy || model.refreshing).accessibilityIdentifier("gitpier.merge.resolve")
      } else {
        Button(store.text("Review Merge…", "审查合并…")) { model.reviewMergeContinuation() }
          .disabled(!model.canContinueMerge).accessibilityIdentifier("gitpier.merge.review")
      }
      Button(store.text("Abort…", "中止…")) {
        model.perform(["merge", "--abort"], confirmation: store.text(
          "Abort this merge and return to the state before it began? The branches may still diverge. Review any edits made since the merge started before aborting.",
          "中止本次合并并回到合并开始前的状态？两条分支仍可能分叉。中止前请审查合并开始后所做的修改。"))
      }.disabled(model.busy || model.refreshing).accessibilityIdentifier("gitpier.merge.abort")
    }.padding(.horizontal, 14).padding(.vertical, 10).background(Color.orange.opacity(0.07))
      .accessibilityElement(children: .contain).accessibilityIdentifier("gitpier.merge.state")
  }
  private var detail: String {
    if conflicts > 0 {
      return store.text(
        "\(conflicts) unresolved files. Save each resolution, then review and complete the merge.",
        "还有 \(conflicts) 个未解决文件。保存各文件的解决结果后，请审查并完成合并。")
    }
    if model.snapshot?.paths.isEmpty == true {
      return store.text(
        "No staged content changes. A merge commit is still needed to record the joined histories.",
        "当前没有暂存内容差异，仍需创建合并提交以记录两条历史的合并关系。")
    }
    return store.text(
      "Review the staged result and complete the merge. Unstaged edits stay outside the merge commit.",
      "请审查已暂存的结果并完成合并。未暂存修改不会纳入合并提交。")
  }
}
