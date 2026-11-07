import CoreAudio
import CoreMotion
import Foundation
import AirPodsCore

/// Head motion runs only while a question is open, so the sensors are off the rest of the time.
final class Motion: NSObject, CMHeadphoneMotionManagerDelegate {
  private let manager = CMHeadphoneMotionManager()
  private let queue = OperationQueue()
  var onSample: ((MotionSample) -> Void)?
  var onLost: (() -> Void)?

  override init() {
    super.init()
    manager.delegate = self
    queue.maxConcurrentOperationCount = 1
  }

  /// The first question shows macOS's Motion prompt, so readings can't be expected until it's answered.
  var undecided: Bool { CMHeadphoneMotionManager.authorizationStatus() == .notDetermined }
  var available: Bool { manager.isDeviceMotionAvailable }
  var denied: Bool {
    let status = CMHeadphoneMotionManager.authorizationStatus()
    return status == .denied || status == .restricted
  }

  /// For the settings page: "undecided", "allowed" or "denied".
  var access: String {
    switch CMHeadphoneMotionManager.authorizationStatus() {
    case .authorized: return "allowed"
    case .denied, .restricted: return "denied"
    default: return "undecided"
    }
  }

  /// Set up asks for Motion access ahead of the first question. Starting updates is what makes macOS
  /// ask; they stop again once the person has answered, or after two minutes.
  private var probing = false
  func requestAccess(then done: @escaping () -> Void) {
    guard undecided, !manager.isDeviceMotionActive else { return done() }
    probing = true
    manager.startDeviceMotionUpdates(to: queue) { _, _ in }
    let deadline = Date().addingTimeInterval(120)
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
      guard let self else { return timer.invalidate() }
      guard !self.undecided || Date() > deadline || !self.probing else { return }
      timer.invalidate()
      if self.probing {
        self.probing = false
        self.manager.stopDeviceMotionUpdates()
      }
      done()
    }
  }

  func start() {
    if probing {
      probing = false
      manager.stopDeviceMotionUpdates()
    }
    guard !manager.isDeviceMotionActive else { return }
    manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
      guard let self, let motion else { return }
      let degrees = 180 / Double.pi
      let sample = MotionSample(
        time: motion.timestamp, pitchRate: motion.rotationRate.x * degrees,
        rollRate: motion.rotationRate.y * degrees, yawRate: motion.rotationRate.z * degrees)
      DispatchQueue.main.async { self.onSample?(sample) }
    }
  }

  func stop() { manager.stopDeviceMotionUpdates() }

  func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
    DispatchQueue.main.async { self.onLost?() }
  }
}

/// The current output device. Prompts must never leak out of the Mac's speakers, so anything that
/// isn't Bluetooth headphones counts as no route.
enum AudioRoute {
  private static func property<T>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
  }

  static var bluetoothOutputName: String? {
    var device = AudioObjectID(0)
    guard property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &device) else { return nil }
    var transport = UInt32(0)
    guard property(device, kAudioDevicePropertyTransportType, &transport), transport == kAudioDeviceTransportTypeBluetooth else { return nil }
    var name: Unmanaged<CFString>?
    guard withUnsafeMutablePointer(to: &name, { pointer in
      var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
      var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
      return AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer) == noErr
    }), let name else { return "Headphones" }
    return name.takeRetainedValue() as String
  }
}
