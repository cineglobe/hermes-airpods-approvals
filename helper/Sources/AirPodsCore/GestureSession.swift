import Foundation

public enum Answer: String, Sendable {
  case yes
  case no
}

public enum EndReason: String, Sendable {
  case timeout
  case lost
  case cancelled
  case unavailable
  /// Motion was allowed but no readings came, usually because the AirPods aren't in.
  case noMotion
  /// Gemini's voice couldn't be had, so nothing was asked.
  case noVoice
}

public enum SessionEffect: Equatable, Sendable {
  case listening
  case beat(Axis, count: Int, direction: Int)
  case missed(Axis)
  case confirmNeeded
  case answered(Answer)
  case ended(EndReason)
}

/// One question to the user. Pure state: the caller supplies samples and the time, so every safety
/// rule below can be tested without hardware.
///
/// - Nothing counts until the question has finished and the head has settled, so a nod that began
///   early can't run on into an answer.
/// - Running out of time, or losing the AirPods, gives no answer at all. Only a completed gesture
///   produces one.
/// - With `requireConfirm`, a yes needs a second completed nod. A shake always answers at once.
public struct GestureSession {
  public enum Phase: Equatable, Sendable {
    case speaking
    case settling
    case listening
    case finished
  }

  public static let settleTime = 0.25
  public static let settleRate = 25.0

  public private(set) var phase = Phase.speaking
  public let requireConfirm: Bool
  public let listenSeconds: TimeInterval

  private var detector: BeatDetector
  private var deadline = TimeInterval.infinity
  private var stillSince: TimeInterval?
  private var confirming = false

  public init(listenSeconds: TimeInterval, requireConfirm: Bool, config: BeatConfig = BeatConfig()) {
    self.listenSeconds = listenSeconds
    self.requireConfirm = requireConfirm
    detector = BeatDetector(config: config)
  }

  /// Call when the spoken question, or the "nod again" prompt, has finished playing.
  public mutating func speechEnded(at time: TimeInterval) -> [SessionEffect] {
    guard phase == .speaking else { return [] }
    phase = .settling
    stillSince = nil
    deadline = time + listenSeconds
    detector.clear()
    return [.listening]
  }

  public mutating func feed(_ sample: MotionSample) -> [SessionEffect] {
    if let effects = expire(at: sample.time) { return effects }

    switch phase {
    case .speaking, .finished:
      return []
    case .settling:
      let moving = max(abs(sample.pitchRate), abs(sample.rollRate), abs(sample.yawRate)) >= Self.settleRate
      if moving {
        stillSince = nil
      } else if let since = stillSince {
        if sample.time - since >= Self.settleTime { phase = .listening }
      } else {
        stillSince = sample.time
      }
      _ = detector.feed(sample)
      detector.clear()
      return []
    case .listening:
      var effects: [SessionEffect] = []
      for event in detector.feed(sample) {
        switch event {
        case let .beat(axis, count, direction):
          effects.append(.beat(axis, count: count, direction: direction))
        case let .reset(axis):
          effects.append(.missed(axis))
        case let .complete(axis):
          effects += complete(axis)
        }
      }
      return effects
    }
  }

  /// Call regularly, so time still runs out if the readings stop.
  public mutating func tick(at time: TimeInterval) -> [SessionEffect] {
    expire(at: time) ?? []
  }

  public mutating func end(_ reason: EndReason) -> [SessionEffect] {
    guard phase != .finished else { return [] }
    phase = .finished
    return [.ended(reason)]
  }

  private mutating func expire(at time: TimeInterval) -> [SessionEffect]? {
    guard phase == .settling || phase == .listening, time >= deadline else { return nil }
    phase = .finished
    return [.ended(.timeout)]
  }

  private mutating func complete(_ axis: Axis) -> [SessionEffect] {
    switch axis {
    case .shake:
      phase = .finished
      return [.answered(.no)]
    case .nod where requireConfirm && !confirming:
      confirming = true
      phase = .speaking
      deadline = .infinity
      return [.confirmNeeded]
    case .nod:
      phase = .finished
      return [.answered(.yes)]
    }
  }
}
