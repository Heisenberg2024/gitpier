import AppKit
import GitPierCore
import SwiftUI

extension UIAcceptance {
  static func pressNativeButton(_ host: NSView, title: String) throws {
    guard let button = accessibleButton(host, title: title, enabled: true) else {
      throw GitPierError.invalidInput("Missing enabled native workflow button: " + title)
    }
    let selector = NSSelectorFromString("accessibilityPerformPress")
    typealias Press = @convention(c) (AnyObject, Selector) -> Bool
    let press = unsafeBitCast(button.method(for: selector), to: Press.self)
    guard press(button, selector) else { throw GitPierError.invalidInput("Native workflow press failed: " + title) }
  }
  static func verifyAdvanced130(store: AppStore, model: RepositoryModel, git: GitService, root: URL,
                                source: URL, host: NSHostingView<AnyView>, window: NSWindow, output: URL) async throws {
    let originalSettings = store.settings
    let originalText = try String(contentsOf: source, encoding: .utf8)
    try "let value = 4\n".write(to: source, atomically: true, encoding: .utf8)
    let change = try await git.status().files.first { $0.path == "workflow.swift" }!
    let patch = try await git.exportFilePatch(change, comparison: .unstaged)
    try originalText.write(to: source, atomically: true, encoding: .utf8)
    let hostLFS = try await git.lfsState()
    guard !hostLFS.installed || !hostLFS.version.isEmpty else { throw GitPierError.invalidInput("LFS environment detection was ambiguous") }

    let origin = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-v130-module-origin-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: origin); store.updateSettings(originalSettings) }
    let originGit = GitService(root: origin)
    await originGit.configure(gitPath: "/usr/bin/git", authEnvironment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
    try await originGit.perform(["init", "-b", "main"])
    try await originGit.perform(["config", "user.name", "Module Acceptance"])
    try await originGit.perform(["config", "user.email", "module@example.invalid"])
    try await originGit.perform(["config", "commit.gpgsign", "false"])
    try "module content\n".write(to: origin.appendingPathComponent("content.txt"), atomically: true, encoding: .utf8)
    try await originGit.stage(try await originGit.status().files)
    _ = try await originGit.commit(message: "module fixture", expected: originGit.snapshot())
    await git.configure(gitPath: "/usr/bin/git", authArguments: ["-c", "protocol.file.allow=always"],
                        authEnvironment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
    let add = try await git.reviewSubmoduleAdd(url: origin.path, path: "module")
    _ = try await git.addSubmodule(add)
    await model.refresh()
    let module = try await git.submodules()[0]
    let moduleReview = try await git.reviewSubmodule(module.path, action: .recorded)

    let oid = String(repeating: "a", count: 64)
    let pointer = "version https://git-lfs.github.com/spec/v1\noid sha256:" + oid + "\nsize 2048\n"
    try pointer.write(to: root.appendingPathComponent("asset.bin"), atomically: true, encoding: .utf8)
    let wrapper = root.appendingPathComponent(".git/git-lfs-interface-fixture")
    let script = """
      #!/bin/sh
      found=0
      command=''
      for arg in "$@"; do
        if [ "$found" = 1 ]; then command="$arg"; break; fi
        [ "$arg" = lfs ] && found=1
      done
      if [ "$found" = 1 ]; then
        case "$command" in
          version) echo 'git-lfs/3.7.1 (UI interface fixture)'; exit 0;;
          ls-files) printf '%s\\n' '{"files":[{"name":"asset.bin","size":2048,"checkout":false,"downloaded":true,"oid_type":"sha256","oid":"\(oid)","version":"https://git-lfs.github.com/spec/v1"}]}'; exit 0;;
          track) echo 'Listing tracked patterns'; echo '    *.bin (.gitattributes)'; exit 0;;
        esac
        echo 'Network is disabled in this UI interface fixture' >&2; exit 1
      fi
      exec /usr/bin/git "$@"
      """ + "\n"
    try script.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    await git.configure(gitPath: wrapper.path, authEnvironment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
    let service = await model.git()
    await service.configure(gitPath: wrapper.path, authEnvironment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
    let rule = try await git.reviewLFSRule("*.bin", track: true)
    let before = try await git.reviewOperation()
    let indexBefore = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    let commit = try await git.commitDetail("HEAD")
    var renderings = 0
    for language in AppLanguage.allCases {
      for appearance in [AppearanceMode.light, .dark] {
        var settings = originalSettings; settings.language = language; settings.appearance = appearance
        store.updateSettings(settings)
        let variants: [(String, AnyView, String)] = [
          ("patch-import", AnyView(PatchImportView(model: model, input: PatchImportRequest(name: "fixture.patch", data: patch))), store.text("Apply Reviewed Patch…", "应用已审查补丁…")),
          ("patch-export", AnyView(PatchExportView(model: model, source: .commit(commit))), store.text("Save Patch…", "保存补丁…")),
          ("lfs-installed-interface", AnyView(LFSView(model: model)), store.text("Open .gitattributes", "打开 .gitattributes")),
          ("lfs-rule", AnyView(LFSRuleReviewView(model: model, review: rule)), store.text("Apply Rule Change", "应用规则修改")),
          ("submodules", AnyView(SubmodulesView(model: model)), store.text("Checkout Recorded Commit…", "检出记录提交…")),
          ("submodule-review", AnyView(SubmoduleReviewView(model: model, review: moduleReview)), store.text("Confirm Operation…", "确认操作…")),
          ("submodule-add", AnyView(SubmoduleAddView(model: model)), store.text("Review", "审查"))
        ]
        for (name, content, ready) in variants {
          window.setContentSize(NSSize(width: 960, height: 640)); host.frame = NSRect(x: 0, y: 0, width: 960, height: 640)
          host.rootView = AnyView(content.environmentObject(store).modifier(AppAppearance(store: store)))
          try await settle()
          let enabled = name == "submodule-add" ? false : true
          try await waitFor { accessibleButton(host, title: ready, enabled: enabled) != nil }
          if name == "patch-import" || name == "lfs-rule" {
            guard descendants(host).contains(where: { $0 is DiffSplitContainer }) else {
              throw GitPierError.invalidInput("A workflow preview did not reuse native Diff")
            }
          }
          try capture(host, to: output.appendingPathComponent("v130-" + name + "-" + language.rawValue + "-" + appearance.rawValue + ".png"))
          renderings += 1
          host.rootView = AnyView(EmptyView()); try await settle()
        }
      }
    }
    guard try await git.reviewOperation() == before, try Data(contentsOf: root.appendingPathComponent(".git/index")) == indexBefore else {
      throw GitPierError.invalidInput("Read-only P1 interfaces changed repository state")
    }
    // Exercise the actual native confirmation and model write path against the fixture.
    host.rootView = AnyView(PatchImportView(model: model, input: PatchImportRequest(name: "fixture.patch", data: patch))
      .environmentObject(store).modifier(AppAppearance(store: store)))
    try await waitFor { accessibleButton(host, title: store.text("Apply Reviewed Patch…", "应用已审查补丁…"), enabled: true) != nil }
    try pressNativeButton(host, title: store.text("Apply Reviewed Patch…", "应用已审查补丁…"))
    try await waitFor { window.attachedSheet != nil }; try await settle()
    guard let sheet = window.attachedSheet?.contentView,
      let confirm = descendants(sheet).compactMap({ $0 as? NSButton }).first(where: { $0.title == store.text("Apply Patch", "应用补丁") }) else {
      throw GitPierError.invalidInput("Missing native Patch confirmation")
    }
    confirm.performClick(nil)
    try await waitFor { !model.busy }; try await settle()
    guard try String(contentsOf: source, encoding: .utf8) == "let value = 4\n",
      try Data(contentsOf: root.appendingPathComponent(".git/index")) == indexBefore else {
      throw GitPierError.invalidInput("Patch UI changed Index or failed to apply the reviewed working patch")
    }
    host.rootView = AnyView(EmptyView()); try await settle()
    host.rootView = AnyView(LFSRuleReviewView(model: model, review: rule).environmentObject(store).modifier(AppAppearance(store: store)))
    try await settle(); try pressNativeButton(host, title: store.text("Apply Rule Change", "应用规则修改"))
    try await waitFor { !model.busy }; try await settle()
    guard try Data(contentsOf: root.appendingPathComponent(".gitattributes")) == rule.after,
      try Data(contentsOf: root.appendingPathComponent(".git/index")) == indexBefore else {
      throw GitPierError.invalidInput("LFS rule UI changed Index or lost the approved attributes")
    }
    host.rootView = AnyView(EmptyView())
    await model.configure()
    try originalText.write(to: source, atomically: true, encoding: .utf8); await model.refresh()
    try "P1 native rendering: \(renderings) views across English/Chinese and light/dark at 960×640. Patch and LFS rules reused native Diff. Read-only previews preserved HEAD/Index; real native Patch confirmation/model applied only the working file; LFS rule action changed only approved attributes. Installed LFS metadata was an isolated interface fixture with network disabled; host installation detected as \(hostLFS.installed). Submodule was a real temporary local clone. No public network, installation or global configuration write occurred.\n"
      .write(to: output.appendingPathComponent("advanced130-results.txt"), atomically: true, encoding: .utf8)
  }
}

/// Visible acceptance controls live only in the isolated --ui-acceptance workflow.
/// The LFS executable is the marked, network-disabled fixture created above.
struct Advanced130ReviewPanel: View {
  @ObservedObject var model: RepositoryModel
  let patch: Data
  @EnvironmentObject var store: AppStore
  @State private var page = "import"
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Picker("Fixture", selection: $page) {
          Text("Patch Import").tag("import")
          Text("Patch Export").tag("export")
          Text("Git LFS").tag("lfs")
          Text("Submodules").tag("submodules")
        }.frame(width: 235)
        Picker("Language", selection: Binding(get: { store.settings.language }, set: { value in
          var settings = store.settings; settings.language = value; store.updateSettings(settings)
        })) {
          Text("English").tag(AppLanguage.english)
          Text("简体中文").tag(AppLanguage.simplifiedChinese)
        }.frame(width: 200)
        Picker("Appearance", selection: Binding(get: { store.settings.appearance }, set: { value in
          var settings = store.settings; settings.appearance = value; store.updateSettings(settings)
        })) {
          Text("Light").tag(AppearanceMode.light)
          Text("Dark").tag(AppearanceMode.dark)
        }.frame(width: 185)
        Spacer()
      }.padding(12)
      Text("Isolated acceptance · temporary repository · LFS interface fixture · network disabled")
        .font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
      Divider()
      Group {
        switch page {
        case "export": PatchExportView(model: model, source: .range)
        case "lfs": LFSView(model: model)
        case "submodules": SubmodulesView(model: model)
        default: PatchImportView(model: model, input: PatchImportRequest(name: "fixture.patch", data: patch))
        }
      }.id(page).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}
