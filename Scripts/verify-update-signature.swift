import CryptoKit
import Foundation

guard CommandLine.arguments.count == 4 else {
  fputs("Usage: verify-update-signature.swift public-key signature file | --feed public-key appcast.xml\n", stderr)
  exit(1)
}
let feedMode = CommandLine.arguments[1] == "--feed"
guard let publicData = Data(base64Encoded: CommandLine.arguments[feedMode ? 2 : 1]) else { exit(1) }
let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
var data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
var signature: Data
if feedMode {
  guard let range = data.range(of: Data("<!-- sparkle-signatures:".utf8), options: .backwards),
        let trailer = String(data: data[range.lowerBound...], encoding: .utf8) else { exit(1) }
  let pattern = #"^<!-- sparkle-signatures:\s+edSignature: ([A-Za-z0-9+/=]+)\s+length: (\d+)\s+-->\s*$"#
  let regex = try NSRegularExpression(pattern: pattern)
  guard let match = regex.firstMatch(in: trailer, range: NSRange(trailer.startIndex..., in: trailer)),
        let sigRange = Range(match.range(at: 1), in: trailer),
        let sizeRange = Range(match.range(at: 2), in: trailer),
        let size = Int(trailer[sizeRange]), size == range.lowerBound,
        let parsed = Data(base64Encoded: String(trailer[sigRange])) else { exit(1) }
  signature = parsed
  data = Data(data.prefix(size))
} else {
  guard let parsed = Data(base64Encoded: CommandLine.arguments[2]) else { exit(1) }
  signature = parsed
}
guard key.isValidSignature(signature, for: data) else {
  fputs("EdDSA signature does not match the embedded public key\n", stderr)
  exit(1)
}
print("EdDSA signature verified against the release public key")
