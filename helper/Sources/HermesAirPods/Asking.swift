import Foundation
import AirPodsCore

/// Runs one question at a time: chime, speech, listening tone, gesture, answer. Only a completed
/// gesture sends an answer. Every other way out sends `ended`, which approves nothing.
final class Asking {
  private struct Active {
    let id: String
    var session: GestureSession?
    let text: String
    let confirmText: String
    /// On a voice call the call asks, so nothing is spoken here: only the listening tone and taps.
    let silent: Bool
    var spoke = false
    var lastSample: TimeInterval?
    let startedAt: TimeInterval
  }

  private let sounds = Sounds()
  private let speech = Speech()
  private let motion = Motion()
  private let gemini = GeminiVoice()
  private let send: ([String: Any]) -> Void
  private var active: Active?
  private var clock: Timer?

  private static let speechWait = 10.0
  private static let motionWait = 3.0
  private static let lostAfter = 1.5

  private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

  init(send: @escaping ([String: Any]) -> Void) {
    self.send = send
    motion.onSample = { [weak self] in self?.sample($0) }
    motion.onLost = { [weak self] in self?.finish(.lost) }
  }

  var status: [String: Any] {
    [
      "output": AudioRoute.bluetoothOutputName ?? NSNull(), "motionDenied": motion.denied,
      "motionAvailable": motion.available, "geminiKey": gemini.hasKey,
    ]
  }

  func handle(_ message: [String: Any]) {
    switch message["type"] as? String {
    case "ask": ask(message)
    case "result":
      // The gesture's own confirm tone has finished by now; this is Hermes having taken it.
      let outcome = message["outcome"] as? String ?? ""
      sounds.start()
      sounds.landed(outcome)
      let words = ["approved": "Approved.", "denied": "Denied."]
      if let text = words[outcome], message["quiet"] as? Bool != true, gemini.hasKey, active == nil {
        gemini.word(text) { [weak self] wav in
          guard let self, self.active == nil, let wav else { return }
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard self.active == nil else { return }
            _ = self.speech.play(wav: wav) {}
          }
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
        if self?.active == nil { self?.sounds.stop() }
      }
    case "setKey":
      let saved = gemini.setKey(message["key"] as? String ?? "")
      send(status.merging(["type": "status", "keySaved": saved]) { a, _ in a })
    case "cancel":
      if message["id"] as? String == active?.id { finish(.cancelled) }
    case "status":
      send(status.merging(["type": "status"]) { a, _ in a })
    default:
      break
    }
  }

  private func ask(_ message: [String: Any]) {
    guard let id = message["id"] as? String, let text = message["text"] as? String else { return }
    guard active == nil else {
      send(["type": "ended", "id": id, "reason": "busy"])
      return
    }
    let silent = message["silent"] as? Bool ?? false
    guard silent || gemini.hasKey else {
      send(["type": "ended", "id": id, "reason": "noKey"])
      return
    }
    guard AudioRoute.bluetoothOutputName != nil, !motion.denied else {
      send(["type": "ended", "id": id, "reason": EndReason.unavailable.rawValue])
      return
    }

    let listenOnly = message["mode"] as? String != "say"
    let seconds = min(30, max(3, message["listenSeconds"] as? Double ?? 8))
    let confirm = message["confirm"] as? Bool ?? false
    active = Active(
      id: id,
      session: listenOnly ? GestureSession(listenSeconds: seconds, requireConfirm: confirm) : nil,
      text: text, confirmText: message["confirmText"] as? String ?? "Nod again to approve.", silent: silent, startedAt: now)

    sounds.start()
    if listenOnly { motion.start() }
    clock?.invalidate()
    clock = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
    if silent {
      active?.spoke = true
      spoken()
      return
    }
    sounds.chime()

    // The chime is already playing while Gemini makes the audio.
    gemini.audio(for: text) { [weak self] wav in
      guard let self, self.active?.id == id, self.active?.spoke == false else { return }
      guard let wav else { self.finish(.noVoice); return }
      self.speak(wav: wav)
    }
    if confirm { gemini.audio(for: active?.confirmText ?? "") { _ in } }
  }

