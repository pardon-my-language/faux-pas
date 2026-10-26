import Foundation
import Security

/// Where the app talks to. All three values are public by design: the same
/// ones the website and the iPhone app ship to every learner. A `pardon` block
/// in the config file points a test build at the dev server instead:
///
///     "pardon": {
///       "api_url": "https://...vercel.app",
///       "supabase_url": "https://<dev ref>.supabase.co",
///       "publishable_key": "sb_publishable_..."
///     }
struct PardonEndpoints: Equatable, Sendable {
    var apiURL: URL
    var supabaseURL: URL
    var publishableKey: String

    static let production = PardonEndpoints(
        apiURL: URL(string: "https://app.pardonmylanguage.com")!,
        supabaseURL: URL(string: "https://pehngomclikppjtwqoww.supabase.co")!,
        publishableKey: "sb_publishable_n88DTrABaApUlP8m7mcQIQ_VmOxjSJt"
    )

    init(apiURL: URL, supabaseURL: URL, publishableKey: String) {
        self.apiURL = apiURL
        self.supabaseURL = supabaseURL
        self.publishableKey = publishableKey
    }

    /// Production, with any field the config overrides.
    init(json: [String: Any]?) {
        self = .production
        let pardon = json?["pardon"] as? [String: Any] ?? [:]
        if let raw = pardon["api_url"] as? String, let url = URL(string: raw) { apiURL = url }
        if let raw = pardon["supabase_url"] as? String, let url = URL(string: raw) { supabaseURL = url }
        if let key = pardon["publishable_key"] as? String, !key.isEmpty { publishableKey = key }
    }

    static func configured() -> PardonEndpoints {
        PardonEndpoints(json: Config.loadJSON())
    }

    var notesURL: URL { apiURL.appendingPathComponent("api/meetings/notes") }
    var profileURL: URL { apiURL.appendingPathComponent("api/meetings/profile") }
    var tokenURL: URL { apiURL.appendingPathComponent("api/meetings/connect/token") }

    /// The browser page that signs the app in (pml GH#2850).
    func connectURL(port: UInt16, pkce: PKCE) -> URL {
        var components = URLComponents(
            url: apiURL.appendingPathComponent("connect/mac"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "challenge", value: pkce.challenge),
        ]
        return components.url!
    }
}

/// A Pardon sign-in: the short-lived token the server checks, and the
/// long-lived one that gets a new one.
struct PardonSession: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    /// Seconds since 1970.
    var expiresAt: TimeInterval

    func isFresh(at now: Date) -> Bool {
        // A minute of margin so a token never expires on its way to the server.
        expiresAt - 60 > now.timeIntervalSince1970
    }
}

/// Where the session is kept between launches.
protocol SessionStore: Sendable {
    func load() -> PardonSession?
    func save(_ session: PardonSession) throws
    func clear()
}

/// The learner's login keychain, one item per Supabase project so a dev
/// sign-in never stands in for a real one.
struct KeychainSessionStore: SessionStore {
    let account: String

    init(endpoints: PardonEndpoints) {
        account = endpoints.supabaseURL.host ?? endpoints.supabaseURL.absoluteString
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(Brand.bundleID).session",
            kSecAttrAccount as String: account,
        ]
    }

    func load() -> PardonSession? {
        var item: CFTypeRef?
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(PardonSession.self, from: data)
    }

    func save(_ session: PardonSession) throws {
        let data = try JSONEncoder().encode(session)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

/// The signed-in learner. Hands out a valid token, refreshing it with
/// Supabase when it is about to expire, and forgets the session when Supabase
/// refuses the refresh (the learner signed out elsewhere or the session was
/// revoked).
actor PardonAccount {
    enum Failure: Error, Equatable {
        case signedOut
    }

    let endpoints: PardonEndpoints
    private let store: SessionStore
    private let transport: NotesTransport
    private let now: @Sendable () -> Date

    init(
        endpoints: PardonEndpoints, store: SessionStore, transport: NotesTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.endpoints = endpoints
        self.store = store
        self.transport = transport
        self.now = now
    }

    /// The account on this Mac, as configured.
    static func live() -> PardonAccount {
        let endpoints = PardonEndpoints.configured()
        return PardonAccount(endpoints: endpoints, store: KeychainSessionStore(endpoints: endpoints))
    }

    var isSignedIn: Bool { store.load() != nil }

    /// A token for the server. `forceRefresh` after the server turned one down.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let session = store.load() else { throw Failure.signedOut }
        if !forceRefresh, session.isFresh(at: now()) { return session.accessToken }
        return try await refresh(with: session.refreshToken).accessToken
    }

    /// Trade a refresh token for a new session and keep it. Also how a
    /// session from the sign-in flow gets stored.
    @discardableResult
    func refresh(with refreshToken: String) async throws -> PardonSession {
        var components = URLComponents(
            url: endpoints.supabaseURL.appendingPathComponent("auth/v1/token"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(endpoints.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])

        let (data, status) = try await transport.send(request)
        // Supabase answers 400 or 401 for a used, revoked or unknown token:
        // that sign-in is over. Anything else (offline, 5xx) leaves it alone.
        if status == 400 || status == 401 {
            store.clear()
            throw Failure.signedOut
        }
        guard status == 200,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let access = json["access_token"] as? String,
            let refresh = json["refresh_token"] as? String
        else {
            throw NotesPass.Failure.server(status: status, message: "Pardon sign-in did not answer. Try again in a moment.")
        }
        let expiresAt =
            (json["expires_at"] as? Double)
            ?? now().timeIntervalSince1970 + ((json["expires_in"] as? Double) ?? 3600)
        let session = PardonSession(accessToken: access, refreshToken: refresh, expiresAt: expiresAt)
        try store.save(session)
        return session
    }

    /// Keep a session from "Sign in with Pardon".
    func store(_ session: PardonSession) throws {
        try store.save(session)
    }

    func signOut() {
        store.clear()
    }
}
