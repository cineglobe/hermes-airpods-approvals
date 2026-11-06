import Foundation
import Network
import AirPodsCore

/// A WebSocket on the loopback address only. Each connection must prove it holds the pairing token
/// before it can ask anything, and must see the same proof from the helper.
final class Bridge {
  static let port: UInt16 = 47291

  private var listener: NWListener?
  private var trusted: NWConnection?
  private let token: () -> String?

  var onMessage: (([String: Any]) -> Void)?
  var onClient: ((Bool) -> Void)?
  var readyInfo: (() -> [String: Any])?

  init(token: @escaping () -> String?) { self.token = token }

  func start() throws {
    let socket = NWProtocolWebSocket.Options()
    socket.autoReplyPing = true
    socket.maximumMessageSize = 32 * 1024 * 1024
    socket.setClientRequestHandler(.main) { _, headers in
      let origin = headers.first { $0.name.lowercased() == "origin" }?.value
      return NWProtocolWebSocket.Response(status: Handshake.allows(origin: origin) ? .accept : .reject, subprotocol: nil)
    }
    let parameters = NWParameters.tcp
    parameters.defaultProtocolStack.applicationProtocols.insert(socket, at: 0)
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
    parameters.allowLocalEndpointReuse = true
    let listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    listener.stateUpdateHandler = { state in
      if case let .failed(error) = state { NSLog("Hermes AirPods: listener failed: \(error)") }
    }
    listener.start(queue: .main)
    self.listener = listener
  }

  private func accept(_ connection: NWConnection) {
    let nonce = Handshake.nonce()
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .ready:
        self?.write(["type": "challenge", "nonce": nonce, "version": 1], to: connection)
      case .failed, .cancelled:
        self?.dropped(connection)
      default:
        break
      }
    }
    connection.start(queue: .main)
    receive(on: connection, nonce: nonce)
    // A client that doesn't prove itself quickly is dropped.
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
      if self?.trusted !== connection, connection.state == .ready { connection.cancel() }
    }
  }

  private func receive(on connection: NWConnection, nonce: String) {
    connection.receiveMessage { [weak self] data, _, _, error in
      guard let self, error == nil else { connection.cancel(); return }
      if let data, let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
        if self.trusted === connection {
          self.onMessage?(message)
        } else if !self.authenticate(connection, message, nonce: nonce) {
          connection.cancel()
          return
        }
      }
      self.receive(on: connection, nonce: nonce)
    }
  }

  private func authenticate(_ connection: NWConnection, _ message: [String: Any], nonce: String) -> Bool {
    guard message["type"] as? String == "hello", let token = token(),
      let proof = message["proof"] as? String, let theirNonce = message["nonce"] as? String,
      Handshake.matches(proof, Handshake.proof(token: token, role: "plugin", nonce: nonce))
    else { return false }

    trusted?.cancel()
    trusted = connection
    var ready = readyInfo?() ?? [:]
    ready["type"] = "ready"
    ready["proof"] = Handshake.proof(token: token, role: "helper", nonce: theirNonce)
    write(ready, to: connection)
    onClient?(true)
    return true
  }

  private func dropped(_ connection: NWConnection) {
    if trusted === connection {
      trusted = nil
      onClient?(false)
    }
  }

  func send(_ message: [String: Any]) {
    if let trusted { write(message, to: trusted) }
  }

  private func write(_ message: [String: Any], to connection: NWConnection) {
    guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
    let context = NWConnection.ContentContext(identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
    connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
  }
}
