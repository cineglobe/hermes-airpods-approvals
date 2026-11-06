import AppKit
import AirPodsCore

/// The pairing token lives in a file only this user can read.
final class Pairing {
  private let url: URL
  private(set) var token: String?
  var openUntil = Date.distantPast

  init() {
    let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Hermes AirPods")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    url = folder.appendingPathComponent("pairing")
    token = (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Only the first pairing is automatic. After that the user has to choose Pair Again, so another
  /// app can't swap the token by opening a link.
  func accept(_ candidate: String) -> Bool {
    guard candidate.count >= 32, candidate.allSatisfy(\.isHexDigit) else { return false }
    guard token == nil || Date() < openUntil else { return false }
    FileManager.default.createFile(atPath: url.path, contents: Data(candidate.utf8), attributes: [.posixPermissions: 0o600])
    token = candidate
    openUntil = .distantPast
    return true
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private let pairing = Pairing()
  private lazy var bridge = Bridge(token: { [pairing] in pairing.token })
  private lazy var asking = Asking(send: { [bridge] in bridge.send($0) })
  private var statusItem: NSStatusItem!
  private let line = NSMenuItem(title: "Waiting for Hermes", action: nil, keyEquivalent: "")
  private var idleQuit: DispatchWorkItem?

  func applicationWillFinishLaunching(_ notification: Notification) {
    NSAppleEventManager.shared().setEventHandler(
      self, andSelector: #selector(openLink(_:reply:)),
      forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem.button?.image = NSImage(systemSymbolName: "airpods", accessibilityDescription: "Hermes AirPods")
    let menu = NSMenu()
    line.isEnabled = false
    menu.addItem(line)
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Pair Again", action: #selector(pairAgain), keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    statusItem.menu = menu

    bridge.readyInfo = { [asking] in asking.status }
    bridge.onMessage = { [asking] in asking.handle($0) }
    bridge.onClient = { [weak self] connected in self?.client(connected) }
    do {
      try bridge.start()
    } catch {
      NSLog("Hermes AirPods: could not open the local port: \(error.localizedDescription)")
      NSApp.terminate(nil)
    }
    scheduleIdleQuit()
  }

  private func client(_ connected: Bool) {
    line.title = connected ? "Connected to Hermes" : "Waiting for Hermes"
    if connected {
      idleQuit?.cancel()
    } else {
      scheduleIdleQuit()
    }
  }

  /// With no Hermes Desktop to serve, there's no reason to keep running.
  private func scheduleIdleQuit() {
    idleQuit?.cancel()
    let work = DispatchWorkItem { NSApp.terminate(nil) }
    idleQuit = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: work)
  }

  @objc private func pairAgain() {
    pairing.openUntil = Date().addingTimeInterval(60)
    line.title = "Press Connect in Hermes"
  }

  @objc private func openLink(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
    guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
      let parts = URLComponents(string: text), parts.scheme == "hermes-airpods", parts.host == "pair",
      let token = parts.queryItems?.first(where: { $0.name == "token" })?.value
    else { return }
    if pairing.accept(token) { line.title = "Paired" }
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
