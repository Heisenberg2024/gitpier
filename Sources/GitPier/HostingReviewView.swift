import GitPierCore
import SwiftUI

struct HostingReviewView: View {
  @EnvironmentObject var store: AppStore
  @ObservedObject var session: HostingReviewSession
  @State private var section = 0
  @State private var discard = false
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Picker("", selection: $section) {
          Text(store.text("Timeline", "时间线")).tag(0)
          Text(store.text("Review Draft", "审查草稿") + " (\(session.draft?.comments.count ?? 0))").tag(1)
        }.pickerStyle(.segmented).frame(maxWidth: 340)
        Spacer()
        if session.context?.capabilities.contains(.requestReviewers) == true {
          Button(store.text("Request Reviewers…", "请求审查者…")) { session.beginReviewers() }.disabled(!session.canCompose)
        }
        if session.context?.capabilities.contains(.generalComment) == true {
          Button(store.text("Add Comment", "添加评论")) { session.begin(.comment) }.disabled(!session.canCompose)
            .accessibilityIdentifier("hosting.review.add-comment")
        }
        Button { session.start(refresh: true) } label: { Image(systemName: "arrow.clockwise") }
          .help(store.text("Refresh Reviews", "刷新审查")).disabled(session.contextLoading || session.submitting)
      }
      HostingReviewStatus(session: session)
      if section == 0 { timeline } else { draft }
      if session.composer != nil { Divider(); HostingReviewComposer(session: session) }
    }
    .onAppear { session.start() }
    .sheet(isPresented: $session.reviewersPresented, onDismiss: { session.prepareStagedReviewers() }) { HostingReviewerPicker(session: session).environmentObject(store) }
    .alert(store.text("Discard this review draft?", "丢弃此审查草稿？"), isPresented: $discard) {
      Button(store.text("Keep Editing", "继续编辑"), role: .cancel) {}
      Button(store.text("Discard", "丢弃"), role: .destructive) { session.discardDraft() }
    }
  }
  private var timeline: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 14) {
        if session.account.instance.provider == .gitlab { gitlabProjectState }
        ForEach(session.orderedThreads) { thread in
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Label(sourceTitle(thread.source), systemImage: thread.source == .inline ? "text.bubble" : "bubble.left.and.bubble.right")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
              if thread.state != .unknown { Text(stateTitle(thread.state)).font(.caption.weight(.medium)) }
              if let resolved = thread.resolved { Text(resolved ? store.text("Resolved", "已解决") : store.text("Unresolved", "未解决")).font(.caption) }
              Spacer()
            }
            ForEach(thread.comments) { comment in
              VStack(alignment: .leading, spacing: 6) {
                HStack {
                  Text(String(comment.author.prefix(1)).uppercased()).font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22).background(.quaternary, in: Circle()).accessibilityHidden(true)
                  Text("@" + comment.author).font(.caption.weight(.semibold))
                  Text(comment.createdAt).font(.caption2).foregroundStyle(.secondary)
                  if comment.outdated || (!comment.commitSHA.isEmpty && comment.commitSHA != session.context?.revision.headSHA) { Label(store.text("Outdated", "已过时"), systemImage: "clock.arrow.circlepath").font(.caption2) }
                  Spacer()
                  if let url = comment.webURL { Link(store.text("Open", "打开"), destination: url).font(.caption) }
                }
                if !comment.path.isEmpty {
                  Text(comment.path + ((comment.newLine ?? comment.oldLine).map { ":" + (comment.startLine.map { String($0) + "–" } ?? "") + String($0) }
                    ?? store.text(" · line unavailable", " · 行号不可用")))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if comment.replyToID != nil { Label(store.text("Thread Reply", "线程回复"), systemImage: "arrow.turn.up.left").font(.caption2).foregroundStyle(.secondary) }
                Text(comment.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if canReply(thread, comment: comment) {
                  Button(store.text("Reply", "回复")) { session.begin(.reply(thread, comment)) }.font(.caption).disabled(!session.canCompose)
                    .accessibilityIdentifier("hosting.review.reply." + comment.id)
                }
              }.padding(.leading, comment.replyToID == nil ? 0 : 16)
            }
            if (thread.hasMoreReplies && !session.replyLoaded.contains(thread.id)) || session.replyPages[thread.id] != nil {
              Button(store.text("Load Replies", "加载回复")) { session.loadReplies(thread) }.disabled(session.replyLoading.contains(thread.id))
            }
            if let error = session.replyErrors[thread.id] {
              HStack { Text(error).foregroundStyle(.orange); Button(store.text("Retry Replies", "重试回复")) { session.loadReplies(thread) } }.font(.caption)
            }
            if thread.state == .pending, session.account.instance.provider == .github, thread.comments.first?.authorID == session.account.user.stableID {
              Button(store.text("Submit Pending Review…", "提交待定审查…")) { session.preparePending(thread) }.disabled(!session.canCompose)
              Text(store.text("The platform's summary is preserved unless you enter a replacement in Review Draft. Choose the decision there before confirming.", "未在审查草稿中输入替代总结时，会保留平台原总结。请先在草稿中选择审查决定，再确认提交。")).font(.caption2).foregroundStyle(.secondary)
            }
            if thread.canResolve, let resolved = thread.resolved, session.context?.capabilities.contains(.resolveDiscussion) == true {
              Button(resolved ? store.text("Unresolve Discussion…", "重新打开讨论…") : store.text("Resolve Discussion…", "解决讨论…")) {
                session.prepareResolution(thread, resolved: !resolved)
              }.disabled(!session.canCompose).accessibilityIdentifier("hosting.review.resolve." + thread.remoteID)
            }
          }.padding(12).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        }
        ForEach(HostingReviewSource.allCases, id: \.self) { source in
          let state = session.states[source] ?? HostingDetailLoadState()
          if state.loading { HStack { ProgressView().controlSize(.small); Text(sourceTitle(source) + store.text(" · Loading…", " · 正在加载…")) }.font(.caption) }
          if let error = state.error {
            HStack {
              Text(sourceTitle(source) + ": " + session.message(error)).foregroundStyle(.orange).textSelection(.enabled)
              Spacer(); Button(store.text("Retry", "重试")) { session.load(source) }
            }.font(.caption)
          }
          if session.nextPages[source] != nil { Button(store.text("Load More ", "加载更多") + sourceTitle(source)) { session.load(source, more: true) }.disabled(state.loading) }
        }
        if HostingReviewSource.allCases.allSatisfy({ session.states[$0]?.loaded == true }), session.orderedThreads.isEmpty {
          Text(store.text("No Reviews or Comments", "暂无审查或评论")).foregroundStyle(.secondary).padding(.vertical, 20)
        }
      }.padding(2)
    }.accessibilityIdentifier("hosting.review.timeline")
  }
  private var gitlabProjectState: some View {
    DisclosureGroup(store.text("GitLab Project Rules & Reviewers", "GitLab 项目规则与审查者")) {
      VStack(alignment: .leading, spacing: 10) {
        Text(store.text("Individual approval, project approval rules, reviewers and unresolved discussions are separate platform concepts. These details load only when requested.", "个人批准、项目审批规则、审查者与未解决讨论属于不同的平台概念，以下详情仅在主动加载时读取。"))
          .font(.caption).foregroundStyle(.secondary)
        HStack {
          Text(store.text("Approval Rules", "审批规则")).font(.headline)
          Spacer(); Button(store.text("Load Approval Rules", "加载审批规则")) { session.loadApprovalRules() }.disabled(session.approvalRulesLoading)
          if session.approvalRulesLoading { ProgressView().controlSize(.small) }
        }
        if let error = session.approvalRulesError { Text(error).foregroundStyle(.orange).font(.caption).textSelection(.enabled) }
        if let value = session.approvalRules {
          switch value.availability {
          case .permissionRequired:
            Text(store.text("Permission is required to read project approval rules. Discussions and individual approval remain independent.", "读取项目审批规则需要额外权限，讨论与个人批准仍独立处理。 ")).font(.caption).foregroundStyle(.orange)
          case .unavailable:
            Text(store.text("This instance or tier does not expose approval-rule details. This does not mean the request has no approval requirements.", "此实例或套餐未开放审批规则详情，这不代表此请求没有审批要求。 ")).font(.caption).foregroundStyle(.secondary)
          case .available:
            if value.rules.isEmpty { Text(store.text("The platform returned no project rules. This does not establish merge eligibility.", "平台返回了空规则列表，不能据此判断是否满足合并条件。 ")).font(.caption).foregroundStyle(.secondary) }
            ForEach(value.rules) { rule in
              VStack(alignment: .leading, spacing: 4) {
                Text(rule.name + " · " + rule.ruleType).font(.caption.weight(.semibold))
                Text(store.text("Required approvals: ", "所需批准数量：") + "\(rule.approvalsRequired) · " + (rule.approved ? store.text("Rule approved", "规则已通过") : store.text("Rule not approved", "规则未通过"))).font(.caption)
                if let users = rule.approvedBy { Text(store.text("Approved by: ", "已批准用户：") + users.map(\.login).joined(separator: ", ")).font(.caption).textSelection(.enabled) }
                if let users = rule.eligibleApprovers { Text(store.text("Eligible approvers: ", "可审批用户：") + users.map(\.login).joined(separator: ", ")).font(.caption).lineLimit(3).textSelection(.enabled) }
                if rule.containsHiddenGroups == true { Text(store.text("The rule includes hidden groups.", "此规则包含不可见群组。")).font(.caption2).foregroundStyle(.secondary) }
                if rule.overridden == true { Text(store.text("This rule is overridden for the merge request.", "此规则已针对当前合并请求覆盖。")).font(.caption2).foregroundStyle(.secondary) }
              }
            }
            if value.rulesOverwritten == true { Text(store.text("The platform reports merge-request approval rules were overwritten.", "平台报告此 MR 的审批规则已被覆盖。")).font(.caption).foregroundStyle(.secondary) }
          }
        }
        Divider()
        HStack {
          Text(store.text("Reviewers · Read-only", "审查者 · 只读")).font(.headline)
          Spacer(); Button(store.text("Load Reviewers", "加载审查者")) { session.loadExistingReviewers() }.disabled(session.reviewerLoading)
          if session.reviewerLoading { ProgressView().controlSize(.small) }
        }
        Text(store.text("Assign GitLab reviewers in the browser. Its API replaces the complete reviewer list and has no verified conditional update; GitPier avoids overwriting another client's concurrent reviewer changes.", "请在浏览器分配 GitLab 审查者。其 API 会替换完整审查者列表，尚无已验证的条件更新机制；GitPier 避免覆盖其他客户端同时进行的更改。 ")).font(.caption).foregroundStyle(.secondary)
        if let error = session.reviewerError { Text(error).font(.caption).foregroundStyle(.orange) }
        if session.existingReviewersLoaded {
          Text(session.existingReviewers.isEmpty ? store.text("No requested reviewers returned.", "平台未返回已请求审查者。 ") : session.existingReviewers.map { "@" + $0.login }.joined(separator: ", ")).font(.caption).textSelection(.enabled)
        }
        if let url = session.context?.webURL { Link(store.text("Manage Reviewers in Browser", "在浏览器管理审查者"), destination: url).font(.caption) }
      }.padding(.top, 8)
    }.padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
  }
  private var draft: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Label(store.text("Saved in memory for this account and request. Switching pages asks whether to keep the draft.", "草稿仅保存在此账号与请求的内存中。切换页面时会询问是否保留。"), systemImage: "doc.badge.clock")
          .font(.caption).foregroundStyle(.secondary)
        Text(store.text("Review Summary", "审查总结")).font(.headline)
        TextEditor(text: Binding(get: { session.draft?.summary ?? "" }, set: { session.draft?.summary = $0 }))
          .font(.body).frame(minHeight: 100, maxHeight: 170).padding(4).overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
          .disabled(!session.canCompose || session.outdated).accessibilityIdentifier("hosting.review.summary")
        HStack {
          Text(store.text("Decision", "审查决定"))
          Picker("", selection: Binding(get: { session.draft?.decision ?? .comment }, set: { session.draft?.decision = $0 })) {
            Text(store.text("Comment", "评论")).tag(HostingReviewDecision.comment)
            if session.context?.capabilities.contains(.approve) == true { Text(store.text("Approve", "批准")).tag(HostingReviewDecision.approve) }
            if session.context?.capabilities.contains(.requestChanges) == true { Text(store.text("Request Changes", "请求更改")).tag(HostingReviewDecision.requestChanges) }
          }.labelsHidden().frame(maxWidth: 240).disabled(!session.canCompose || session.outdated)
          Spacer()
        }
        if session.account.instance.provider == .gitlab {
          Text(store.text("GitLab publishes each Discussion separately. Approval is a separate operation and may not satisfy all project approval rules. The confirmation lists each write and its result.", "GitLab 会分别发布每条讨论。批准属于独立操作，且不一定满足项目的全部审批规则。确认页面会列出每次写入及其结果。"))
            .font(.caption).foregroundStyle(.secondary)
        }
        Text(store.text("Pending Review Comments", "待提交审查评论") + " (\(session.draft?.comments.count ?? 0))").font(.headline)
        ForEach(session.draft?.comments ?? []) { comment in
          VStack(alignment: .leading, spacing: 7) {
            anchorLabel(comment.anchor, store: store)
            Text(comment.body).textSelection(.enabled)
            HStack {
              Button(store.text("Edit", "编辑")) { session.edit(comment) }.disabled(!session.canCompose || session.outdated)
              Button(store.text("Delete Draft Comment", "删除草稿评论")) { session.draft?.comments.removeAll { $0.id == comment.id } }.disabled(session.submitting)
            }.font(.caption)
          }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
        HStack {
          Button(store.text("Discard Draft…", "丢弃草稿…")) { discard = true }.disabled(session.submitting)
          Spacer()
          if session.context?.capabilities.contains(.draft) == true {
            Button(store.text("Save Pending on Platform…", "保存待定审查到平台…")) { session.prepareDraft(pending: true) }.disabled(!canSubmitDraft)
          }
          if session.account.instance.provider != .gitea {
            Button(store.text("Review Submission…", "预览并提交审查…")) { session.prepareDraft() }.buttonStyle(.borderedProminent).disabled(!canSubmitDraft)
              .accessibilityIdentifier("hosting.review.preview-draft")
          } else if let url = session.context?.webURL {
            Link(store.text("Submit Review in Browser", "在浏览器提交审查"), destination: url)
          }
        }
      }.padding(2)
    }.accessibilityIdentifier("hosting.review.draft")
  }
  private var canSubmitDraft: Bool { session.canCompose && !session.outdated && session.draft?.hasContent == true && session.composerBody.isEmpty }
  private func canReply(_ thread: HostingReviewThread, comment: HostingReviewComment) -> Bool {
    guard session.context?.capabilities.contains(.reply) == true, comment.kind != .system, comment.kind != .summary else { return false }
    return session.account.instance.provider == .gitlab ? [.conversation, .inline].contains(thread.source) : thread.source == .inline
  }
  private func sourceTitle(_ source: HostingReviewSource) -> String {
    switch source { case .conversation: store.text("Conversation", "会话"); case .reviews: store.text("Reviews", "审查"); case .inline: store.text("Code Discussions", "代码讨论") }
  }
  private func stateTitle(_ state: HostingReviewState) -> String {
    switch state {
    case .approved: store.text("Approved", "已批准")
    case .changesRequested: store.text("Changes Requested", "已请求更改")
    case .commented: store.text("Commented", "已评论")
    case .dismissed: store.text("Dismissed", "已撤销")
    case .pending: store.text("Pending Review", "待提交审查")
    case .unapproved: store.text("Unapproved", "未批准")
    case .unknown: store.text("Unknown", "未知")
    }
  }
}

