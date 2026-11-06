import CryptoKit
import Foundation

/// Both sides prove they hold the pairing token without sending it. A process that merely grabs
/// the local port can't pass as the helper, so it can't forge a nod.
public enum Handshake {
  public static func proof(token: String, role: String, nonce: String) -> String {
    let key = SymmetricKey(data: Data(token.utf8))
    let code = HMAC<SHA256>.authenticationCode(for: Data("\(role):\(nonce)".utf8), using: key)
    return code.map { String(format: "%02x", $0) }.joined()
  }

  public static func matches(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }

  public static func nonce() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  /// Browsers send their page's origin, so a website can never reach the helper.
  public static func allows(origin: String?) -> Bool {
    guard let origin else { return false }
    return origin == "file://" || origin == "null"
  }
}
