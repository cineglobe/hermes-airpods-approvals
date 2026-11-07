import AirPodsCore
import Foundation
import Security

/// Gemini's voice for prompts. The key lives in the login Keychain and is only ever sent to Google.
/// Anything that goes wrong returns nil, and the Mac's own voice reads the prompt instead.
final class GeminiVoice {
  static let model = "gemini-3.8-flash-tts"
  static let voice = "Kore"
  private static let service = "dev.cineglobe.hermes-airpods"
  private static let account = "gemini-api-key"
  private static let maxText = 700
  private static let cacheSize = 16

  private var cache: [(text: String, wav: Data)] = []
  private let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 12
    config.urlCache = nil
    return URLSession(configuration: config)
  }()

  private(set) lazy var hasKey: Bool = Self.readKey() != nil

  // MARK: Keychain

  private static var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
  }

  private static func readKey() -> String? {
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
      let key = String(data: data, encoding: .utf8), !key.isEmpty
    else { return nil }
    return key
  }

  /// Saves a key, or removes it when empty. The key is checked for shape only; a wrong key shows up as
  /// the Mac voice being used.
  @discardableResult
  func setKey(_ raw: String) -> Bool {
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    SecItemDelete(Self.query as CFDictionary)
    cache.removeAll()
    guard !key.isEmpty else {
      hasKey = false
      return true
    }
    guard key.count <= 200, key.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else { return false }
    var item = Self.query
    item[kSecValueData as String] = Data(key.utf8)
    item[kSecAttrLabel as String] = "Hermes AirPods Gemini key"
    hasKey = SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    return hasKey
  }

  // MARK: Speech

  /// Calls back on the main queue with WAV audio, or nil.
  func audio(for text: String, then done: @escaping (Data?) -> Void) {
    let finish = { (wav: Data?) in DispatchQueue.main.async { done(wav) } }
    if let hit = cache.first(where: { $0.text == text }) {
      finish(hit.wav)
      return
    }
    guard hasKey, text.count <= Self.maxText, let key = Self.readKey(),
      let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(Self.model):generateContent")
    else {
      finish(nil)
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
      "contents": [["parts": [["text": text]]]],
      "generationConfig": [
        "responseModalities": ["AUDIO"],
        "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": Self.voice]]],
      ],
    ])
    session.dataTask(with: request) { [weak self] data, response, _ in
      guard (response as? HTTPURLResponse)?.statusCode == 200, let data, let wav = GeminiReply.wav(from: data) else {
        if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 {
          NSLog("Hermes AirPods: Gemini returned \(code), using the Mac voice")
        }
        finish(nil)
        return
      }
      DispatchQueue.main.async {
        guard let self else { return }
        self.cache.append((text, wav))
        if self.cache.count > Self.cacheSize { self.cache.removeFirst() }
        done(wav)
      }
    }.resume()
  }
}
