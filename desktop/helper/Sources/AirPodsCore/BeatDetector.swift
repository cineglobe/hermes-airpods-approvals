import Foundation

/// One reading from the AirPods. Rates are degrees per second.
public struct MotionSample: Sendable {
  public let time: TimeInterval
  public let pitchRate: Double
  public let rollRate: Double
  public let yawRate: Double

  public init(time: TimeInterval, pitchRate: Double, rollRate: Double, yawRate: Double) {
    self.time = time
    self.pitchRate = pitchRate
    self.rollRate = rollRate
    self.yawRate = yawRate
  }
}

public enum Axis: String, Sendable {
  case nod
  case shake
}

public enum BeatEvent: Equatable, Sendable {
  /// A swing landed. `count` starts at 1; `direction` is the sign of the rate.
  case beat(Axis, count: Int, direction: Int)
  /// The next beat came too late, or the movement wasn't clean. The count starts over.
  case reset(Axis)
  case complete(Axis)
}

/// Thresholds measured from real recordings; see docs/GESTURES.md.
public struct BeatConfig: Sendable {
  public var quietRate = 12.0
  public var minimumPeakRate = 30.0
  public var minimumSwing = 4.0
  public var maximumBeatGap = 0.41
  public var beatsNeeded = 3
  public var dominance = 3.0
  public var swingEndPause = 0.12
  public var lockout = 0.8
  public var maximumSampleGap = 0.25

  public init() {}
}

/// Follows one axis, turning swings into beats. A swing becomes a beat the moment it is fast and
/// large enough, so the tap sound lands while the head is still moving.
struct AxisTracker {
  let axis: Axis
  let config: BeatConfig

  private var swingSign = 0
  private var swingAngle = 0.0
  private var swingPeak = 0.0
  private var swingCounted = false
  private var lastActive = 0.0
  private var lastBeatSign = 0
  private(set) var lastBeatTime = 0.0
  private(set) var firstBeatTime = 0.0
  private(set) var count = 0

  init(axis: Axis, config: BeatConfig) {
    self.axis = axis
    self.config = config
  }

  mutating func clear() {
    swingSign = 0
    swingAngle = 0
    swingPeak = 0
    swingCounted = false
    lastBeatSign = 0
    count = 0
  }

  mutating func feed(time: TimeInterval, rate: Double, step: Double) -> BeatEvent? {
    var event: BeatEvent?
    if count > 0, time - lastBeatTime > config.maximumBeatGap {
      count = 0
      event = .reset(axis)
    }

    let sign = abs(rate) < config.quietRate ? 0 : (rate > 0 ? 1 : -1)
    if sign == 0 {
      if swingSign != 0, time - lastActive > config.swingEndPause {
        swingSign = 0
      }
      return event
    }

    if sign != swingSign {
      swingSign = sign
      swingAngle = 0
      swingPeak = 0
      swingCounted = false
    }
    swingAngle += abs(rate) * step
    swingPeak = max(swingPeak, abs(rate))
    lastActive = time

    guard !swingCounted, swingPeak >= config.minimumPeakRate, swingAngle >= config.minimumSwing else {
      return event
    }
    swingCounted = true
    if count > 0, sign != lastBeatSign {
      count += 1
    } else {
      count = 1
      firstBeatTime = time
    }
    lastBeatSign = sign
    lastBeatTime = time
    return .beat(axis, count: count, direction: sign)
  }
}

/// Turns a stream of samples into beats and completed gestures.
///
/// Speed alone can't tell a gesture from everyday movement: a glance is as fast as a shake. What
/// separates them is rhythm. A glance goes out and back once, then stops. A gesture needs three
/// alternating beats, each landing soon after the last, with the head moving mainly on one axis.
public struct BeatDetector {
  public let config: BeatConfig

  private var nod: AxisTracker
  private var shake: AxisTracker
  private var previousTime: TimeInterval?
  private var lockedUntil = 0.0
  private var history: [(time: TimeInterval, pitch: Double, roll: Double, yaw: Double)] = []

  public init(config: BeatConfig = BeatConfig()) {
    self.config = config
    nod = AxisTracker(axis: .nod, config: config)
    shake = AxisTracker(axis: .shake, config: config)
  }

  public mutating func clear() {
    nod.clear()
    shake.clear()
    previousTime = nil
    lockedUntil = 0
    history.removeAll(keepingCapacity: true)
  }

  public mutating func feed(_ sample: MotionSample) -> [BeatEvent] {
    defer { previousTime = sample.time }
    guard let previous = previousTime else { return [] }

    let step = sample.time - previous
    guard step > 0 else { return [] }
    if step > config.maximumSampleGap {
      // Readings dropped out, so the rhythm so far can't be trusted.
      let events = resets()
      nod.clear()
      shake.clear()
      history.removeAll(keepingCapacity: true)
      return events
    }
    if sample.time < lockedUntil { return [] }

    history.append((sample.time, abs(sample.pitchRate) * step, abs(sample.rollRate) * step, abs(sample.yawRate) * step))
    let horizon = sample.time - 3
    if let first = history.first, first.time < horizon {
      history.removeAll { $0.time < horizon }
    }

    var events: [BeatEvent] = []
    if let event = nod.feed(time: sample.time, rate: sample.pitchRate, step: step) { events.append(event) }
    if let event = shake.feed(time: sample.time, rate: sample.yawRate, step: step) { events.append(event) }

    for axis in [Axis.nod, .shake] {
      let tracker = axis == .nod ? nod : shake
      guard tracker.count >= config.beatsNeeded else { continue }
      if isDominant(axis, from: tracker.firstBeatTime) {
        events.append(.complete(axis))
        lockedUntil = sample.time + config.lockout
      } else {
        events.append(.reset(axis))
      }
      nod.clear()
      shake.clear()
      break
    }
    return events
  }

  private func resets() -> [BeatEvent] {
    var events: [BeatEvent] = []
    if nod.count > 0 { events.append(.reset(.nod)) }
    if shake.count > 0 { events.append(.reset(.shake)) }
    return events
  }

  private func isDominant(_ axis: Axis, from start: TimeInterval) -> Bool {
    var pitch = 0.0, roll = 0.0, yaw = 0.0
    for entry in history where entry.time >= start {
      pitch += entry.pitch
      roll += entry.roll
      yaw += entry.yaw
    }
    let main = axis == .nod ? pitch : yaw
    let other = max(roll, axis == .nod ? yaw : pitch)
    return other == 0 || main / other >= config.dominance
  }
}