struct HostingReviewStatus: View {
  @EnvironmentObject var store: AppStore
  @ObservedObject var session: HostingReviewSession
  @State private var acknowledge = false
  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      if session.contextLoading { HStack { ProgressView().controlSize(.small); Text(store.text("Checking review permissions and revision…", "正在检查审查权限与版本…")) }.font(.caption) }
      if let error = session.contextError {
        HStack { Text(error).foregroundStyle(.orange); Button(store.text("Retry", "重试")) { session.start() } }.font(.caption)
      }
      if !session.identityValid { Label(session.message(HostingReviewError.targetChanged), systemImage: "person.crop.circle.badge.exclamationmark").font(.caption).foregroundStyle(.orange) }
      if session.outdated { Label(session.message(HostingReviewError.revisionChanged), systemImage: "clock.arrow.circlepath").font(.caption).foregroundStyle(.orange) }
      if let explanation = session.context?.permissionExplanation, !explanation.isEmpty { Text(permissionExplanation(explanation)).font(.caption).foregroundStyle(.secondary) }
      if let explanation = session.reviewBrowserExplanation {
        Text(explanation).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        if let url = session.context?.webURL { Link(store.text("Review in Browser", "在浏览器审查"), destination: url).font(.caption) }
      }
      if let error = session.actionError { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
      if let status = session.status { Label(statusTitle(status), systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
      if session.submitting {
        HStack { ProgressView().controlSize(.small); Text(store.text("Submitting / verifying…", "正在提交 / 回读验证…")); Button(store.text("Cancel Waiting", "取消等待")) { session.cancelSubmission() } }.font(.caption)
      }
      if let report = session.report, !report.complete {
        ForEach(Array(report.results.enumerated()), id: \.element.id) { index, result in
          Text("\(index + 1). " + outcomeTitle(result.outcome)).font(.caption)
        }
      }
      if session.targetBlocked || session.report?.hasUnknown == true {
        Label(store.text("A previous submission for this target is unresolved. New submissions are blocked until it is verified or explicitly checked on the platform.", "此目标此前提交的结果尚未确认。在回读验证或主动核实平台结果前，新的提交已被阻止。 "), systemImage: "exclamationmark.bubble").font(.caption).foregroundStyle(.orange)
        HStack {
          if session.report?.hasUnknown == true { Button(store.text("Check Known Receipt", "回读已知结果")) { session.reconcile() }.disabled(session.submitting) }
          if let url = session.context?.webURL { Link(store.text("Check in Browser", "在浏览器中核实"), destination: url) }
          Button(store.text("I Checked the Platform…", "我已在平台核实…")) { acknowledge = true }.disabled(session.submitting)
        }.font(.caption)
      }
    }
    .alert(store.text("Allow a new submission?", "允许重新提交？"), isPresented: $acknowledge) {
      Button(store.text("Cancel", "取消"), role: .cancel) {}
      Button(store.text("I Verified What Was Published", "我已核实实际发布内容")) { session.acknowledgePlatformCheck() }
    } message: { Text(store.text("Only continue after checking the platform and removing any comments that were already published from the draft. This does not prove that a previous request failed.", "请先在平台检查实际结果，并从草稿中删除已经发布的评论。此操作不能证明上次请求未成功。")) }
  }
  private func outcomeTitle(_ value: HostingReviewSubmissionOutcome) -> String {
    switch value {
    case .submitted(let receipt): store.text("Submitted and verified · ", "已提交并验证 · ") + receipt.id
    case .unknown: store.text("Result Unknown — draft preserved", "结果未知，草稿已保留")
    case .notSent: store.text("Not Sent", "未发送")
    case .failed(let failure):
      switch failure { case .review(let error): session.message(error); case .hosting(let error): session.message(error); case .cancelled: store.text("Cancelled before sending", "发送前已取消") }
    }
  }
  private func statusTitle(_ status: HostingReviewSession.Status) -> String {
    switch status {
    case .pendingSaved: store.text("Pending review saved on the platform.", "待提交审查已保存到平台。")
    case .submittedVerified: store.text("Submitted and verified on the platform.", "已提交并在平台回读验证。")
    }
  }
  private func permissionExplanation(_ english: String) -> String {
    guard store.settings.language == .simplifiedChinese else { return english }
    switch session.account.instance.provider {
    case .github: return "GitHub 公开仓库需 public_repo，私有仓库需 repo；两者均包含写入权限。细粒度 PAT 需对应 Issue / Pull Request 写权限。"
    case .gitlab:
      if english.contains("approvals") { return "此实例未开放合并请求审批，或当前账号无法读取审批权限。" }
      return "GitLab 审查写入需 api 权限，其授权范围超出评论操作。审批还取决于项目规则与当前用户权限。"
    case .gitea: return "Gitea 普通评论需 write:issue，既有审查回复与追加审查者需 write:repository。审查提交与审批请在浏览器操作。扩大 Scope 可能与旧 Grant 冲突，请主动重新授权或替换 PAT。"
    }
  }
}

struct HostingReviewComposer: View {
  @EnvironmentObject var store: AppStore
  @ObservedObject var session: HostingReviewSession
  @State private var preview = false
  @State private var discard = false
  @FocusState private var focused: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title).font(.headline)
        Spacer()
        Toggle(store.text("Preview", "预览"), isOn: $preview).toggleStyle(.button).controlSize(.small)
      }
      if case .inline(let anchor) = session.composer {
        anchorLabel(anchor, store: store)
        if session.inlineStartCandidates.count > 1 {
          Picker(store.text("Start Line", "起始行"), selection: Binding(get: { session.inlineStartLineID ?? -1 }, set: { session.selectInlineStartLine($0) })) {
            ForEach(session.inlineStartCandidates) { candidate in Text("\(candidate.number) · " + String(candidate.code.prefix(60))).tag(candidate.id) }
          }.pickerStyle(.menu).frame(maxWidth: 420, alignment: .leading).disabled(!session.canCompose)
            .accessibilityIdentifier("hosting.review.range-start")
        }
        ScrollView { Text(anchor.rangeCode ?? anchor.code).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: anchor.startLine == nil ? 35 : 75)
      }
      if case .reply(let thread, let comment) = session.composer {
        Text(store.text("Reply to @", "回复 @") + comment.author + " · " + thread.remoteID).font(.caption).foregroundStyle(.secondary)
      }
      if preview { ScrollView { Text(session.composerBody).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(6) }.frame(minHeight: 80, maxHeight: 130) }
      else {
        TextEditor(text: $session.composerBody).font(.body).focused($focused).frame(minHeight: 80, maxHeight: 130)
          .padding(4).overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor))).disabled(!session.canCompose)
          .accessibilityIdentifier("hosting.review.comment-body")
      }
      HStack {
        Text("@" + session.account.user.login + " · " + session.binding.repository + " #\(session.number)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        Spacer()
        Button(store.text("Cancel", "取消")) { if session.composerBody.isEmpty { close() } else { discard = true } }.disabled(session.submitting)
        if case .inline = session.composer {
          Button(store.text("Save to Review Draft", "保存到审查草稿")) { session.saveInlineDraft() }.disabled(!canSubmit)
        }
        Button(store.text("Preview Submission…", "预览提交…")) { session.prepareComposer() }.buttonStyle(.borderedProminent).disabled(!canSubmit)
          .accessibilityIdentifier("hosting.review.preview-comment")
      }
    }.padding(10).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    .onAppear { focused = true }
    .alert(store.text("Discard this comment draft?", "丢弃此评论草稿？"), isPresented: $discard) {
      Button(store.text("Keep Editing", "继续编辑"), role: .cancel) {}
      Button(store.text("Discard", "丢弃"), role: .destructive) { close() }
    }
  }
  private var canSubmit: Bool { session.canCompose && !session.composerBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  private var title: String {
    switch session.composer { case .inline: store.text("Add Review Comment", "添加审查评论"); case .reply: store.text("Reply", "回复"); default: store.text("Add Comment", "添加评论") }
  }
  private func close() { session.composer = nil; session.composerBody = ""; session.editingComment = nil }
}

