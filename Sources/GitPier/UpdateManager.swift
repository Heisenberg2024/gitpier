import AppKit
import Combine
import GitPierCore
import Sparkle
import SwiftUI

@MainActor
final class UpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate,
  @preconcurrency SPUStandardUserDriverDelegate
{
  enum State: Equatable {
    case unavailable, idle, checking, current
    case available(String)
    case downloading, verifying, ready, waiting, installing, cancelled, restartCancelled
    case failed(String)
  }
  @Published private(set) var state: State = .unavailable
  @Published private(set) var canCheck = false
  @Published private(set) var automaticChecks = false
  @Published private(set) var lastCheck: Date?
  @Published private(set) var latestVersion: String?
  @Published private(set) var waitingToInstall = false
  private var controller: SPUStandardUpdaterController?
  private var installHandler: (() -> Void)?
  private unowned let store: AppStore
  private var started = false
  private var installationWritable: Bool {
    let app = Bundle.main.bundleURL
    return FileManager.default.isWritableFile(atPath: app.path)
      && FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
  }
  private var testing: Bool {
    Bundle.main.object(forInfoDictionaryKey: "GitPierTestingUpdates") as? Bool == true
      && (Bundle.main.bundleIdentifier ?? "").hasPrefix("com.heisenberg2024.gitpier.update-test.")
  }
  var configured: Bool {
    guard Bundle.main.bundlePath.hasSuffix(".app"),
      let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
      Data(base64Encoded: key)?.count == 32,
      let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    else { return false }
    let config = AppResources.releaseConfiguration
    guard config.hasSigningKey, key == config.publicEDKey,
      Bundle.main.bundleIdentifier == config.bundleIdentifier, feed == config.feedURL
    else { return false }
    if testing {
      guard let url = URL(string: feed) else { return false }
      return url.scheme == "http" && url.host == "127.0.0.1" && url.port != nil
        && url.path == "/appcast.xml" && url.user == nil && url.password == nil
    }
    return config.bundleIdentifier == "com.heisenberg2024.gitpier"
      && feed == "https://github.com/Heisenberg2024/gitpier/releases/latest/download/appcast.xml"
  }
  init(store: AppStore) {
    self.store = store
    super.init()
  }
  func start() {
    guard !started, configured else { return }
    started = true
    let controller = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    self.controller = controller
    controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticChecks)
    controller.updater.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastCheck)
    state = .idle
    // No automatic downloads or install-on-quit. The standard driver owns all update UI.
    controller.startUpdater()
  }
  func check() {
    start()
    controller?.checkForUpdates(nil)
  }
  func setAutomaticChecks(_ enabled: Bool) {
    start()
    controller?.updater.automaticallyChecksForUpdates = enabled
  }
  func resumeInstallation() {
    guard let handler = installHandler, !store.hasRunningGitOperations, installationWritable else {
      return
    }
    installHandler = nil
    waitingToInstall = false
    handler()  // Sparkle still calls the normal application termination delegate.
  }
  func terminationWasCancelled() {
    guard controller != nil, installHandler == nil else { return }
    if state == .waiting || state == .ready || state == .installing {
      waitingToInstall = false
      state = .restartCancelled
    }
  }
  var canResumeInstallation: Bool {
    waitingToInstall && !store.hasRunningGitOperations && installationWritable
  }
  private func failure(_ description: String) -> NSError {
    NSError(domain: "GitPier.Updates", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
  }
  @objc(updater:mayPerformUpdateCheck:error:)
  func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
    guard configured else {
      throw failure(store.text("Update signing is not configured.", "尚未配置更新签名。"))
    }
    let url = Bundle.main.bundleURL.standardizedFileURL
    let values = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey])
    guard values?.volumeIsReadOnly != true, !url.path.contains("/AppTranslocation/") else {
      throw failure(
        store.text(
          "Install GitPier in Applications before updating. Download the DMG from GitHub Releases if needed.",
          "请先将 GitPier 安装到 Applications 再更新；必要时从 GitHub Releases 下载 DMG。"))
    }
    guard installationWritable else {
      throw failure(
        store.text(
          "This installation cannot be replaced with your current permissions. Use a manual DMG upgrade.",
          "当前权限无法替换此安装，请手动通过 DMG 升级。"))
    }
    state = .checking
  }
  @objc(updater:shouldProceedWithUpdate:updateCheck:error:)
  func updater(
    _ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck
  ) throws {
    guard let url = item.fileURL, url.pathExtension.lowercased() == "dmg", item.contentLength > 0,
      Int(item.versionString) != nil
    else { throw failure(store.text("The update metadata is invalid.", "更新元数据无效。")) }
    if !testing {
      let expected =
        "/Heisenberg2024/gitpier/releases/download/v\(item.displayVersionString)/GitPier-\(item.displayVersionString)-macos-universal.dmg"
      guard url.scheme == "https", url.host == "github.com", url.path == expected,
        item.displayVersionString.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil
      else {
        throw failure(
          store.text("The update is not a stable GitPier release.", "此更新不是 GitPier 稳定版。"))
      }
    } else {
      let feed = URL(string: AppResources.releaseConfiguration.feedURL)!
      guard url.scheme == "http", url.host == "127.0.0.1", url.port == feed.port,
        url.user == nil, url.password == nil
      else {
        throw failure("Test updates must remain on the isolated loopback server.")
      }
    }
  }
  func allowedChannels(for updater: SPUUpdater) -> Set<String> { [] }
  func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    latestVersion = item.displayVersionString + " (" + item.versionString + ")"
    state = .available(latestVersion!)
  }
  func updaterDidNotFindUpdate(_ updater: SPUUpdater) { state = .current }
  func updater(
    _ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest
  ) { state = .downloading }
  func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) { state = .verifying }
  func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) { state = .verifying }
  func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) { state = .ready }
  func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { state = .installing }
  func userDidCancelDownload(_ updater: SPUUpdater) { state = .cancelled }
  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
    if state != .current && state != .cancelled && state != .restartCancelled {
      state = .failed(GitService.redact(error.localizedDescription))
    }
    installHandler = nil
    waitingToInstall = false
  }
  func updater(
    _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
    untilInvokingBlock installHandler: @escaping () -> Void
  ) -> Bool {
    postponeInstallation(installHandler)
  }
  func postponeInstallation(_ installHandler: @escaping () -> Void) -> Bool {
    guard store.hasRunningGitOperations || !installationWritable else { return false }
    self.installHandler = installHandler
    waitingToInstall = true
    state = .waiting
    return true
  }
  var supportsGentleScheduledUpdateReminders: Bool { true }
  func standardUserDriverWillFinishUpdateSession() {
    if installHandler == nil, state == .waiting {
      waitingToInstall = false
      state = .restartCancelled
    }
  }
  func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
  ) -> Bool { false }
  func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
  ) {
    if !handleShowingUpdate {
      store.notice = store.text(
        "A GitPier update is available. Open Settings → About to review it.",
        "GitPier 有可用更新，请打开设置 → 关于查看。")
    }
  }
  var statusText: String {
    switch state {
    case .unavailable:
      return store.text(
        "Updates are unavailable until the release signing key is configured.", "配置正式更新签名公钥后才能启用更新。"
      )
    case .idle: return store.text("Ready to check", "可以检查更新")
    case .checking: return store.text("Checking for updates…", "正在检查更新…")
    case .current: return store.text("GitPier is up to date", "GitPier 已是最新版本")
    case .available(let version): return store.text("Update available: ", "可用更新：") + version
    case .downloading: return store.text("Downloading…", "正在下载…")
    case .verifying: return store.text("Verifying the signed update…", "正在验证更新签名…")
    case .ready: return store.text("Ready to install — waiting for confirmation", "已准备安装，等待确认")
    case .waiting:
      if !installationWritable {
        return store.text(
          "This installation is no longer writable. Use a manual DMG upgrade.",
          "此安装位置已无法写入，请手动通过 DMG 升级。")
      }
      return store.text(
        "Finish Git operations, then resume installation here.", "请结束 Git 操作，再在此继续安装。")
    case .installing: return store.text("Installing and restarting…", "正在安装并重新启动…")
    case .cancelled: return store.text("Update cancelled", "更新已取消")
    case .restartCancelled:
      return store.text(
        "Restart cancelled. GitPier remains open; check for updates when you are ready.",
        "已取消重启，GitPier 继续运行；准备好后可再次检查更新。")
    case .failed(let reason): return reason
    }
  }
}

