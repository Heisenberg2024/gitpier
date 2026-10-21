import AppKit
import GitPierCore
import PTYSupport
import SwiftTerm
import SwiftUI

@MainActor enum TerminalTypeface {
  static func resolve(name: String, size: CGFloat) -> NSFont {
    let selected =
      NSFont(name: name, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    let namedWidth = selected.advancement(forGlyph: selected.glyph(withName: "W")).width
    let actualWidth = ("W" as NSString).size(withAttributes: [.font: selected]).width
    guard abs(namedWidth - actualWidth) > 0.75 else { return selected }
    // Older Nerd Fonts can rename ASCII glyphs. SwiftTerm measures named W, so use a safe base with a cascade.
    let base =
      NSFont(name: "Menlo", size: size)
      ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: [selected.fontDescriptor]])
    return NSFont(descriptor: descriptor, size: size) ?? base
  }
}

final class SafeTerminalView: LocalProcessTerminalView {
  private(set) var scrollThumb: OverlayScrollThumb?
  private var lastScrollPosition: Double?
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateScrollThumb()
  }
  override func layout() {
    super.layout()
    updateScrollThumb()
  }
  override func scrolled(source terminal: Terminal, yDisp: Int) {
    super.scrolled(source: terminal, yDisp: yDisp)
    updateScrollThumb()
  }
  override func bufferActivated(source: Terminal) {
    super.bufferActivated(source: source)
    updateScrollThumb()
  }
  func updateScrollThumb() {
    // SwiftTerm scrolls its buffer directly, rather than using NSScrollView.
    // Hide its native scroller and drive the same thumb through its public scrollback API.
    for scroller in subviews.compactMap({ $0 as? NSScroller }) { scroller.isHidden = true }
    if scrollThumb == nil {
      let thumb = OverlayScrollThumb(horizontal: false)
      thumb.accessibilityName = "Terminal scrollback"
      thumb.changed = { [weak self] fraction in
        self?.scroll(toPosition: Double(fraction))
        self?.updateScrollThumb()
      }
      scrollThumb = thumb
      addSubview(thumb, positioned: .above, relativeTo: nil)
    }
    guard let thumb = scrollThumb else { return }
    if thumb.tintColor != nativeForegroundColor { thumb.tintColor = nativeForegroundColor }
    let target = NSRect(x: max(0, bounds.width - 12), y: 0, width: 12, height: bounds.height)
    if thumb.frame != target { thumb.frame = target }
    thumb.isHidden = !canScroll || bounds.height < 12 || bounds.width < 12
    if let lastScrollPosition, lastScrollPosition != scrollPosition { thumb.markActive() }
    lastScrollPosition = scrollPosition
    thumb.update(fraction: CGFloat(scrollPosition))
  }
  private(set) var resizeCount = 0
  override func setFrameSize(_ newSize: NSSize) {
    let size = NSSize(width: floor(newSize.width), height: floor(newSize.height))
    guard size.width > 1, size.height > 1, size != frame.size else { return }
    resizeCount += 1
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    super.setFrameSize(size)
    updateScrollThumb()
    CATransaction.commit()
  }
  // Used by the isolated acceptance harness only; normal sessions never collect or persist output.
  var acceptanceOutput: ((Data) -> Void)?
  override func dataReceived(slice: ArraySlice<UInt8>) {
    acceptanceOutput?(Data(slice))
    super.dataReceived(slice: slice)
    updateScrollThumb()
  }
  override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
    guard let url = URL(string: link),
      ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "")
    else { return }
    NSWorkspace.shared.open(url)
  }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    sender.draggingPasteboard.canReadObject(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
      ? .copy : super.draggingEntered(sender)
  }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    if let urls = sender.draggingPasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty
    {
      send(txt: urls.map { InputValidation.shellQuote($0.path) }.joined(separator: " "))
      return true
    }
    return super.performDragOperation(sender)
  }
}

