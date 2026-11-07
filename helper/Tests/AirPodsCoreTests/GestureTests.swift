import XCTest
@testable import AirPodsCore

/// Rows from a real guided recording: one person wearing AirPods, 50 samples a second.
struct Row {
  let sample: MotionSample
  let label: String
  let trial: Int
}

func recording() throws -> [Row] {
  let url = try XCTUnwrap(Bundle.module.url(forResource: "recording-1", withExtension: "csv", subdirectory: "Fixtures"))
  return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").dropFirst().map { line in
    let f = line.split(separator: ",").map(String.init)
    return Row(
      sample: MotionSample(time: Double(f[0])!, pitchRate: Double(f[3])!, rollRate: Double(f[4])!, yawRate: Double(f[5])!),
      label: f[1], trial: Int(f[2])!)
  }
}

func completions(_ rows: [Row]) -> [(Axis, Row)] {
  var detector = BeatDetector()
  var found: [(Axis, Row)] = []
  for row in rows {
    for case let .complete(axis) in detector.feed(row.sample) { found.append((axis, row)) }
  }
  return found
}

/// Back-and-forth movement at a steady rhythm.
func swings(axis: Axis, beats: Int, gap: Double, start: Double = 0, peak: Double = 90) -> [MotionSample] {
  var samples: [MotionSample] = []
  let total = Double(beats) * gap
  var t = 0.0
  while t <= total {
    let rate = peak * sin(.pi * t / gap)
    samples.append(MotionSample(time: start + t, pitchRate: axis == .nod ? rate : 0, rollRate: 0, yawRate: axis == .shake ? rate : 0))
    t += 0.02
  }
  return samples
}

func still(from start: Double, seconds: Double) -> [MotionSample] {
  stride(from: start, to: start + seconds, by: 0.02).map { MotionSample(time: $0, pitchRate: 1, rollRate: 1, yawRate: 1) }
}

final class RecordingTests: XCTestCase {
  func testEveryFastGestureIsCaught() throws {
    let rows = try recording()
    for k in 1...4 {
      let nods = completions(rows.filter { $0.label == "nod_fast" && $0.trial == k })
      XCTAssertTrue(nods.contains { $0.0 == .nod }, "fast nod \(k) missed")
      XCTAssertFalse(nods.contains { $0.0 == .shake }, "fast nod \(k) read as a shake")
      let shakes = completions(rows.filter { $0.label == "shake_fast" && $0.trial == k })
      XCTAssertTrue(shakes.contains { $0.0 == .shake }, "fast shake \(k) missed")
      XCTAssertFalse(shakes.contains { $0.0 == .nod }, "fast shake \(k) read as a nod")
    }
  }

  func testSlowGesturesAnswerNothing() throws {
    let rows = try recording()
    for label in ["nod_slow", "shake_slow"] {
      for k in 1...3 {
        XCTAssertTrue(completions(rows.filter { $0.label == label && $0.trial == k }).isEmpty, "\(label) \(k) fired")
      }
    }
  }

  func testEverydayMovementNeverFires() throws {
    let rows = try recording()
    for label in ["still", "glance", "look_down", "look_around", "talk", "walk"] {
      XCTAssertTrue(completions(rows.filter { $0.label == label }).isEmpty, "\(label) fired")
    }
  }

  func testWholeStreamOnlyFiresAroundGestures() throws {
    let rows = try recording()
    for (axis, row) in completions(rows) {
      let word = axis == .nod ? "nod" : "shake"
      if row.label == "prompt" {
        // Between steps the user sometimes started the next nod early. A fire there must sit next
        // to a step of the same kind.
        let index = rows.firstIndex { $0.sample.time == row.sample.time }!
        let near = rows[max(0, index - 150)..<min(rows.count, index + 150)].map(\.label)
        XCTAssertTrue(near.contains { $0.hasPrefix(word) }, "stray \(word) at \(row.sample.time)")
      } else {
        XCTAssertTrue(row.label.hasPrefix(word), "\(word) fired during \(row.label)")
      }
    }
  }
}

final class DetectorTests: XCTestCase {
  func testTwoBeatsAreNotAnAnswer() {
    var detector = BeatDetector()
    let events = swings(axis: .nod, beats: 2, gap: 0.3).flatMap { detector.feed($0) }
    XCTAssertFalse(events.contains(.complete(.nod)))
  }

