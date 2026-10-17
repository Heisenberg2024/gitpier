import GitPierCore
import SwiftUI

extension HostingModel {
  func storageTitle(_ mode: HostingStorageMode) -> String {
    mode == .localVault ? store.text("Local Encrypted Vault", "本地加密凭证库") : store.text("macOS Keychain", "系统钥匙串")
  }
  func storageExplanation(_ mode: HostingStorageMode) -> String {
    mode == .localVault
      ? store.text("AES-256-GCM with a separate random key saved on this Mac. No extra password or OAuth Keychain authorization. Anyone who obtains both key and encrypted files can recover the credentials. FileVault adds protection while the disk is locked.", "使用 AES-256-GCM 和保存在本机的独立随机密钥，无需额外密码或 OAuth 钥匙串授权。若密钥和密文同时泄露，凭证可被恢复；FileVault 可增加磁盘锁定时的保护。")
      : store.text("macOS manages credential access permissions. The system may request authorization, including after an ad-hoc signed application update.", "由 macOS 管理凭证访问权限。系统可能要求授权，包括 ad-hoc 签名应用更新后。")
  }
}

struct HostingStorageSheet: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var hosting: HostingModel
  let account: HostingAccount
  @State private var target: HostingStorageMode
  @State private var readStored = false
  @State private var cleanup = false
  @State private var reauthorizing = false
  @State private var busy = false
  @State private var error: String?
  @State private var task: Task<Void, Never>?
  private var switched: Bool { hosting.account(account.id)?.storageMode == target }
  init(hosting: HostingModel, account: HostingAccount) {
    self.hosting = hosting; self.account = account
    _target = State(initialValue: account.storageMode == .keychain ? .localVault : .keychain)
    _cleanup = State(initialValue: account.storageMode == .localVault)
  }
  var body: some View {
    Group {
      if reauthorizing {
        HostingConnectSheet(hosting: hosting, request: HostingConnectionRequest(provider: account.instance.provider, account: account, storageMode: target))
      } else {
        VStack(alignment: .leading, spacing: 16) {
          Text(store.text("Change Storage Method", "更换存储方式")).font(.title2.weight(.semibold))
          Text(account.instance.provider.title + " · @" + account.user.login).foregroundStyle(.secondary)
          Picker(store.text("Credential Storage", "凭证存储"), selection: $target) {
            Text(hosting.storageTitle(account.storageMode == .keychain ? .localVault : .keychain)).tag(account.storageMode == .keychain ? HostingStorageMode.localVault : .keychain)
          }
          Text(hosting.storageExplanation(target)).font(.callout).fixedSize(horizontal: false, vertical: true)
          Button(store.text("Reauthorize into New Storage (Recommended)…", "重新授权并保存到新存储（推荐）…")) { reauthorizing = true }
          Text(store.text("A fresh authorization avoids reading the old Keychain. For PAT, enter a token again. The original copy is retained for explicit cleanup.", "重新授权无需读取旧钥匙串；PAT 可重新输入 Token。原副本保留，供后续主动清理。"))
            .font(.caption).foregroundStyle(.secondary)
          Divider()
          Toggle(store.text("Read stored credentials if no memory session is available", "内存会话不可用时读取已存储的凭证"), isOn: $readStored)
          Text(store.text("Otherwise, use only this account's current memory token. Reading or deleting a Keychain item may request your macOS password; cancellation preserves the source.", "否则仅使用此账号当前的内存 Token。读取或删除 Keychain 项可能要求 macOS 密码；取消后保留原存储。"))
            .font(.caption).foregroundStyle(.secondary)
          Toggle(store.text("Clean up the previous copy after a successful switch", "切换成功后清理原副本"), isOn: $cleanup)
          if let error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
          HStack {
            Button(switched ? store.text("Done", "完成") : store.text("Cancel", "取消"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button(store.text("Confirm Change", "确认切换")) {
              busy = true; error = nil
              task = Task {
                defer { busy = false }
                do { try await hosting.changeStorage(account, to: target, allowStoredRead: readStored, cleanup: cleanup); dismiss() }
                catch {
                  self.error = (switched ? store.text("Storage changed successfully. Previous-copy cleanup can be retried from the account. ", "存储已成功切换，可在账号中重试清理旧副本。") : "") + hosting.message(error)
                }
              }
            }.buttonStyle(.borderedProminent).disabled(switched).accessibilityIdentifier("hosting-confirm-storage")
          }
        }.padding(24).frame(width: 590).disabled(busy)
      }
    }.onDisappear { task?.cancel() }
  }
}