@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable,
  LocalProcessTerminalViewDelegate
{
  let id = UUID()
  @Published var name: String
  @Published var exited = false
  @Published var exitCode: Int32?
  @Published var directory: String
  var customName = false
  let view: SafeTerminalView
  let root: String
  let authentication: AuthenticationContext?
  let agentConfiguration: AgentLaunchConfiguration?
  var agentDidExit: ((Int32?, Bool) -> Void)?
  private var stopRequested = false
  private var exitReported = false
  @Published private(set) var stopping = false
  private var agentProcess = GitPierProcessIdentity()
  private var cleanupTask: Task<Void, Never>?
  private var agentStarted = false
  private let canStart: (() -> Bool)?
  private var appliedFont = ""
  private(set) var fontApplyCount = 0
  private var appliedCursor = ""
  private var appliedScrollback: Int?
  init(
    root: String, number: Int, settings: AppSettings, authentication: AuthenticationContext? = nil,
    agentConfiguration: AgentLaunchConfiguration? = nil, autoStart: Bool = true,
    canStart: (() -> Bool)? = nil
  ) {
    self.root = root
    self.authentication = authentication
    self.agentConfiguration = agentConfiguration
    self.canStart = canStart
    directory = root
    name = agentConfiguration == nil ? "Local \(number)" : "Codex"
    var options = TerminalOptions.default
    options.scrollback = max(1000, min(settings.scrollback, 100000))
    view = SafeTerminalView(
      frame: NSRect(x: 0, y: 0, width: 800, height: 260),
      font: TerminalTypeface.resolve(name: settings.terminalFont, size: settings.terminalFontSize),
      options: options)
    super.init()
    view.processDelegate = self
    view.registerForDraggedTypes([.fileURL])
    if autoStart { start(settings: settings) }
  }
  func start(settings: AppSettings) {
    guard canStart?() != false else { exited = true; reportAgentExit(126); return }
    if let launch = agentConfiguration {
      // Agent restarts always require a fresh task/HEAD/executable confirmation.
      guard !agentStarted, !exitReported else { return }
      do { try launch.executable.validate() } catch {
        exited = true; reportAgentExit(nil); return
      }
      let env = launch.executable.environment.values
      exited = false; exitCode = nil
      var gate: [Int32] = [-1, -1]
      guard pipe(&gate) == 0 else { exited = true; reportAgentExit(126); return }
      defer { Darwin.close(gate[0]); Darwin.close(gate[1]) }
      // Only the read end crosses exec into the internal launcher. No await can interleave a spawn.
      guard fcntl(gate[1], F_SETFD, FD_CLOEXEC) == 0, fcntl(gate[1], F_SETNOSIGPIPE, 1) == 0,
        let launcher = Bundle.main.executablePath else { exited = true; reportAgentExit(126); return }
      agentStarted = true
      view.startProcess(executable: launcher,
        args: ["--task-agent-launch", String(gate[0]), String(launch.directoryIdentity.device), String(launch.directoryIdentity.inode), launch.directory, launch.executable.path] + launch.executable.launchIdentityArguments,
        environment: env.map { "\($0.key)=\($0.value)" }, execName: launcher, currentDirectory: nil)
      agentProcess = gitpier_process_identity(view.process.shellPid)
      guard view.process.shellPid > 1 else { exited = true; reportAgentExit(126); return }
      // The helper cannot execute Codex before a stable process identity has been captured.
      guard agentProcess.pid > 1 else { finishAgent(code: 126); return }
      var permission: UInt8 = 49
      if Darwin.write(gate[1], &permission, 1) != 1 { finishAgent(code: 126) }
      return
    }
    guard FileManager.default.isExecutableFile(atPath: settings.shellPath) else {
      exited = true
      view.feed(text: "Shell is not executable: \(settings.shellPath)\r\n")
      return
    }
    var env = ProcessInfo.processInfo.environment
    for key in env.keys
    where key.hasPrefix("GITPIER_") || key == "GIT_INDEX_FILE" || key == "GIT_ASKPASS"
      || key == "SSH_ASKPASS"
    { env[key] = nil }
    env["TERM"] = "xterm-256color"
    env["COLORTERM"] = "truecolor"
    env["TERM_PROGRAM"] = "GitPier"
    env["TERM_PROGRAM_VERSION"] = AppResources.version
    if let authentication {
      for (key, value) in authentication.environment { env[key] = value }
      let pairs = stride(from: 0, to: authentication.arguments.count, by: 2).compactMap {
        i -> (String, String)? in
        guard i + 1 < authentication.arguments.count else { return nil }
        let parts = authentication.arguments[i + 1].split(
          separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
      }
      if !pairs.isEmpty {
        env["GIT_CONFIG_COUNT"] = String(pairs.count)
        for (i, pair) in pairs.enumerated() {
          env["GIT_CONFIG_KEY_\(i)"] = pair.0
          env["GIT_CONFIG_VALUE_\(i)"] = pair.1
        }
      }
    }
    if env["PATH"] == nil {
      env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }
    exited = false
    exitCode = nil
    let shell = URL(fileURLWithPath: settings.shellPath).lastPathComponent
    // Login + interactive allows the user's profile, prompt, agent and shell plugins to load.
    view.startProcess(
      executable: settings.shellPath, args: settings.loginShell ? ["-l", "-i"] : ["-i"],
      environment: env.map { "\($0.key)=\($0.value)" }, execName: shell,
      currentDirectory: settings.terminalDirectory == "home"
        ? FileManager.default.homeDirectoryForCurrentUser.path
        : settings.terminalDirectory == "custom" && !settings.terminalCustomDirectory.isEmpty
          ? (settings.terminalCustomDirectory as NSString).expandingTildeInPath : root)
  }
  func apply(settings: AppSettings, dark: Bool) {
    let fontKey = "\(settings.terminalFont):\(settings.terminalFontSize)"
    if appliedFont != fontKey {
      view.font = TerminalTypeface.resolve(
        name: settings.terminalFont, size: settings.terminalFontSize)
      appliedFont = fontKey
      fontApplyCount += 1
    }
    let useDark = settings.terminalTheme == "follow" ? dark : settings.terminalTheme == "dark"
    let bg = useDark ? NSColor(hex: 0x191B1F) : NSColor(hex: 0xFAFBFC)
    let fg = useDark ? NSColor(hex: 0xD3D8E1) : NSColor(hex: 0x262B36)
    if view.nativeBackgroundColor != bg { view.nativeBackgroundColor = bg }
    if view.nativeForegroundColor != fg { view.nativeForegroundColor = fg }
    if view.lineSpacing != settings.terminalLineSpacing {
      view.lineSpacing = min(1.8, max(0.8, settings.terminalLineSpacing))
    }
    if appliedCursor != settings.terminalCursor {
      view.getTerminal().setCursorStyle(
        CursorStyle(tagName: settings.terminalCursor) ?? .blinkBlock)
      appliedCursor = settings.terminalCursor
    }
    if appliedScrollback != settings.scrollback {
      view.getTerminal().changeScrollback(max(1000, min(settings.scrollback, 100000)))
      appliedScrollback = settings.scrollback
    }
    view.updateScrollThumb()
  }
  func close() {
    if agentConfiguration != nil {
      guard !exitReported else { return }
      stopRequested = true; finishAgent(code: nil)
      return
    }
    guard !exited, view.process.running else {
      exited = true
      return
    }
    gitpier_hangup_session(view.process.shellPid)
    view.terminate()
    stopRequested = true
    exited = true
    reportAgentExit(nil)
  }
  private func reportAgentExit(_ code: Int32?) {
    guard agentConfiguration != nil, !exitReported else { return }
    exitReported = true; agentDidExit?(code, stopRequested)
  }
  private func finishAgent(code: Int32?) {
    guard cleanupTask == nil, !exitReported else { return }
    stopping = true
    // Keep metadata/session active until verified process cleanup has finished.
    let pid = agentProcess.pid, seconds = agentProcess.seconds, microseconds = agentProcess.microseconds
    cleanupTask = Task { [weak self] in
      let remaining = await Task.detached(priority: .userInitiated) {
        pid > 1 ? gitpier_terminate_owned_session(GitPierProcessIdentity(pid: pid, seconds: seconds, microseconds: microseconds)) : -1
      }.value
      guard let self else { return }
      self.cleanupTask = nil; self.stopping = false
      guard remaining == 0 else {
        self.view.feed(text: "\r\nProcess cleanup could not be verified. Inspect attached jobs before closing this task.\r\n")
        return
      }
      self.exited = true; self.exitCode = code; self.reportAgentExit(code)
    }
  }
  func stopAgentAndWait() async -> Bool {
    guard agentConfiguration != nil else { return true }
    close()
    if let cleanupTask { await cleanupTask.value }
    return exitReported
  }
  nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
  nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    Task { @MainActor [weak self] in
      if self?.customName == false { self?.name = String(title.prefix(60)) }
    }
  }
  nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
    Task { @MainActor [weak self] in
      if let directory { self?.directory = URL(string: directory)?.path ?? directory }
    }
  }
  nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      let code = exitCode.map { ($0 & 0x7f) == 0 ? (($0 >> 8) & 0xff) : 128 + ($0 & 0x7f) }
      if self.agentConfiguration != nil { self.finishAgent(code: code); return }
      self.exited = true
      self.exitCode = code
    }
  }
}