struct HostingReviewConfirmationView: View {
  @EnvironmentObject var store: AppStore
  @ObservedObject var session: HostingReviewSession
  let snapshot: HostingReviewConfirmation
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(store.text("Confirm Remote Review Submission", "确认发布远端审查")).font(.title2.weight(.semibold))
      Text(snapshot.context.target.instance.provider.title + " · " + snapshot.context.target.instance.baseURL.absoluteString).font(.caption).textSelection(.enabled)
      Text("@" + session.account.user.login + " · " + snapshot.context.target.repository + " #\(snapshot.context.target.requestNumber)").font(.headline).textSelection(.enabled)
      Text(store.text("Commit: ", "提交：") + snapshot.context.revision.headSHA).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
      Text(store.text("Remote operations: ", "远端操作数量：") + "\(snapshot.items.count)").font(.caption)
      if snapshot.context.target.instance.provider == .gitlab {
        Label(store.text("Each Discussion and Approval is published separately. Partial success is possible; each result will be shown.", "每条讨论与批准将分别发布，可能部分成功；将逐条显示结果。"), systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(snapshot.items) { item in mutationPreview(item.mutation) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
      }.frame(minHeight: 150, maxHeight: 330).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
      Text(store.text("Publishing uses this hosting account. The current request, permissions, commit and comment locations are checked again before sending.", "将使用此托管账号发布。发送前会重新检查请求、权限、提交版本与评论位置。"))
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button(store.text("Edit / Cancel", "编辑 / 取消")) { session.confirmation = nil }.keyboardShortcut(.cancelAction)
        Spacer()
        Button(store.text("Confirm & Submit", "确认并发布")) { session.submit(snapshot) }.buttonStyle(.borderedProminent)
          .disabled(session.submitting || !session.identityValid).accessibilityIdentifier("hosting.review.confirm-submit")
      }
    }.padding(22).frame(width: 620)
  }
  @ViewBuilder private func mutationPreview(_ mutation: HostingReviewMutation) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      switch mutation {
      case .comment(let body): Text(store.text("General Comment", "普通评论")).font(.headline); Text(body).textSelection(.enabled)
      case .inline(let body, let anchor): Text(store.text("Inline Review Comment", "逐行审查评论")).font(.headline); anchorLabel(anchor, store: store); Text(anchor.rangeCode ?? anchor.code).font(.system(.caption, design: .monospaced)).textSelection(.enabled); Text(body).textSelection(.enabled)
      case .reply(let thread, let comment, let body): Text(store.text("Thread Reply", "线程回复")).font(.headline); Text(store.text("Thread / Comment: ", "线程 / 评论：") + thread + " / " + comment).font(.caption); Text(body).textSelection(.enabled)
      case .review(let summary, let decision, let comments, let pending):
        Text(pending ? store.text("Pending Review — saved on platform", "待定审查：保存到平台") : decisionTitle(decision)).font(.headline)
        Text(store.text("Inline comments: ", "逐行评论数量：") + "\(comments.count)").font(.caption)
        if !summary.isEmpty { Text(summary).textSelection(.enabled) }
        ForEach(comments) { comment in anchorLabel(comment.anchor, store: store); if let code = comment.anchor.rangeCode { Text(code).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }; Text(comment.body).textSelection(.enabled); Divider() }
      case .submitPending(let id, let summary, let decision): Text(decisionTitle(decision)).font(.headline); Text(store.text("Pending Review: ", "待定审查：") + id).font(.caption); Text(summary).textSelection(.enabled)
      case .resolve(let id, let resolved): Text(resolved ? store.text("Resolve Discussion", "解决讨论") : store.text("Reopen Discussion", "重新打开讨论")).font(.headline); Text(id).font(.caption)
      case .requestReviewers(let selection):
        Text(store.text("Request Reviewers — Platform Notification", "请求审查者：平台通知")).font(.headline)
        Text(store.text("New requests: ", "新增请求：") + selection.reviewers.map { "@" + $0.login + " (" + $0.id + ")" }.joined(separator: ", ")).textSelection(.enabled)
        Text(store.text("Existing reviewers preserved: ", "已有审查者将保留：") + selection.existingReviewers.map { "@" + $0.login }.joined(separator: ", ")).font(.caption).textSelection(.enabled)
        Text(store.text("The platform may notify the selected users. GitLab reviewer assignment does not grant approval authority.", "平台可能向所选用户发送通知，GitLab 审查者分配并不授予审批权限。 ")).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
  private func decisionTitle(_ value: HostingReviewDecision) -> String {
    switch value { case .comment: store.text("Comment Review", "评论审查"); case .approve: store.text("Approve", "批准"); case .requestChanges: store.text("Request Changes", "请求更改") }
  }
}

