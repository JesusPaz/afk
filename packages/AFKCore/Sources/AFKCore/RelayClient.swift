import Foundation
import Combine

public enum AFKError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public enum ServerAddress {
    public static func parse(_ value: String) throws -> URL {
        guard let u = URL(string: value), let host = u.host, u.user == nil, u.password == nil,
              u.query == nil, u.fragment == nil, u.path.isEmpty || u.path == "/",
              u.scheme == "https" || (u.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)) else {
            throw AFKError.message("Usa HTTPS. HTTP solo se permite en localhost para el POC.")
        }
        return u
    }
}

@MainActor
public final class RelayClient: ObservableObject {
    @Published public private(set) var connected = false
    @Published public private(set) var status = "Sin conexión"
    public var onMessage: ((Message) -> Void)?
    public var onDisconnect: (() -> Void)?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var outgoing: [Message] = []
    private var generation = UUID()
    private let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    public init() {}
    public func request<Response: Decodable>(_ base: URL, path: String, method: String = "POST", token: String? = nil, body: [String: String]? = nil) async throws -> Response {
        var request = URLRequest(url: base.appendingPathComponent(path)); request.httpMethod = method; request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "No se pudo conectar al servidor."
            throw AFKError.message(message)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
    public func revoke(_ base: URL, token: String, clientID: String) async throws {
        var r = URLRequest(url: base.appendingPathComponent("v1/clients/\(clientID)")); r.httpMethod = "DELETE"; r.timeoutInterval = 15
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: r)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else { throw AFKError.message("No se pudo revocar el acceso.") }
    }
    public func connect(_ base: URL, token: String) {
        disconnect(); let current = UUID(); generation = current
        var parts = URLComponents(url: base.appendingPathComponent("v1/connect"), resolvingAgainstBaseURL: false)!
        parts.scheme = base.scheme == "https" ? "wss" : "ws"
        var request = URLRequest(url: parts.url!); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request); socket.maximumMessageSize = 512 * 1024; self.socket = socket; socket.resume(); status = "Conectando…"
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let received = try await socket.receive()
                    guard let self, self.generation == current else { return }
                    let bytes: Data
                    switch received { case .string(let text): bytes = Data(text.utf8); case .data(let data): bytes = data; @unknown default: continue }
                    let message = try JSONDecoder().decode(Message.self, from: bytes)
                    self.connected = true; self.status = "Conectado"; self.onMessage?(message)
                }
            } catch {
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.disconnect(); self.status = "Sin conexión. Reintenta para continuar."
            }
        }
    }
    public func send(_ message: Message) {
        guard socket != nil else { return }
        guard outgoing.count < 16 else { disconnect(); status = "Conexión lenta. Reconecta para recuperar la sesión."; return }
        outgoing.append(message)
        guard sender == nil else { return }
        let current = generation
        sender = Task { [weak self] in
            guard let self else { return }
            do {
                while self.generation == current, !self.outgoing.isEmpty, !Task.isCancelled {
                    let next = self.outgoing.removeFirst()
                    let data = try JSONEncoder().encode(next)
                    guard let socket = self.socket else { return }
                    try await socket.send(.string(String(decoding: data, as: UTF8.self)))
                }
                if self.generation == current { self.sender = nil }
            } catch {
                if self.generation == current { self.disconnect() }
            }
        }
    }
    public func disconnect() {
        generation = UUID(); receiver?.cancel(); receiver = nil; sender?.cancel(); sender = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil; outgoing.removeAll(); connected = false; status = "Sin conexión"; onDisconnect?()
    }
}