@MainActor final class TerminalManager: ObservableObject {
  @Published var sessions: [TerminalSession] = []
  @Published var selectedID: UUID?
  @Published var splitID: UUID?
  let root: String
  var authentication: AuthenticationContext?
  var canStart: (() -> Bool)?
  private var number = 0
  init(root: String) { self.root = root }
  func configure(authentication: AuthenticationContext) { self.authentication = authentication }
  var selected: TerminalSession? { sessions.first { $0.id == selectedID } }
  func add(settings: AppSettings) {
    guard canStart?() != false else { return }
    number += 1
    let session = TerminalSession(
      root: root, number: number, settings: settings, authentication: authentication, canStart: canStart)
    sessions.append(session)
    selectedID = session.id
  }
  func close(_ id: UUID) {
    guard let session = sessions.first(where: { $0.id == id }) else { return }
    if session.agentConfiguration != nil, !session.exited {
      Task { [weak self] in
        guard await session.stopAgentAndWait() else { return }
        self?.removeClosed(id)
      }
      return
    }
    session.close()
    removeClosed(id)
  }
  private func removeClosed(_ id: UUID) {
    sessions.removeAll { $0.id == id }
    if selectedID == id { selectedID = sessions.last?.id }
    if splitID == id { splitID = nil }
  }
  func addAgent(_ launch: AgentLaunchConfiguration, settings: AppSettings, onExit: @escaping (Int32?, Bool) -> Void) -> TerminalSession {
    let session = TerminalSession(root: root, number: 0, settings: settings, agentConfiguration: launch, autoStart: false, canStart: canStart)
    session.agentDidExit = onExit
    sessions.append(session); selectedID = session.id
    session.start(settings: settings)
    return session
  }
  func shutdown() {
    for session in sessions { session.close() }
    sessions.removeAll()
  }
}

