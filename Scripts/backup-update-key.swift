// Owner-invoked local backup. Secrets stay in memory, Keychain or an encrypted volume.
import CryptoKit
import Foundation
import Security

struct BackupError: Error { let message: String }
func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw BackupError(message: message) }
}
@discardableResult
func run(_ executable: String, _ arguments: [String], password: Data? = nil) throws -> Data {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  let output = Pipe()
  let errors = Pipe()
  process.standardOutput = output
  process.standardError = errors
  let input = Pipe()
  process.standardInput = input
  try process.run()
  if let password {
    try input.fileHandleForWriting.write(contentsOf: password + Data([0]))
  }
  try input.fileHandleForWriting.close()
  let response = output.fileHandleForReading.readDataToEndOfFile()
  let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  // Do not relay subprocess text: future tool errors might contain secret material.
  if process.terminationStatus != 0 {
    var diagnostic = "\(URL(fileURLWithPath: executable).lastPathComponent) \(arguments.first ?? "") failed (\(process.terminationStatus))."
    if executable == "/usr/bin/hdiutil", var detail = String(data: diagnostics, encoding: .utf8) {
      if let password, let secretText = String(data: password, encoding: .utf8) {
        detail = detail.replacingOccurrences(of: secretText, with: "<redacted>")
      }
      diagnostic += "\n" + detail
    }
    throw BackupError(message: diagnostic)
  }
  return response
}
let manager = FileManager.default
let service = "com.heisenberg2024.gitpier.signing-backup"
func keychainQuery(_ account: String) -> [String: Any] {
  [kSecClass as String: kSecClassGenericPassword,
   kSecAttrService as String: service,
   kSecAttrAccount as String: account,
   kSecAttrSynchronizable as String: false]
}
func readPassword(_ account: String) throws -> Data {
  var query = keychainQuery(account)
  query[kSecReturnData as String] = true
  var result: CFTypeRef?
  let status = SecItemCopyMatching(query as CFDictionary, &result)
  try require(status == errSecSuccess, "Cannot read backup password from Keychain (\(status)).")
  guard let data = result as? Data else { throw BackupError(message: "Invalid backup password record.") }
  return data
}
func storePassword(_ password: Data, account: String) throws {
  var query = keychainQuery(account)
  query[kSecAttrLabel as String] = "GitPier production update backup password"
  query[kSecAttrDescription as String] = "encrypted disk image password"
  query[kSecAttrIsSensitive as String] = true
  query[kSecValueData as String] = password
  let status = SecItemAdd(query as CFDictionary, nil)
  try require(status == errSecSuccess, "Cannot store backup password in Keychain (\(status)).")
}
func verifyPrivateKey(_ file: URL, publicKey: String) throws {
  let attributes = try manager.attributesOfItem(atPath: file.path)
  try require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Private backup file must have mode 0600.")
  let encoded = try Data(contentsOf: file)
  guard let seed = Data(base64Encoded: encoded), seed.count == 32 else {
    throw BackupError(message: "Expected Sparkle's 32-byte seed backup format.")
  }
  let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
  try require(key.publicKey.rawRepresentation.base64EncodedString() == publicKey, "Backup public key mismatch.")
  let proof = Data("GitPier signing backup recovery verification".utf8)
  let signature = try key.signature(for: proof)
  try require(key.publicKey.isValidSignature(signature, for: proof), "Backup signing proof failed.")
}
func mount(_ image: URL, at mountPoint: URL, password: Data, readOnly: Bool) throws {
  try manager.createDirectory(at: mountPoint, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  try run("/usr/bin/hdiutil", ["attach", image.path, readOnly ? "-readonly" : "-readwrite",
      "-nobrowse", "-noautoopen", "-owners", "on", "-stdinpass", "-mountpoint", mountPoint.path], password: password)
}
func unmount(_ mountPoint: URL) throws {
  try run("/usr/bin/hdiutil", ["detach", mountPoint.path])
  try manager.removeItem(at: mountPoint)
}
do {
  let arguments = CommandLine.arguments
  try require(arguments.count == 4 && ["create", "verify"].contains(arguments[1]),
      "Usage: swift Scripts/backup-update-key.swift create|verify /absolute/backup.dmg /absolute/repository")
  let image = URL(fileURLWithPath: arguments[2]).standardizedFileURL
  let root = URL(fileURLWithPath: arguments[3]).resolvingSymlinksInPath()
  try require(arguments[2].hasPrefix("/") && image.pathExtension == "dmg", "Backup must be an absolute .dmg path.")
  try require(!image.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"), "Backup must be outside the repository.")
  let configData = try Data(contentsOf: root.appendingPathComponent("Sources/GitPier/Resources/ReleaseConfiguration.json"))
  let config = try JSONSerialization.jsonObject(with: configData) as! [String: String]
  let publicKey = config["publicEDKey"] ?? ""
  try require(Data(base64Encoded: publicKey)?.count == 32, "Configure the production public key first.")
  let metadataURL = image.appendingPathExtension("json")
  let mountPoint = manager.temporaryDirectory.appendingPathComponent("GitPierSigningBackup-" + UUID().uuidString)
  var mounted = false
  defer {
    if mounted { try? unmount(mountPoint) }
  }
  if arguments[1] == "create" {
    try require(!manager.fileExists(atPath: image.path) && !manager.fileExists(atPath: metadataURL.path), "Backup already exists.")
    let parent = image.deletingLastPathComponent()
    if !manager.fileExists(atPath: parent.path) {
      try manager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    let attributes = try manager.attributesOfItem(atPath: parent.path)
    try require((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0 == 0o700, "Backup parent must have mode 0700.")
    let tool = root.appendingPathComponent(".build/artifacts/sparkle/Sparkle/bin/generate_keys").path
    let actual = try run(tool, ["--account", "GitPier-production", "-p"])
    try require(String(data: actual, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == publicKey, "Keychain/config public key mismatch.")
    var bytes = [UInt8](repeating: 0, count: 32)
    try require(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess, "Random password generation failed.")
    let password = Data(bytes).base64EncodedData()
    let account = "GitPier-production-backup-" + UUID().uuidString
    try storePassword(password, account: account)
    try require(try readPassword(account) == password, "Backup password round-trip failed.")
    try run("/usr/bin/hdiutil", ["create", "-size", "32m", "-fs", "HFS+", "-volname", "GitPier Update Key Backup",
        "-type", "UDIF", "-encryption", "AES-256", "-stdinpass", image.path], password: password)
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: image.path)
    try mount(image, at: mountPoint, password: password, readOnly: false)
    mounted = true
    let privateFile = mountPoint.appendingPathComponent("GitPier-update-key.secret")
    try run(tool, ["--account", "GitPier-production", "-x", privateFile.path])
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateFile.path)
    try verifyPrivateKey(privateFile, publicKey: publicKey)
    try Data((publicKey + "\n").utf8).write(to: mountPoint.appendingPathComponent("public-key.txt"))
    try unmount(mountPoint)
    mounted = false
    let metadata: [String: String] = ["format": "AES-256 encrypted HFS+ disk image", "publicEDKey": publicKey,
        "keychainService": service, "keychainAccount": account, "createdAt": ISO8601DateFormatter().string(from: Date()),
        "sha256": SHA256.hash(data: try Data(contentsOf: image)).map { String(format: "%02x", $0) }.joined()]
    try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: metadataURL, options: .withoutOverwriting)
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
  }
  let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as! [String: String]
  try require(metadata["publicEDKey"] == publicKey && metadata["keychainService"] == service, "Backup metadata mismatch.")
  let hash = SHA256.hash(data: try Data(contentsOf: image)).map { String(format: "%02x", $0) }.joined()
  try require(hash == metadata["sha256"], "Backup image hash mismatch.")
  let password = try readPassword(metadata["keychainAccount"] ?? "")
  let imageInfo = try run("/usr/bin/hdiutil", ["isencrypted", "-plist", image.path])
  let info = try PropertyListSerialization.propertyList(from: imageInfo, format: nil) as! [String: Any]
  try require(info["encrypted"] as? Bool == true, "Backup image must be encrypted.")
  try mount(image, at: mountPoint, password: password, readOnly: true)
  mounted = true
  try verifyPrivateKey(mountPoint.appendingPathComponent("GitPier-update-key.secret"), publicKey: publicKey)
  try unmount(mountPoint)
  mounted = false
  print("Encrypted backup verified by read-only remount, public key and signing proof: \(image.path)")
  print("Password is stored separately in the login Keychain; copy it to secure offline storage using Keychain Access.")
} catch let error as BackupError {
  fputs(error.message + "\n", stderr)
  exit(1)
} catch {
  // Never render arbitrary secret-bearing error descriptions.
  fputs("Backup failed. No private key or password was printed; retain the Keychain and any encrypted image for inspection.\n", stderr)
  exit(1)
}
