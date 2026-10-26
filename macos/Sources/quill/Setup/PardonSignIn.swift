import AppKit
import Foundation

/// "Sign in with Pardon" (faux-pas#4, pml GH#2850): open Pardon's sign-in
/// page in the browser, wait for it to come back to this Mac with a one-time
/// code, and trade the code for a session of the app's own.
struct PardonSignIn: Sendable {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case timedOut
        case cancelled
        case wrongState
        case refused(String)
        case server(Int)

        var description: String {
            switch self {
            case .timedOut: "Signing in took too long. Try again."
            case .cancelled: "Signing in was stopped."
            case .wrongState: "That sign-in was not started here. Try again."
            case .refused(let message): message
            case .server: "Pardon did not answer. Try again in a moment."
            }
        }
    }

    let account: PardonAccount
    let transport: NotesTransport
    let openURL: @Sendable (URL) -> Void

    init(
        account: PardonAccount, transport: NotesTransport = URLSessionTransport(),
        openURL: @escaping @Sendable (URL) -> Void = { url in
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
    ) {
        self.account = account
        self.transport = transport
        self.openURL = openURL
    }

    /// The whole round trip. `loopback` lets the caller cancel it.
    func run(loopback: LoopbackCallback, timeout: TimeInterval = 600) async throws {
        let pkce = PKCE.make()
        let port = try await loopback.start()
        openURL(account.endpoints.connectURL(port: port, pkce: pkce))
        let query: [String: String]
        do {
            query = try await loopback.waitForCallback(timeout: timeout)
        } catch LoopbackCallback.Failure.timedOut {
            throw Failure.timedOut
        } catch LoopbackCallback.Failure.cancelled {
            throw Failure.cancelled
        }
        guard query["state"] == pkce.state, let code = query["code"], !code.isEmpty else {
            throw Failure.wrongState
        }
        try await account.store(try await exchange(code: code, verifier: pkce.verifier))
    }

    /// Trade the code and verifier for a session.
    func exchange(code: String, verifier: String) async throws -> PardonSession {
        var request = URLRequest(url: account.endpoints.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "verifier": verifier])
        let (data, status) = try await transport.send(request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else {
            if (400..<500).contains(status), let message = json?["error"] as? String { throw Failure.refused(message) }
            throw Failure.server(status)
        }
        guard let access = json?["access_token"] as? String, let refresh = json?["refresh_token"] as? String,
            let expires = json?["expires_at"] as? Double
        else { throw Failure.server(status) }
        return PardonSession(accessToken: access, refreshToken: refresh, expiresAt: expires)
    }
}

/// The learner's languages from their Pardon profile (pml GH#2835).
struct MeetingProfile: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let language: Language
        /// A1 to C2 as Pardon has it; nil when not placed yet.
        let level: String?
        let active: Bool
    }

    let nativeLanguage: Language?
    let languages: [Entry]

    static func fetch(account: PardonAccount, transport: NotesTransport = URLSessionTransport()) async throws
        -> MeetingProfile
    {
        var request = URLRequest(url: account.endpoints.profileURL)
        request.timeoutInterval = 30
        request.setValue("Bearer \(try await account.accessToken())", forHTTPHeaderField: "authorization")
        let (data, status) = try await transport.send(request)
        guard status == 200 else { throw PardonSignIn.Failure.server(status) }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> MeetingProfile {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PardonSignIn.Failure.server(200)
        }
        let entries = (json["languages"] as? [[String: Any]] ?? []).compactMap { row -> Entry? in
            guard let language = (row["language"] as? String).flatMap(Language.init(rawValue:)) else { return nil }
            return Entry(language: language, level: row["level"] as? String, active: row["active"] as? Bool ?? false)
        }
        return MeetingProfile(
            nativeLanguage: (json["nativeLanguage"] as? String).flatMap(Language.init(rawValue:)), languages: entries)
    }
}