struct TerminalHost: NSViewRepresentable {
  @ObservedObject var session: TerminalSession
  var settings: AppSettings
  var dark: Bool
  func makeNSView(context: Context) -> SafeTerminalView {
    session.apply(settings: settings, dark: dark)
    return session.view
  }
  func updateNSView(_ view: SafeTerminalView, context: Context) {
    session.apply(settings: settings, dark: dark)
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: SafeTerminalView, context: Context)
    -> CGSize?
  {
    CGSize(width: proposal.width ?? 800, height: proposal.height ?? 260)
  }
}

struct TerminalPanel: View {
  @ObservedObject var model: RepositoryModel
  @ObservedObject var manager: TerminalManager
  @EnvironmentObject var store: AppStore
  @Environment(\.colorScheme) var scheme
  @FocusState private var searchFocused: Bool
  @State private var search = ""
  @State private var showSearch = false
  @State private var closing: UUID?
  @State private var renaming: UUID?
  @State private var newName = ""
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text(store.text("Terminal", "终端")).font(uiFont(size: 12, weight: .semibold)).padding(
          .leading, 12)
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 3) {
            ForEach(manager.sessions) { session in
              HStack(spacing: 7) {
                Circle().fill(session.exited ? Color.secondary : Color.mint).frame(
                  width: 5, height: 5)
                Text(session.name).lineLimit(1).frame(maxWidth: 170)
                Button {
                  if session.exited { manager.close(session.id) } else { closing = session.id }
                } label: {
                  Image(systemName: "xmark").font(uiFont(size: 9))
                }.buttonStyle(.workspace)
              }
              .padding(.horizontal, 10).padding(.vertical, 7)
              .background(
                manager.selectedID == session.id ? Color.accentColor.opacity(0.18) : Color.clear
              )
              .clipShape(RoundedRectangle(cornerRadius: 5))
              .overlay(
                RoundedRectangle(cornerRadius: 5).stroke(
                  manager.selectedID == session.id ? Color.accentColor.opacity(0.5) : .clear)
              )
              .onTapGesture { manager.selectedID = session.id }
              .contextMenu {
                Button(store.text("Rename", "重命名")) {
                  renaming = session.id
                  newName = session.name
                }
                Button(store.text("Restart Shell", "重启 Shell")) {
                  if session.exited {
                    session.start(settings: store.settings)
                  } else {
                    closing = session.id
                  }
                }.disabled(session.agentConfiguration != nil)
                Button(store.text("Split with this session", "与此会话分屏")) {
                  if manager.selectedID != session.id { manager.splitID = session.id }
                }
                Button(store.text("Close", "关闭")) { closing = session.id }
              }
            }
          }.padding(.vertical, 4)
        }
        IconButton("plus", help: store.text("New terminal (⌘T)", "新终端 (⌘T)")) {
          manager.add(settings: store.settings)
        }
        Menu {
          ForEach(["/bin/zsh", "/bin/bash", "/opt/homebrew/bin/fish"], id: \.self) { path in
            Button(path) {
              var settings = store.settings
              settings.shellPath = path
              manager.add(settings: settings)
            }
          }
        } label: {
          Image(systemName: "chevron.down")
        }.menuStyle(.borderlessButton).frame(width: 18)
        Spacer(minLength: 4)
        IconButton("magnifyingglass", help: store.text("Search terminal", "搜索终端")) {
          showSearch.toggle()
        }
        if manager.splitID != nil {
          IconButton("rectangle", help: store.text("End split", "结束分屏")) { manager.splitID = nil }
        }
        IconButton(
          model.panels.layout.terminalMaximized
            ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
          help: store.text("Maximize / Restore", "最大化 / 恢复")
        ) {
          var layout = model.panels.layout
          layout.terminalMaximized.toggle()
          model.editLayout(layout)
        }
        IconButton("minus", help: store.text("Hide terminal (⌥F12)", "隐藏终端 (⌥F12)")) {
          var layout = model.panels.layout
          layout.terminalVisible = false
          model.editLayout(layout)
        }
      }.font(uiFont(size: 12)).padding(.trailing, 12).frame(height: 39).background(
        Theme.panel(scheme))
      Divider()
      if showSearch {
        HStack {
          TextField(store.text("Find in terminal…", "在终端中查找…"), text: $search).textFieldStyle(
            .plain
          ).onSubmit { _ = manager.selected?.view.findNext(search) }
          IconButton("chevron.up", help: localizedUI("Previous")) {
            _ = manager.selected?.view.findPrevious(search)
          }
          IconButton("chevron.down", help: localizedUI("Next")) {
            _ = manager.selected?.view.findNext(search)
          }
          IconButton("xmark", help: localizedUI("Close Search")) {
            showSearch = false
            manager.selected?.view.clearSearch()
          }
        }.padding(8).background(Theme.panel(scheme))
        Divider()
      }
      if let session = manager.selected {
        HSplitView {
          terminalContent(session)
          if let split = manager.sessions.first(where: { $0.id == manager.splitID }),
            split.id != session.id
          {
            terminalContent(split)
          }
        }
      } else {
        VStack(spacing: 12) {
          Image(systemName: "terminal").font(uiFont(size: 28)).foregroundStyle(.secondary)
          Button(store.text("Start a local terminal", "启动本地终端")) {
            manager.add(settings: store.settings)
          }
          Text(model.record.path).font(uiFont(size: 11, design: .monospaced)).foregroundStyle(
            .secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }.background(Theme.editor(scheme))
      .onReceive(NotificationCenter.default.publisher(for: .gitpierSearch)) { event in
        if event.object as? String == "terminal" {
          showSearch = true
          searchFocused = true
        }
      }
      .confirmationDialog(
        store.text("Close this terminal session?", "关闭此终端会话？"),
        isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } })
      ) {
        Button(store.text("Close and stop processes", "关闭并停止进程"), role: .destructive) {
          if let closing { manager.close(closing) }
          closing = nil
        }
      } message: {
        Text(
          store.text(
            "The shell and jobs attached to this terminal will be stopped.", "将停止此终端的 Shell 及关联作业。")
        )
      }
      .alert(
        store.text("Rename Terminal", "重命名终端"),
        isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
      ) {
        TextField(store.text("Name", "名称"), text: $newName)
        Button(store.text("Save", "保存")) {
          if let session = manager.sessions.first(where: { $0.id == renaming }), !newName.isEmpty {
            session.name = newName
            session.customName = true
          }
          renaming = nil
        }
        Button(store.text("Cancel", "取消"), role: .cancel) { renaming = nil }
      }
  }
  @ViewBuilder func terminalContent(_ session: TerminalSession) -> some View {
    VStack(spacing: 0) {
      if session.exited {
        HStack {
          Text(
            store.text("Shell exited", "Shell 已退出") + (session.exitCode.map { " (\($0))" } ?? ""))
          Spacer()
          if session.agentConfiguration == nil {
            Button(store.text("Restart", "重新启动")) { session.start(settings: store.settings) }
          } else { Text(store.text("Start a new session from Task Workspaces.", "请从任务工作空间确认启动新会话。")) }
        }.font(uiFont(size: 11)).padding(6).background(Theme.panel(scheme))
      }
      TerminalHost(session: session, settings: store.settings, dark: scheme == .dark).id(session.id)
        .padding(
          .horizontal, 8
        ).padding(.top, 4)
    }.frame(minWidth: 220)
  }
}
