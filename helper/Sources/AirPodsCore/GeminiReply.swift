import Foundation

/// Reads the spoken audio out of a Gemini `generateContent` reply.
public enum GeminiReply {
  /// The first audio part, if it is a real WAV file. Anything else is treated as no voice.
  public static func wav(from reply: Data) -> Data? {
    guard let json = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
      let candidates = json["candidates"] as? [[String: Any]]
    else { return nil }
    for candidate in candidates {
      let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
      for part in parts {
        guard let encoded = (part["inlineData"] as? [String: Any])?["data"] as? String,
          let audio = Data(base64Encoded: encoded)
        else { continue }
        return audio.prefix(4) == Data("RIFF".utf8) ? audio : nil
      }
    }
    return nil
  }
}