struct UpdateSettingsView: View {
  @ObservedObject var manager: UpdateManager
  @EnvironmentObject var store: AppStore
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(store.text("Updates", "更新")).font(.headline)
        Spacer()
        Button(store.text("Check for Updates…", "检查更新…")) { manager.check() }
          .disabled(!manager.configured || !manager.canCheck)
      }
      Toggle(
        store.text("Automatically check for updates", "自动检查更新"),
        // An explicit setter avoids Swift 6.1's isolated method-reference IRGen crash.
        isOn: Binding(
          get: { manager.automaticChecks },
          set: { enabled in manager.setAutomaticChecks(enabled) })
      )
      .disabled(!manager.configured)
      Text(manager.statusText).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
      if let date = manager.lastCheck {
        Text(store.text("Last checked: ", "上次检查：") + date.formatted()).font(.caption)
          .foregroundStyle(.secondary)
      }
      if manager.waitingToInstall {
        Button(store.text("Resume Installation…", "继续安装…")) { manager.resumeInstallation() }
          .disabled(!manager.canResumeInstallation)
      }
      Link(
        store.text("GitHub Releases / Manual DMG Upgrade", "GitHub Releases / 手动 DMG 升级"),
        destination: URL(string: "https://github.com/Heisenberg2024/gitpier/releases/latest")!)
      Text(
        store.text(
          "Update dialogs follow the selected language after restarting GitPier.",
          "重新启动 GitPier 后，更新对话框会使用所选语言。")
      )
      .font(.caption).foregroundStyle(.secondary)
      Text(
        store.text(
          "Downloads and installation require your confirmation. Restarting ends terminal sessions; commit drafts are saved.",
          "下载和安装需要确认。重启会结束终端会话，提交草稿已保存。")
      )
      .font(.caption).foregroundStyle(.secondary)
    }.onAppear { manager.start() }
  }
}

struct UpdateCheckMenu: View {
  @ObservedObject var manager: UpdateManager
  @EnvironmentObject var store: AppStore
  var body: some View {
    Button(store.text("Check for Updates…", "检查更新…")) { manager.check() }
      .disabled(!manager.configured || !manager.canCheck)
  }
}
