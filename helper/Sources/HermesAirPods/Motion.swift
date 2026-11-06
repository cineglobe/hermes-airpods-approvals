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

  var available: Bool { manager.isDeviceMotionAvailable }
  var denied: Bool {
    let status = CMHeadphoneMotionManager.authorizationStatus()
    return status == .denied || status == .restricted
  }

  func start() {
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