@MainActor private func anchorLabel(_ anchor: HostingDiffAnchor, store: AppStore) -> some View {
  VStack(alignment: .leading, spacing: 3) {
    Text(anchor.path + ":" + (anchor.startLine.map { String($0) + "–" } ?? "") + String((anchor.side == .old ? anchor.oldLine : anchor.newLine) ?? 0) + " · " + (anchor.side == .old ? store.text("Old Side", "旧侧") : store.text("New Side", "新侧")))
      .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
    Text(String(anchor.revision.headSHA.prefix(12))).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
  }
}

struct HostingReviewDraftBanner: View {
  @EnvironmentObject var store: AppStore
  @ObservedObject var registry: HostingReviewSessionRegistry
  @State private var showing = false
  @State private var discarding: HostingReviewSession?
  var body: some View {
    if !registry.pending.isEmpty {
      HStack {
        Label(store.text("Review drafts / unresolved results: ", "审查草稿 / 待核实结果：") + "\(registry.pending.count)", systemImage: "doc.badge.clock")
        Text(store.text("Kept in memory when switching repositories. Closing the last window asks before discarding.", "切换仓库时保留在内存中，关闭最后一个窗口前会询问是否丢弃。")).foregroundStyle(.secondary).lineLimit(1)
        Spacer(); Button(store.text("View Review Work…", "查看审查状态…")) { showing = true }
      }.font(.caption).padding(.horizontal, 12).padding(.vertical, 6).background(.quaternary)
      .sheet(isPresented: $showing) {
        VStack(alignment: .leading, spacing: 12) {
          Text(store.text("Review Drafts & Unresolved Results", "审查草稿与待核实结果")).font(.title2.weight(.semibold))
          List {
            ForEach(registry.pending, id: \.id) { session in
              DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                  if session.hasUnresolvedResult { HostingReviewStatus(session: session) }
                  if !session.identityValid { Label(store.text("Original account or repository binding changed. This draft is available for copying; it cannot be submitted through a different account.", "原账号或仓库关联已变化。此草稿可复制保留，不能通过其他账号提交。"), systemImage: "person.crop.circle.badge.exclamationmark").font(.caption).foregroundStyle(.orange) }
                  if let draft = session.draft {
                    Text(store.text("Original commit: ", "原提交版本：") + draft.context.revision.headSHA).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    if !draft.summary.isEmpty {
                      Text(store.text("Review Summary", "审查总结")).font(.caption.weight(.semibold))
                      Text(draft.summary).textSelection(.enabled)
                    }
                    ForEach(draft.comments) { comment in
                      anchorLabel(comment.anchor, store: store)
                      Text(comment.body).textSelection(.enabled)
                      Divider()
                    }
                  }
                  if !session.composerBody.isEmpty {
                    Text(store.text("Unsent Comment", "未发送评论")).font(.caption.weight(.semibold))
                    Text(session.composerBody).textSelection(.enabled)
                  }
                  Text(store.text("Return to the original request to continue, or copy this text into a newly confirmed review. Comment positions are never transferred automatically.", "可返回原请求继续，或将文字复制到重新确认的审查中。评论位置不会自动转移。 ")).font(.caption).foregroundStyle(.secondary)
                  if session.hasPrivateDraftContent {
                    Button(store.text("Discard This Draft…", "丢弃此草稿…")) { discarding = session }.disabled(session.submitting)
                  }
                }.padding(.vertical, 8)
              } label: {
                Text(session.displayName).textSelection(.enabled)
              }
            }
          }
          HStack { Spacer(); Button(store.text("Done", "完成")) { showing = false }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 620, height: 330)
        .alert(store.text("Discard this review draft?", "丢弃此审查草稿？"), isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } })) {
          Button(store.text("Keep Draft", "保留草稿"), role: .cancel) { discarding = nil }
          Button(store.text("Discard", "丢弃"), role: .destructive) { discarding?.discardDraft(); discarding = nil }
        } message: { Text(discarding?.displayName ?? "") }
      }
    }
  }
}
