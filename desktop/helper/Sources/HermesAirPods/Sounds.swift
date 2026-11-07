import AVFoundation
import AirPodsCore

/// Every sound is generated here, so there are no audio files to ship. Taps go through Apple's 3D
/// audio so a shake lands in the ear you turned towards and a nod lands above or below you.
final class Sounds {
  private let engine = AVAudioEngine()
  private let space = AVAudioEnvironmentNode()
  private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
  private var taps: [AVAudioPlayerNode] = []
  private var nextTap = 0
  private let hum = AVAudioPlayerNode()

  init() {
    engine.attach(space)
    engine.connect(space, to: engine.mainMixerNode, format: nil)
    space.distanceAttenuationParameters.rolloffFactor = 0
    for _ in 0..<4 { taps.append(addPlayer()) }
    engine.attach(hum)
    engine.connect(hum, to: engine.mainMixerNode, format: format)
  }

  private func addPlayer() -> AVAudioPlayerNode {
    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: space, format: format)
    player.renderingAlgorithm = .HRTFHQ
    player.sourceMode = .pointSource
    return player
  }

  func start() {
    guard !engine.isRunning else { return }
    engine.prepare()
    do { try engine.start() } catch { NSLog("Hermes AirPods: audio engine did not start: \(error.localizedDescription)") }
  }

  func stop() {
    hum.stop()
    taps.forEach { $0.stop() }
    engine.stop()
  }

  private func buffer(seconds: Double, _ value: (Double) -> Double) -> AVAudioPCMBuffer {
    let frames = AVAudioFrameCount(seconds * format.sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let data = buffer.floatChannelData![0]
    for i in 0..<Int(frames) { data[i] = Float(value(Double(i) / format.sampleRate)) }
    return buffer
  }

  private func tone(frequency: Double, seconds: Double, level: Double) -> AVAudioPCMBuffer {
    buffer(seconds: seconds) { t in
      let attack = min(1, t / 0.002)
      let decay = exp(-t * 7 / seconds)
      return level * attack * decay * (sin(2 * .pi * frequency * t) + 0.3 * sin(4 * .pi * frequency * t))
    }
  }

  private func play(_ buffer: AVAudioPCMBuffer, at position: AVAudio3DPoint) {
    guard engine.isRunning else { return }
    let player = taps[nextTap]
    nextTap = (nextTap + 1) % taps.count
    player.position = position
    player.scheduleBuffer(buffer, at: nil, options: .interrupts)
    player.play()
  }

  private let ahead = AVAudio3DPoint(x: 0, y: 0, z: -1)

  /// Beats grow louder as the gesture builds. Shakes sit low in the ear; nods sit high, brighter
  /// above and darker below.
  func tap(axis: Axis, count: Int, direction: Int) {
    let level = [0.3, 0.55, 0.85][max(0, min(count - 1, 2))]
    switch axis {
    case .shake:
      // Turning left is a positive yaw rate.
      let x: Float = direction > 0 ? -1 : 1
      play(tone(frequency: 420, seconds: 0.09, level: level), at: AVAudio3DPoint(x: x, y: 0, z: 0))
    case .nod:
      let up = direction > 0
      let y: Float = up ? 1 : -1
      play(tone(frequency: up ? 1180 : 760, seconds: 0.09, level: level), at: AVAudio3DPoint(x: 0, y: y, z: 0))
    }
  }

  func chime() {
    play(tone(frequency: 660, seconds: 0.16, level: 0.22), at: ahead)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) { [self] in
      play(tone(frequency: 880, seconds: 0.22, level: 0.22), at: ahead)
    }
  }

  func missed() {
    play(tone(frequency: 240, seconds: 0.12, level: 0.12), at: ahead)
  }

  func finished(yes: Bool) {
    let notes: [Double] = yes ? [880, 1320] : [440, 294]
    play(tone(frequency: notes[0], seconds: 0.14, level: 0.3), at: ahead)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
      play(tone(frequency: notes[1], seconds: 0.26, level: 0.3), at: ahead)
    }
  }

  /// Plays once Hermes has taken the answer: the same boop as the beats, run as a quick phrase.
  /// Approved climbs from below to above you; denied falls and moves from one ear to the other.
  func landed(_ outcome: String) {
    let steps: [(Double, AVAudio3DPoint)]
    switch outcome {
    case "approved":
      steps = [(988, .init(x: 0, y: -1, z: -0.3)), (1319, .init(x: 0, y: 0, z: -1)), (1760, .init(x: 0, y: 1, z: -0.3))]
    case "denied":
      steps = [(523, .init(x: -1, y: 0, z: -0.3)), (440, .init(x: 0, y: 0, z: -1)), (330, .init(x: 1, y: 0, z: -0.3))]
    default:
      missed()
      return
    }
    for (index, step) in steps.enumerated() {
      DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.075) { [self] in
        play(tone(frequency: step.0, seconds: index == 2 ? 0.22 : 0.08, level: 0.5), at: step.1)
      }
    }
  }

  func startListening() {
    guard engine.isRunning else { return }
    // Whole cycles of both notes, so the loop has no click.
    let loop = buffer(seconds: 1) { t in
      0.022 * (sin(2 * .pi * 110 * t) + 0.5 * sin(2 * .pi * 165 * t)) * (0.8 + 0.2 * sin(2 * .pi * t))
    }
    hum.scheduleBuffer(loop, at: nil, options: [.loops, .interrupts])
    hum.play()
  }

  func stopListening() {
    hum.stop()
  }
}
