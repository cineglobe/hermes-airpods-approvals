import AVFoundation

/// Plays Gemini's spoken prompt. There is deliberately no fallback voice: if it can't play, nothing is
/// asked and the request stays on screen.
final class Speech: NSObject, AVAudioPlayerDelegate {
  private var player: AVAudioPlayer?
  private var finished: (() -> Void)?

  func play(wav: Data, then done: @escaping () -> Void) -> Bool {
    stop()
    guard let player = try? AVAudioPlayer(data: wav) else { return false }
    player.delegate = self
    guard player.play() else { return false }
    finished = done
    self.player = player
    return true
  }

  func stop() {
    finished = nil
    player?.stop()
    player = nil
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    let done = finished
    finished = nil
    self.player = nil
    done?()
  }
}