  private func speak(wav: Data) {
    guard var current = active else { return }
    current.spoke = true
    active = current
    guard speech.play(wav: wav, then: { [weak self] in self?.spoken() }) else {
      finish(.noVoice)
      return
    }
  }


  private func spoken() {
    guard var current = active else { return }
    guard var session = current.session else {
      send(["type": "ended", "id": current.id, "reason": "spoken"])
      cleanUp()
      return
    }
    let effects = session.speechEnded(at: now)
    current.session = session
    active = current
    apply(effects)
  }

  private func sample(_ sample: MotionSample) {
    guard var current = active, var session = current.session else { return }
    current.lastSample = sample.time
    let effects = session.feed(sample)
    current.session = session
    active = current
    apply(effects)
  }

  private func tick() {
    guard var current = active else { return }
    let time = now
    if !current.spoke, time - current.startedAt > Self.speechWait {
      finish(.noVoice)
      return
    }
    guard var session = current.session else { return }
    if let last = current.lastSample {
      if time - last > Self.lostAfter { finish(.lost); return }
    } else if motion.undecided {
      // macOS is still showing its Motion prompt. The session's own time limit still applies.
    } else if time - current.startedAt > Self.motionWait {
      finish(.noMotion)
      return
    }
    let effects = session.tick(at: time)
    current.session = session
    active = current
    apply(effects)
  }

  private func finish(_ reason: EndReason) {
    guard var current = active, var session = current.session else {
      if let current = active {
        send(["type": "ended", "id": current.id, "reason": reason.rawValue])
        cleanUp()
      }
      return
    }
    let effects = session.end(reason)
    current.session = session
    active = current
    apply(effects)
  }

  private func apply(_ effects: [SessionEffect]) {
    for effect in effects {
      guard let id = active?.id else { return }
      switch effect {
      case .listening:
        sounds.startListening()
        send(["type": "progress", "id": id, "state": "listening", "beats": 0])
      case let .beat(axis, count, direction):
        sounds.tap(axis: axis, count: count, direction: direction)
        send(["type": "progress", "id": id, "state": "beat", "axis": axis.rawValue, "beats": count])
      case let .missed(axis):
        sounds.missed()
        send(["type": "progress", "id": id, "state": "missed", "axis": axis.rawValue, "beats": 0])
      case .confirmNeeded:
        sounds.stopListening()
        sounds.finished(yes: true)
        send(["type": "progress", "id": id, "state": "confirm", "beats": 0])
        let text = active?.confirmText ?? ""
        let silent = active?.silent ?? false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
          guard self?.active?.id == id else { return }
          if silent {
            self?.spoken()
            return
          }
          self?.gemini.audio(for: text) { wav in
            guard let self, self.active?.id == id else { return }
            guard let wav, self.speech.play(wav: wav, then: { [weak self] in self?.spoken() }) else {
              self.finish(.noVoice)
              return
            }
          }
        }
      case let .answered(answer):
        sounds.stopListening()
        sounds.finished(yes: answer == .yes)
        send(["type": "answer", "id": id, "answer": answer.rawValue])
        cleanUp(after: 0.6)
      case let .ended(reason):
        sounds.stopListening()
        speech.stop()
        if reason == .timeout || reason == .lost || reason == .noVoice { sounds.missed() }
        send(["type": "ended", "id": id, "reason": reason.rawValue])
        cleanUp(after: 0.4)
      }
    }
  }

  private func cleanUp(after delay: Double = 0) {
    active = nil
    clock?.invalidate()
    clock = nil
    motion.stop()
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      if self?.active == nil { self?.sounds.stop() }
    }
  }
}
