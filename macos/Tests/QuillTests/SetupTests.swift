import Foundation
import XCTest

@testable import quill

/// First-run setup (faux-pas#4): the sign-in round trip with the browser and
/// the server faked, the profile, and the order of the steps.
final class SetupTests: XCTestCase {
    private let endpoints = PardonEndpoints(
        apiURL: URL(string: "https://app.example.test")!,
        supabaseURL: URL(string: "https://auth.example.test")!,
        publishableKey: "sb_publishable_test")

    private func account(_ store: SetupMemoryStore = SetupMemoryStore()) -> PardonAccount {
        PardonAccount(endpoints: endpoints, store: store, transport: SetupTransport { _ in (500, Data()) })
    }

    private func tokenReply() -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "access_token": "access-1", "refresh_token": "refresh-1", "expires_at": 1_900_000_000,
        ])
    }

    /// A browser that follows the connect page straight back to the app,
    /// optionally with another state.
    private func browser(state override: String? = nil) -> @Sendable (URL) -> Void {
        { url in
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let port = query.first { $0.name == "port" }!.value!
            let state = override ?? query.first { $0.name == "state" }!.value!
            let back = URL(string: "http://127.0.0.1:\(port)/callback?code=one-time&state=\(state)")!
            Task { _ = try? await URLSession.shared.data(from: back) }
        }
    }

    // MARK: - PKCE

    func testChallengeMatchesTheRFCExample() {
        XCTAssertEqual(
            PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testFreshPKCEIsURLSafeAndShapedForTheServer() {
        let pkce = PKCE.make()
        XCTAssertEqual(pkce.verifier.count, 43)
        XCTAssertEqual(pkce.challenge.count, 43)
        XCTAssertEqual(pkce.state.count, 22)
        XCTAssertNotEqual(PKCE.make().verifier, pkce.verifier)
        for value in [pkce.verifier, pkce.challenge, pkce.state] {
            XCTAssertNil(value.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        }
    }

    func testConnectURLCarriesThePortStateAndChallengeOnly() throws {
        let pkce = PKCE.make()
        let url = endpoints.connectURL(port: 53682, pkce: pkce)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/connect/mac")
        XCTAssertEqual(
            components.queryItems?.map(\.name), ["port", "state", "challenge"])
        XCTAssertFalse(url.absoluteString.contains(pkce.verifier), "the verifier never goes to the browser")
    }

    // MARK: - Loopback

    func testLoopbackReadsOnlyTheCallback() {
        let request = Data("GET /callback?code=a%20b&state=s HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
        XCTAssertEqual(LoopbackCallback.callbackQuery(fromRequest: request), ["code": "a b", "state": "s"])
        XCTAssertNil(LoopbackCallback.callbackQuery(fromRequest: Data("GET /favicon.ico HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertNil(LoopbackCallback.callbackQuery(fromRequest: Data("POST /callback HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertNil(LoopbackCallback.callbackQuery(fromRequest: Data()))
    }

    func testLoopbackAnswersTheBrowserAndHandsOverTheQuery() async throws {
        let loopback = try LoopbackCallback()
        let port = try await loopback.start()
        XCTAssertGreaterThan(port, 1023)
        let (missing, missingResponse) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/favicon.ico")!)
        XCTAssertEqual((missingResponse as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertFalse(missing.isEmpty)
        let (page, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/callback?code=c&state=s")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("You are signed in to Pardon."))
        let query = try await loopback.waitForCallback(timeout: 5)
        XCTAssertEqual(query, ["code": "c", "state": "s"])
    }

    func testLoopbackTimesOut() async throws {
        let loopback = try LoopbackCallback()
        _ = try await loopback.start()
        do {
            _ = try await loopback.waitForCallback(timeout: 0.2)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? LoopbackCallback.Failure, .timedOut)
        }
    }

    // MARK: - Sign in

    func testSignInStoresTheSessionFromTheCode() async throws {
        let store = SetupMemoryStore()
        let transport = SetupTransport { _ in (200, self.tokenReply()) }
        let signIn = PardonSignIn(account: account(store), transport: transport, openURL: browser())
        try await signIn.run(loopback: try LoopbackCallback(), timeout: 5)

        XCTAssertEqual(store.session?.refreshToken, "refresh-1")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://app.example.test/api/meetings/connect/token")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body["code"], "one-time")
        XCTAssertEqual(body["verifier"]?.count, 43)
    }

    func testSignInRefusesACallbackItDidNotStart() async throws {
        let store = SetupMemoryStore()
        let transport = SetupTransport { _ in (200, self.tokenReply()) }
        let signIn = PardonSignIn(account: account(store), transport: transport, openURL: browser(state: "someone-else"))
        do {
            try await signIn.run(loopback: try LoopbackCallback(), timeout: 5)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? PardonSignIn.Failure, .wrongState)
        }
        XCTAssertTrue(transport.requests.isEmpty, "the code is never traded")
        XCTAssertNil(store.session)
    }

    func testSignInShowsTheServersRefusal() async throws {
        let transport = SetupTransport { _ in
            (400, try! JSONSerialization.data(withJSONObject: ["error": "This sign-in has expired. Try again from the app."]))
        }
        let signIn = PardonSignIn(account: account(), transport: transport, openURL: { _ in })
        do {
            _ = try await signIn.exchange(code: "c", verifier: "v")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? PardonSignIn.Failure, .refused("This sign-in has expired. Try again from the app."))
        }
        let down = PardonSignIn(account: account(), transport: SetupTransport { _ in (502, Data()) }, openURL: { _ in })
        do {
            _ = try await down.exchange(code: "c", verifier: "v")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? PardonSignIn.Failure, .server(502))
        }
    }

    // MARK: - Profile and settings

    func testProfileFillsLanguagesAndLevels() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "nativeLanguage": "english",
            "languages": [
                ["language": "german", "level": "A2", "active": false],
                ["language": "french", "level": "C1", "active": true],
                ["language": "spanish", "level": NSNull(), "active": false],
            ],
        ])
        let profile = try MeetingProfile.parse(data)
        XCTAssertEqual(profile.nativeLanguage, .english)
        let settings = LearnerSettings().applying(profile)
        XCTAssertEqual(settings.nativeLanguage, .english)
        XCTAssertEqual(settings.levels, [.french: .b2, .german: .a2, .spanish: .b1])
        XCTAssertEqual(settings.meetingLanguage, .french, "the language they study now comes first")
        XCTAssertEqual(settings.workLanguages, [.french, .german, .spanish])
    }

    func testProfileNeverListsTheNativeLanguageAsAWorkLanguage() {
        let profile = MeetingProfile(
            nativeLanguage: .french,
            languages: [.init(language: .french, level: "B1", active: true), .init(language: .english, level: "B2.1", active: false)])
        let settings = LearnerSettings().applying(profile)
        XCTAssertEqual(settings.levels, [.english: .b2])
        XCTAssertEqual(settings.meetingLanguage, .english)
    }

    func testPardonLevelsReadAsMenuLevels() {
        XCTAssertEqual(LearnerSettings.Level(pardon: "B1.2"), .b1)
        XCTAssertEqual(LearnerSettings.Level(pardon: "c2"), .b2)
        XCTAssertNil(LearnerSettings.Level(pardon: "Z9"))
        XCTAssertNil(LearnerSettings.Level(pardon: nil))
    }

    func testSetupDoneIsSaved() {
        var settings = LearnerSettings()
        XCTAssertFalse(settings.setupDone)
        settings.setupDone = true
        XCTAssertTrue(LearnerSettings(json: settings.merged(into: [:])).setupDone)
    }

    // MARK: - Steps

    func testWhereTheWindowOpens() {
        XCTAssertEqual(SetupFlow.firstStep(signedIn: false, setupDone: false), .welcome)
        XCTAssertEqual(SetupFlow.firstStep(signedIn: false, setupDone: true), .welcome, "signed out starts over")
        XCTAssertEqual(SetupFlow.firstStep(signedIn: true, setupDone: false), .languages, "picks up halfway")
        XCTAssertNil(SetupFlow.firstStep(signedIn: true, setupDone: true))
    }

    func testStepOrderSkipsTheModelWhenItIsThere() {
        XCTAssertEqual(SetupFlow.step(after: .welcome, modelReady: false), .languages)
        XCTAssertEqual(SetupFlow.step(after: .languages, modelReady: false), .permissions)
        XCTAssertEqual(SetupFlow.step(after: .permissions, modelReady: false), .model)
        XCTAssertEqual(SetupFlow.step(after: .permissions, modelReady: true), .ready)
        XCTAssertEqual(SetupFlow.step(after: .model, modelReady: true), .ready)
        XCTAssertNil(SetupFlow.step(after: .ready, modelReady: true))
    }
}

private final class SetupTransport: NotesTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let handler: (URLRequest) -> (Int, Data)
    private var sent: [URLRequest] = []

    init(_ handler: @escaping (URLRequest) -> (Int, Data)) {
        self.handler = handler
    }

    var requests: [URLRequest] { lock.withLock { sent } }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        lock.withLock { sent.append(request) }
        let (status, body) = handler(request)
        return (body, status)
    }
}

private final class SetupMemoryStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PardonSession?

    var session: PardonSession? { lock.withLock { stored } }

    func load() -> PardonSession? { session }
    func save(_ session: PardonSession) throws { lock.withLock { stored = session } }
    func clear() { lock.withLock { stored = nil } }
}
