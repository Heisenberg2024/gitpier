import AppKit
import GitPierCore
import SwiftUI

/// Sections for the Terminal settings form; state stays with this view.
struct CLISettingsSections: View {
  @EnvironmentObject var store: AppStore
  @State private var installed = false
  @State private var message: String?
  @State private var selectedApplication: URL?
  private let installation = CLIToolInstallation()
  var body: some View {
    Group {
      Section(store.text("GitPier CLI", "GitPier 命令行工具")) {
        Text(store.text("Open repositories from your terminal with gitpier open . Navigation only; Git writes still require their normal workflows.", "在终端使用 gitpier open . 打开仓库。CLI 仅负责导航，Git 写入继续使用原有工作流。"))
        Text(installation.executable.path).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
        Text(selectedApplication?.lastPathComponent ?? "GitPier.app").foregroundStyle(.secondary)
        HStack {
          Button(store.text("Install Command Line Tool", "安装命令行工具")) { install() }.disabled(installed)
          Button(store.text("Uninstall Command Line Tool", "卸载命令行工具")) { uninstall() }.disabled(!installed)
          Button(store.text("Choose GitPier App…", "选择 GitPier 应用…")) {
            let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
            panel.allowedContentTypes = [.applicationBundle]
            if panel.runModal() == .OK { selectedApplication = panel.url }
          }.disabled(installed)
        }
        Text(store.text("Existing files are preserved. To select another GitPier copy, uninstall this launcher first, then select the app and reinstall. No administrator access is requested.", "保留已有文件。若要改用另一份 GitPier，请先卸载此启动器，再选择应用并重新安装。不会请求管理员权限。" )).font(.callout).foregroundStyle(.secondary)
        if let message { Text(message).textSelection(.enabled).foregroundStyle(.secondary) }
      }
      Section(store.text("Terminal PATH", "终端 PATH")) {
        Text(store.text("If ~/.local/bin is absent from PATH, add it yourself in your shell configuration, then open a new terminal. GitPier does not edit shell files.", "如果 PATH 未包含 ~/.local/bin，请自行在 Shell 配置中加入后重新打开终端。GitPier 不会编辑 Shell 文件。"))
        Text("export PATH=\"$HOME/.local/bin:$PATH\"").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
        Text("gitpier open . --page history").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
      }
    }.onAppear { refresh() }
  }
  private func refresh() {
    if let receipt = try? installation.receipt() {
      installed = true; selectedApplication = try? receipt.application()
    } else { installed = false }
  }
  private func install() {
    do {
      let app = selectedApplication ?? Bundle.main.bundleURL
      guard let bundle = Bundle(url: app), let id = bundle.bundleIdentifier,
        id == "com.heisenberg2024.gitpier" || id.hasPrefix("com.heisenberg2024.gitpier.") else {
        throw GitPierError.invalidInput(store.text("Choose a GitPier application.", "请选择 GitPier 应用。"))
      }
      try installation.install(source: app.appendingPathComponent("Contents/Helpers/gitpier"), application: app, bundleIdentifier: id)
      message = store.text("Installed. Run gitpier --help from your terminal.", "已安装，可在终端执行 gitpier --help。")
    } catch { message = store.settings.language == .english ? error.localizedDescription : "无法安装命令行工具。请检查所选应用、目录权限和已有安装；已有文件已保留。" }
    refresh()
  }
  private func uninstall() {
    do { try installation.uninstall(); message = store.text("Command line tool removed.", "命令行工具已卸载。") }
    catch { message = store.settings.language == .english ? error.localizedDescription : "无法核实并卸载命令行工具。已有文件已保留，请检查安装文件和归属凭据是否被修改。" }
    refresh()
  }
}
