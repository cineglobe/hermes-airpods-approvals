import AVFoundation

/// Plays Gemini's audio when the plugin sends it, otherwise uses the Mac's own voice.
final class Speech: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
  private var player: AVAudioPlayer?
  private let voice = AVSpeechSynthesizer()
  private var finished: (() -> Void)?

  override init() {
    super.init()
    voice.delegate = self
  }

  func say(_ text: String, then done: @escaping () -> Void) {
    stop()
    finished = done
    let utterance = AVSpeechUtterance(string: text)
    utterance.rate = 0.52
    voice.speak(utterance)
  }

  func play(wav: Data, fallback text: String, then done: @escaping () -> Void) {
    stop()
    finished = done
    guard let player = try? AVAudioPlayer(data: wav), player.play() else {
      say(text, then: done)
      return
    }
    player.delegate = self
    self.player = player
  }

  func stop() {
    finished = nil
    player?.stop()
    player = nil
    voice.stopSpeaking(at: .immediate)
  }

  private func complete() {
    let done = finished
    finished = nil
    player = nil
    done?()
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { complete() }
  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { complete() }
}