  func testLateBeatStartsTheCountAgain() {
    var detector = BeatDetector()
    let events = swings(axis: .shake, beats: 4, gap: 0.6).flatMap { detector.feed($0) }
    XCTAssertFalse(events.contains(.complete(.shake)))
    XCTAssertTrue(events.contains(.reset(.shake)))
  }

  func testDiagonalMovementIsRejected() {
    var detector = BeatDetector()
    let samples = swings(axis: .nod, beats: 3, gap: 0.3).map {
      MotionSample(time: $0.time, pitchRate: $0.pitchRate, rollRate: 0, yawRate: $0.pitchRate)
    }
    let events = samples.flatMap { detector.feed($0) }
    XCTAssertFalse(events.contains(.complete(.nod)))
    XCTAssertFalse(events.contains(.complete(.shake)))
  }

  func testDroppedReadingsBreakTheRhythm() {
    var detector = BeatDetector()
    let first = swings(axis: .nod, beats: 2, gap: 0.3)
    let second = swings(axis: .nod, beats: 1, gap: 0.3, start: first.last!.time + 0.3)
    let events = (first + second).flatMap { detector.feed($0) }
    XCTAssertFalse(events.contains(.complete(.nod)))
  }

  func testLockoutStopsOneGestureAnsweringTwice() {
    var detector = BeatDetector()
    let events = swings(axis: .shake, beats: 6, gap: 0.25).flatMap { detector.feed($0) }
    XCTAssertEqual(events.filter { $0 == .complete(.shake) }.count, 1)
  }
}

final class SessionTests: XCTestCase {
  func run(_ session: inout GestureSession, _ samples: [MotionSample]) -> [SessionEffect] {
    samples.flatMap { session.feed($0) }
  }

  func listening(confirm: Bool = false, seconds: Double = 8) -> GestureSession {
    var session = GestureSession(listenSeconds: seconds, requireConfirm: confirm)
    _ = session.speechEnded(at: 0)
    _ = run(&session, still(from: 0, seconds: 0.4))
    XCTAssertEqual(session.phase, .listening)
    return session
  }

  func testNodDuringSpeechCountsForNothing() {
    var session = GestureSession(listenSeconds: 8, requireConfirm: false)
    XCTAssertTrue(run(&session, swings(axis: .nod, beats: 4, gap: 0.3)).isEmpty)
    XCTAssertEqual(session.phase, .speaking)
  }

  func testNodCarriedOverFromSpeechCountsForNothing() {
    var session = GestureSession(listenSeconds: 8, requireConfirm: false)
    _ = session.speechEnded(at: 0)
    let effects = run(&session, swings(axis: .nod, beats: 6, gap: 0.3))
    XCTAssertFalse(effects.contains(.answered(.yes)))
    XCTAssertEqual(session.phase, .settling)
  }

  func testOneRoundNodAnswersYes() {
    var session = listening()
    let effects = run(&session, swings(axis: .nod, beats: 3, gap: 0.3, start: 0.5))
    XCTAssertEqual(effects.last, .answered(.yes))
    XCTAssertEqual(session.phase, .finished)
  }

  func testShakeAnswersNoAtOnce() {
    var session = listening(confirm: true)
    let effects = run(&session, swings(axis: .shake, beats: 3, gap: 0.3, start: 0.5))
    XCTAssertEqual(effects.last, .answered(.no))
  }

  func testTapsPlayForEachBeat() {
    var session = listening()
    let counts = run(&session, swings(axis: .nod, beats: 3, gap: 0.3, start: 0.5)).compactMap { effect -> Int? in
      if case let .beat(_, count, _) = effect { return count }
      return nil
    }
    XCTAssertEqual(counts, [1, 2, 3])
  }

  func testConfirmRoundNeedsASecondNod() {
    var session = listening(confirm: true)
    let first = run(&session, swings(axis: .nod, beats: 3, gap: 0.3, start: 0.5))
    XCTAssertEqual(first.last, .confirmNeeded)
    XCTAssertFalse(first.contains(.answered(.yes)))
    XCTAssertEqual(session.phase, .speaking)

    XCTAssertEqual(session.speechEnded(at: 3), [.listening])
    _ = run(&session, still(from: 3, seconds: 0.4))
    let second = run(&session, swings(axis: .nod, beats: 3, gap: 0.3, start: 3.5))
    XCTAssertEqual(second.last, .answered(.yes))
  }

