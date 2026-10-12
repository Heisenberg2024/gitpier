import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2 else { exit(1) }
let directory = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
guard directory.path.contains("/.cache/update-acceptance/") else {
  fputs("Test keys must stay in the ignored update acceptance directory\n", stderr); exit(1)
}
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let file = directory.appendingPathComponent("test-private-key.secret")
guard !FileManager.default.fileExists(atPath: file.path) else { exit(1) }
let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedData().write(to: file, options: .atomic)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
try key.publicKey.rawRepresentation.base64EncodedData().write(to: directory.appendingPathComponent("test-public-key.txt"))
print("Isolated test key files created; production Keychain untouched")
