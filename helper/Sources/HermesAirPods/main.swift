import AppKit
import AirPodsCore

/// The pairing token lives in a file only this user can read.
final class Pairing {
  private let url: URL
  private(set) var token: String?
  private var openUntil = Date.distantPast

  init() {
    let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Hermes AirPods")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    url = folder.appendingPathComponent("pairing")
    token = (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var isOpen: Bool { token == nil || Date() < openUntil }

  /// Pairing is open for a minute after the app is opened, which is what Connect in Hermes does.
  /// Websites can't open the app or reach the socket, so this is only reachable from the Mac itself.
  func open() { openUntil = Date().addingTimeInterval(60) }

  func accept(_ candidate: String) -> Bool {
    guard candidate.count >= 32, candidate.allSatisfy(\.isHexDigit), isOpen else { return false }
    FileManager.default.createFile(atPath: url.path, contents: Data(candidate.utf8), attributes: [.posixPermissions: 0o600])
    token = candidate
    openUntil = .distantPast
    return true
  }
}

/// No window, no Dock icon, no menu bar item. It runs only while Hermes Desktop is open and quits
/// on its own once Desktop has gone.
final class AppDelegate: NSObject, NSApplicationDelegate {
  private static let desktopBundle = "com.nousresearch.hermes"
  /// Long enough to ride out Desktop reloading its plugins, short enough to tidy up promptly.
  private static let graceSeconds = 20.0

  private let pairing = Pairing()
  private lazy var bridge = Bridge(token: { [pairing] in pairing.token })
  private lazy var asking = Asking(send: { [bridge] in bridge.send($0) })
  private var quitLater: DispatchWorkItem?

  func applicationDidFinishLaunching(_ notification: Notification) {
    pairing.open()
    bridge.pairingOpen = { [pairing] in pairing.isOpen }
    bridge.pair = { [pairing] in pairing.accept($0) }
    bridge.readyInfo = { [asking] in asking.status }
    bridge.onMessage = { [asking] in asking.handle($0) }
    bridge.onClient = { [weak self] connected in self?.client(connected) }
    do {
      try bridge.start()
    } catch {
      NSLog("Hermes AirPods: could not open the local port: \(error.localizedDescription)")
      NSApp.terminate(nil)
    }

    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(appQuit(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    if !desktopRunning { NSApp.terminate(nil) }
    scheduleQuit()
  }

  /// Connect in Hermes opens the app again while it runs.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    pairing.open()
    return false
  }

  private var desktopRunning: Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: Self.desktopBundle).isEmpty
  }

  @objc private func appQuit(_ note: Notification) {
    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    if app?.bundleIdentifier == Self.desktopBundle, !desktopRunning { NSApp.terminate(nil) }
  }

  private func client(_ connected: Bool) {
    if connected {
      quitLater?.cancel()
    } else {
      scheduleQuit()
    }
  }

  /// With no Hermes Desktop connected, there is nothing to do.
  private func scheduleQuit() {
    quitLater?.cancel()
    let work = DispatchWorkItem { NSApp.terminate(nil) }
    quitLater = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.graceSeconds, execute: work)
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
