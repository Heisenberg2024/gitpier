import GitPierCore
import SwiftUI

struct HostingReviewerPicker: View {
  @EnvironmentObject var store: AppStore
  @ObservedObject var session: HostingReviewSession
  @State private var search = ""
  @State private var selected: Set<String> = []
  private var candidates: [HostingReviewer] {
    session.reviewerCandidates.filter { search.isEmpty || $0.login.localizedCaseInsensitiveContains(search) || $0.name.localizedCaseInsensitiveContains(search) }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(store.text("Request Reviewers", "请求审查者")).font(.title2.weight(.semibold))
      Text(session.displayName).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      Label(store.text("This requests user reviewers and may notify them on the platform. Existing reviewers are preserved. GitLab reviewers are not the same as approvers.", "此操作请求用户审查，可能向其发送平台通知。已有审查者会保留，GitLab 审查者与审批者并非同一概念。"), systemImage: "bell")
        .font(.callout).foregroundStyle(.secondary)
      if !session.existingReviewers.isEmpty {
        Text(store.text("Existing reviewers (preserved): ", "已有审查者（保留）：") + session.existingReviewers.map { "@" + $0.login }.joined(separator: ", "))
          .font(.caption).textSelection(.enabled).lineLimit(3)
      }
      TextField(store.text("Search loaded candidates", "搜索已加载的候选用户"), text: $search).textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("hosting.review.reviewer-search")
      if session.reviewerLoading { HStack { ProgressView().controlSize(.small); Text(store.text("Loading reviewers…", "正在加载审查者…")) }.font(.caption) }
      if let error = session.reviewerError { HStack { Text(error).foregroundStyle(.orange); Button(store.text("Retry", "重试")) { session.loadReviewers(more: false) } }.font(.caption) }
      List {
        ForEach(candidates) { user in
          let existing = session.existingReviewers.contains(where: { $0.id == user.id })
          Toggle(isOn: Binding(get: { selected.contains(user.id) }, set: { value in if value { selected.insert(user.id) } else { selected.remove(user.id) } })) {
            HStack {
              VStack(alignment: .leading, spacing: 3) {
                Text("@" + user.login).fontWeight(.medium)
                if !user.name.isEmpty { Text(user.name).font(.caption).foregroundStyle(.secondary) }
              }
              Spacer()
              if existing { Text(store.text("Already Requested", "已请求")).font(.caption).foregroundStyle(.secondary) }
              else if user.id == session.context?.authorID { Text(store.text("Request Author", "请求作者")).font(.caption).foregroundStyle(.secondary) }
            }
          }.disabled(existing || user.id == session.context?.authorID || session.reviewerLoading || (selected.count >= 15 && !selected.contains(user.id)))
        }
        if session.reviewerNextPage != nil { Button(store.text("Load More Candidates", "加载更多候选用户")) { session.loadReviewers(more: true) }.disabled(session.reviewerLoading) }
      }.frame(minHeight: 180)
      Text(store.text("Selected: ", "已选择：") + "\(selected.count) / 15").font(.caption).foregroundStyle(.secondary)
      HStack {
        Button(store.text("Cancel", "取消")) { session.reviewersPresented = false }.keyboardShortcut(.cancelAction)
        Spacer()
        Button(store.text("Preview Request…", "预览请求…")) { session.stageReviewers(session.reviewerCandidates.filter { selected.contains($0.id) }) }
          .buttonStyle(.borderedProminent).disabled(selected.isEmpty || session.reviewerLoading || !session.identityValid)
          .accessibilityIdentifier("hosting.review.preview-reviewers")
      }
    }.padding(22).frame(width: 620, height: 570)
  }
}
