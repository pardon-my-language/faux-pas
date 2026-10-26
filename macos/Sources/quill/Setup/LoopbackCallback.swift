import Foundation
import Network

/// A one-request web server on 127.0.0.1, where the browser comes back after
/// "Sign in with Pardon" (RFC 8252 loopback redirect). Only this Mac can reach
/// it, it answers one /callback, and then it stops.
final class LoopbackCallback: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case couldNotListen
        case timedOut
        case cancelled
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "pardon.loopback")
    private let lock = NSLock()
    private var portWaiter: CheckedContinuation<UInt16, Error>?
    private var callbackWaiter: CheckedContinuation<[String: String], Error>?
    private var received: [String: String]?
    private var finished = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.acceptLocalOnly = true
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw Failure.couldNotListen
        }
    }

    /// Start listening; returns the port the system picked.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { portWaiter = continuation }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let port = self.listener.port?.rawValue ?? 0
                    self.lock.withLock { self.portWaiter }?.resume(returning: port)
                    self.lock.withLock { self.portWaiter = nil }
                case .failed, .cancelled:
                    self.lock.withLock { self.portWaiter }?.resume(throwing: Failure.couldNotListen)
                    self.lock.withLock { self.portWaiter = nil }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    /// The query of the first request to /callback.
    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            self?.finish(throwing: Failure.timedOut)
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            let ready: [String: String]? = lock.withLock {
                if let received { return received }
                callbackWaiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func cancel() {
        finish(throwing: Failure.cancelled)
    }

    private func finish(throwing error: Error) {
        let waiter: CheckedContinuation<[String: String], Error>? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            defer { callbackWaiter = nil }
            return callbackWaiter
        }
        listener.cancel()
        waiter?.resume(throwing: error)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return connection.cancel() }
            let query = Self.callbackQuery(fromRequest: data ?? Data())
            let page = query == nil ? Self.notFound : Self.signedIn
            connection.send(content: Data(page.utf8), completion: .contentProcessed { _ in connection.cancel() })
            guard let query else { return }
            let waiter: CheckedContinuation<[String: String], Error>? = self.lock.withLock {
                guard !self.finished, self.received == nil else { return nil }
                self.received = query
                self.finished = self.callbackWaiter != nil
                defer { self.callbackWaiter = nil }
                return self.callbackWaiter
            }
            if let waiter {
                waiter.resume(returning: query)
                self.listener.cancel()
            }
        }
    }

    /// The query items of `GET /callback?...`, or nil for any other request.
    static func callbackQuery(fromRequest data: Data) -> [String: String]? {
        guard let firstLine = String(decoding: data, as: UTF8.self).split(separator: "\r\n").first else {
            return nil
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
            let components = URLComponents(string: "http://127.0.0.1\(parts[1])"),
            components.path == "/callback"
        else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return query
    }

    private static func page(status: String, title: String, body: String) -> String {
        let html = """
            <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title>
            <style>body{font-family:-apple-system,system-ui,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;color:#1d1d1f}main{text-align:center;max-width:28rem;padding:2rem}h1{font-size:1.5rem;font-weight:600}p{color:#6e6e73}</style>
            </head><body><main><h1>\(title)</h1><p>\(body)</p></main></body></html>
            """
        return
            "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(html)"
    }

    static let signedIn = page(
        status: "200 OK", title: "You are signed in to Pardon.", body: "You can close this tab and go back to the app.")
    static let notFound = page(status: "404 Not Found", title: "Nothing here.", body: "Go back to the Pardon app.")
}