  func testShakeDuringConfirmDenies() {
    var session = listening(confirm: true)
    _ = run(&session, swings(axis: .nod, beats: 3, gap: 0.3, start: 0.5))
    _ = session.speechEnded(at: 3)
    _ = run(&session, still(from: 3, seconds: 0.4))
    XCTAssertEqual(run(&session, swings(axis: .shake, beats: 3, gap: 0.3, start: 3.5)).last, .answered(.no))
  }

  func testConfirmTimeoutGivesNoAnswer() {
    var session = listening(confirm: true, seconds: 2)
    _ = run(&session, swings(axis: .nod, beats: 3, gap: 0.3, start: 0.5))
    _ = session.speechEnded(at: 3)
    XCTAssertEqual(session.tick(at: 5.1), [.ended(.timeout)])
  }

  func testTimeoutGivesNoAnswer() {
    var session = listening(seconds: 2)
    XCTAssertEqual(session.tick(at: 2.1), [.ended(.timeout)])
    XCTAssertTrue(run(&session, swings(axis: .nod, beats: 3, gap: 0.3, start: 3)).isEmpty)
  }

  func testTimeoutRunsEvenWithoutSamples() {
    var session = GestureSession(listenSeconds: 1, requireConfirm: false)
    _ = session.speechEnded(at: 0)
    XCTAssertEqual(session.tick(at: 1.5), [.ended(.timeout)])
  }

  func testLosingTheAirPodsGivesNoAnswer() {
    var session = listening()
    _ = run(&session, swings(axis: .nod, beats: 2, gap: 0.3, start: 0.5))
    XCTAssertEqual(session.end(.lost), [.ended(.lost)])
    XCTAssertTrue(run(&session, swings(axis: .nod, beats: 3, gap: 0.3, start: 2)).isEmpty)
  }
}

final class HandshakeTests: XCTestCase {
  func testProofMatchesTheWebCryptoValue() {
    // Computed independently with Python's hmac module; the JS test checks the same value.
    XCTAssertEqual(Handshake.proof(token: "abc123", role: "plugin", nonce: "n1"), "5def1f5f4aaa8dfea598336bad1f07724f040aa27b7316d1ef040875e05f603c")
  }

  func testRolesCannotBeSwapped() {
    XCTAssertNotEqual(Handshake.proof(token: "t", role: "plugin", nonce: "n"), Handshake.proof(token: "t", role: "helper", nonce: "n"))
  }

  func testWrongTokenFails() {
    XCTAssertFalse(Handshake.matches(Handshake.proof(token: "a", role: "plugin", nonce: "n"), Handshake.proof(token: "b", role: "plugin", nonce: "n")))
  }

  func testWebsitesAreRefused() {
    XCTAssertTrue(Handshake.allows(origin: "file://"))
    XCTAssertFalse(Handshake.allows(origin: "https://example.com"))
    XCTAssertFalse(Handshake.allows(origin: "http://localhost:3000"))
    XCTAssertFalse(Handshake.allows(origin: nil))
    XCTAssertFalse(Handshake.allows(origin: "null"))
  }
}

final class GeminiReplyTests: XCTestCase {
  private func reply(_ audio: Data) -> Data {
    let body: [String: Any] = ["candidates": [["content": ["parts": [["text": "ok"], ["inlineData": ["mimeType": "audio/wav", "data": audio.base64EncodedString()]]]]]]]
    return try! JSONSerialization.data(withJSONObject: body)
  }

  func testWavAudioIsUsed() {
    let wav = Data("RIFF....WAVEfmt ".utf8)
    XCTAssertEqual(GeminiReply.wav(from: reply(wav)), wav)
  }

  func testRawAudioIsRefused() {
    XCTAssertNil(GeminiReply.wav(from: reply(Data([0, 1, 2, 3, 4]))))
  }

  func testErrorsAndJunkGiveNoVoice() {
    XCTAssertNil(GeminiReply.wav(from: Data(#"{"error":{"code":429}}"#.utf8)))
    XCTAssertNil(GeminiReply.wav(from: Data("not json".utf8)))
  }
}
