import Foundation
import XCTest

@testable import quill

/// Pardon's notes pass with the API mocked: what goes out, what comes back,
/// and every way it can fail without writing half a set of notes.
final class NotesPassTests: XCTestCase {
    private let notes = MeetingNotes(
        greeting: "Nice work in that meeting.",
        went_well: ["You asked clear questions."],
        mistakes: [
            .init(
                said: "Je suis 30 ans",
                better: "J'ai 30 ans.",
                reason: "In French, age uses avoir \u{2014} not être.",
                native_language_habit: true)
        ],
        patterns: [
            .init(pattern: "Using être for age.", example: "Je suis 30 ans", native_language_habit: true)
        ],
        practice: "Say \"J'ai 30 ans\" out loud three times before your next call."
    )

    private let transcript = Transcript(
        engine: "parakeet", model: "test", created_at: "2026-10-26T14:00:00Z",
        segments: [
            .init(speaker: "me", start_ms: 0, end_ms: 1000, text: "Je suis 30 ans"),
            .init(speaker: "them", start_ms: 1000, end_ms: 2000, text: "CONFIDENTIAL chiffres du budget"),
            .init(speaker: "me", start_ms: 2000, end_ms: 3000, text: "  "),
            .init(speaker: "me", start_ms: 3000, end_ms: 4000, text: "On peut livrer vendredi"),
        ]
    )

    private func reply(_ notes: MeetingNotes, nativeLanguage: String? = "english") throws -> Data {
        var body: [String: Any] = [
            "id": "note-1", "level": "B1",
            "notes": try JSONSerialization.jsonObject(with: try JSONEncoder().encode(notes)),
        ]
        body["nativeLanguage"] = nativeLanguage ?? NSNull()
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func error(_ code: String, _ message: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["code": code, "error": message])
    }

    /// Riley's case: an English speaker learning French.
    private let englishLearningFrench = LearnerSettings(
        feedback: true, meetingLanguage: .french, levels: [.french: .b1], nativeLanguage: .english)

    private let endpoints = PardonEndpoints(
        apiURL: URL(string: "https://app.example.test")!,
        supabaseURL: URL(string: "https://auth.example.test")!,
        publishableKey: "sb_publishable_test")

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A signed-in learner whose token is still good for an hour.
    private func signedIn(_ transport: MockTransport, store: MemoryStore? = nil) -> (PardonAccount, MemoryStore) {
        let store =
            store
            ?? MemoryStore(
                PardonSession(
                    accessToken: "access-1", refreshToken: "refresh-1",
                    expiresAt: now.timeIntervalSince1970 + 3600))
        let fixed = now
        return (PardonAccount(endpoints: endpoints, store: store, transport: transport, now: { fixed }), store)
    }

    private func pass(_ transport: MockTransport, settings: LearnerSettings? = nil, store: MemoryStore? = nil)
        -> (NotesPass, MemoryStore)
    {
        let (account, store) = signedIn(transport, store: store)
        return (NotesPass(settings: settings ?? englishLearningFrench, account: account, transport: transport), store)
    }

    private func expect(
        _ expected: NotesPass.Failure, _ work: () async throws -> Void, file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await work()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? NotesPass.Failure, expected, file: file, line: line)
        }
    }

    // MARK: - Happy path

    func testSendsOnlyTheLearnersLinesToPardonWithTheSession() async throws {
        let transport = MockTransport { _ in (200, try self.reply(self.notes)) }
        let result = try await pass(transport).0
            .notes(on: transcript, title: "2026.10.26-1400", startedAt: "2026-10-26T14:00:00Z")
        XCTAssertEqual(result, .init(notes: notes, nativeLanguage: .english))

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(request.url?.absoluteString, "https://app.example.test/api/meetings/notes")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer access-1")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["meetingLanguage"] as? String, "french")
        XCTAssertEqual(body["level"] as? String, "B1")
        XCTAssertEqual(body["lines"] as? [String], ["Je suis 30 ans", "On peut livrer vendredi"])
        XCTAssertEqual(body["title"] as? String, "2026.10.26-1400")
        XCTAssertEqual(body["startedAt"] as? String, "2026-10-26T14:00:00Z")
        let raw = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertFalse(raw.contains("CONFIDENTIAL"), "the other speakers' words must stay on the Mac")
    }

    func testRunWritesJSONAndMarkdownIntoTheSession() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try transcript.write(to: dir)

        let transport = MockTransport { _ in (200, try self.reply(self.notes)) }
        let file = try await pass(transport).0.run(sessionDir: dir)

        XCTAssertEqual(file.lastPathComponent, "notes.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("notes.json").path))
        let markdown = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(markdown.contains("# Pardon's notes:"))
        XCTAssertTrue(markdown.contains("You said: \"Je suis 30 ans\""))
        XCTAssertTrue(markdown.contains("A habit many English speakers have."))
    }

    func testHeadingsFollowTheNativeLanguageTheServerWroteIn() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try transcript.write(to: dir)

        // The menu says English, but the Pardon profile has no native language
        // in the four, so the server wrote in English with no habit tags.
        let transport = MockTransport { _ in (200, try self.reply(self.notes, nativeLanguage: nil)) }
        var settings = englishLearningFrench
        settings.nativeLanguage = .german
        let file = try await pass(transport, settings: settings).0.run(sessionDir: dir)
        let markdown = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(markdown.contains("## What went well"))
        XCTAssertFalse(markdown.contains("Typisch"))
        XCTAssertFalse(markdown.contains("A habit many"))
    }

    // MARK: - Signing in

    func testSignedOutSendsNothing() async throws {
        let transport = MockTransport { _ in (200, try self.reply(self.notes)) }
        let (notesPass, _) = pass(transport, store: MemoryStore(nil))
        await expect(.signedOut) { _ = try await notesPass.notes(on: self.transcript) }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testAnExpiredTokenIsRefreshedFirst() async throws {
        let transport = MockTransport { request in
            if request.url?.path == "/auth/v1/token" {
                return (
                    200,
                    try JSONSerialization.data(withJSONObject: [
                        "access_token": "access-2", "refresh_token": "refresh-2", "expires_in": 3600,
                    ])
                )
            }
            return (200, try self.reply(self.notes))
        }
        let store = MemoryStore(PardonSession(accessToken: "old", refreshToken: "refresh-1", expiresAt: 0))
        _ = try await pass(transport, store: store).0.notes(on: transcript)

        let refresh = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(refresh.url?.query, "grant_type=refresh_token")
        XCTAssertEqual(refresh.value(forHTTPHeaderField: "apikey"), "sb_publishable_test")
        XCTAssertEqual(transport.requests.last?.value(forHTTPHeaderField: "authorization"), "Bearer access-2")
        XCTAssertEqual(store.session?.refreshToken, "refresh-2", "the new session is kept")
    }

    func testATokenTheServerTurnsDownIsRefreshedOnceAndRetried() async throws {
        let transport = MockTransport { request in
            switch (request.url?.path, request.value(forHTTPHeaderField: "authorization")) {
            case ("/auth/v1/token", _):
                return (
                    200,
                    try JSONSerialization.data(withJSONObject: [
                        "access_token": "access-2", "refresh_token": "refresh-2", "expires_in": 3600,
                    ])
                )
            case (_, "Bearer access-1"):
                return (401, self.error("signed_out", "Sign in to Pardon to get notes."))
            default:
                return (200, try self.reply(self.notes))
            }
        }
        let result = try await pass(transport).0.notes(on: transcript)
        XCTAssertEqual(result.notes, notes)
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testARefusedRefreshSignsTheLearnerOut() async throws {
        let transport = MockTransport { request in
            request.url?.path == "/auth/v1/token"
                ? (400, Data(#"{"error":"invalid_grant"}"#.utf8))
                : (401, self.error("signed_out", "Sign in to Pardon to get notes."))
        }
        let (notesPass, store) = pass(transport)
        await expect(.signedOut) { _ = try await notesPass.notes(on: self.transcript) }
        XCTAssertNil(store.session, "a session Supabase refused is forgotten")
    }

    // MARK: - Refusals and errors

    func testDailyCapUsesTheServersWords() async throws {
        let message = "You've had notes on 10 meetings today. Notes are back tomorrow."
        let transport = MockTransport { _ in (429, self.error("daily_cap", message)) }
        await expect(.dailyCap(message)) { _ = try await self.pass(transport).0.notes(on: self.transcript) }
    }

    func testServerErrorsAndUnavailableNotes() async throws {
        let down = MockTransport { _ in (502, self.error("model_error", "Notes could not be written right now.")) }
        await expect(.server(status: 502, message: "Notes could not be written right now.")) {
            _ = try await self.pass(down).0.notes(on: self.transcript)
        }
        let notReady = MockTransport { _ in (503, self.error("not_available", "Meeting notes are not available yet.")) }
        await expect(.notAvailable) { _ = try await self.pass(notReady).0.notes(on: self.transcript) }
        let html = MockTransport { _ in (500, Data("<html>".utf8)) }
        await expect(.server(status: 500, message: "Notes could not be written right now. Try again in a moment.")) {
            _ = try await self.pass(html).0.notes(on: self.transcript)
        }
    }

    func testServerRefusalForANativeLanguageMeeting() async throws {
        // The server goes by the Pardon profile, which can differ from the menu.
        let transport = MockTransport { _ in
            (400, self.error("native_language_meeting", "This meeting is in your native language."))
        }
        await expect(.nativeLanguageMeeting) { _ = try await self.pass(transport).0.notes(on: self.transcript) }
    }

    func testUnreadableReplyWritesNothing() async throws {
        let transport = MockTransport { _ in (200, Data(#"{"notes":"oops"}"#.utf8)) }
        do {
            _ = try await pass(transport).0.notes(on: transcript)
            XCTFail("expected an error")
        } catch let failure as NotesPass.Failure {
            guard case .unreadable = failure else { return XCTFail("\(failure)") }
        }
    }

    func testEmptyTranscriptSendsNoRequest() async throws {
        let silent = Transcript(
            engine: "parakeet", model: "test", created_at: "",
            segments: [.init(speaker: "them", start_ms: 0, end_ms: 1000, text: "Il y a quelqu'un ?")]
        )
        let transport = MockTransport { _ in (200, try self.reply(self.notes)) }
        await expect(.nothingSaid) { _ = try await self.pass(transport).0.notes(on: silent) }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testMeetingInNativeLanguageSendsNoRequest() async throws {
        var settings = englishLearningFrench
        settings.meetingLanguage = .english
        let transport = MockTransport { _ in (200, try self.reply(self.notes)) }
        await expect(.nativeLanguageMeeting) {
            _ = try await self.pass(transport, settings: settings).0.notes(on: self.transcript)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    // MARK: - Endpoints

    func testEndpointsDefaultToProductionAndTheConfigCanPointAtDev() {
        XCTAssertEqual(PardonEndpoints(json: nil), .production)
        XCTAssertEqual(PardonEndpoints.production.notesURL.absoluteString, "https://app.pardonmylanguage.com/api/meetings/notes")
        let dev = PardonEndpoints(json: [
            "pardon": ["api_url": "https://dev.example.test", "supabase_url": "https://dev.supabase.co"]
        ])
        XCTAssertEqual(dev.apiURL.absoluteString, "https://dev.example.test")
        XCTAssertEqual(dev.supabaseURL.absoluteString, "https://dev.supabase.co")
        XCTAssertEqual(dev.publishableKey, PardonEndpoints.production.publishableKey)
    }

    // MARK: - Rendering

    func testHeadingsAndHabitTagFollowTheNativeLanguage() {
        let german = LearnerSettings(meetingLanguage: .english, nativeLanguage: .german)
        let out = notes.rendered(title: "t", settings: german)
        XCTAssertTrue(out.contains("# Notizen von Pardon: t"))
        XCTAssertTrue(out.contains("## Was gut lief"))
        XCTAssertTrue(out.contains("Du hast gesagt: \"Je suis 30 ans\""))
        XCTAssertTrue(out.contains("(Typisch, wenn Deutsch die Muttersprache ist.)"))

        let french = LearnerSettings(meetingLanguage: .english, nativeLanguage: .french)
        let fr = notes.rendered(title: "t", settings: french)
        XCTAssertTrue(fr.contains("Tu as dit : \"Je suis 30 ans\""))
        XCTAssertTrue(fr.contains("(Une habitude fréquente chez les francophones.)"))
    }

    func testNoHabitTagWhenNativeLanguageIsOther() {
        let out = notes.rendered(title: "t", settings: LearnerSettings(meetingLanguage: .french))
        XCTAssertTrue(out.contains("## What went well"))
        XCTAssertFalse(out.contains("A habit many"))
    }

    func testRenderedNotesHaveNoLongDashesOrEmojis() {
        let messy = MeetingNotes(
            greeting: "Great \u{1F389} meeting \u{2014} nice work!",
            went_well: ["Clear \u{2014} and calm."],
            mistakes: [],
            patterns: [],
            practice: "Practice \u{2728} once."
        )
        let out = messy.rendered(title: "t", settings: englishLearningFrench)
        XCTAssertFalse(out.contains("\u{2014}"))
        XCTAssertFalse(out.contains("\u{1F389}"))
        XCTAssertFalse(out.contains("\u{2728}"))
    }

    func testPatternWithoutFinalPeriodStillReadsAsASentence() {
        let bare = MeetingNotes(
            greeting: "Hi!", went_well: [], mistakes: [],
            patterns: [.init(pattern: "Using être for age", example: "Je suis 30 ans", native_language_habit: false)],
            practice: "Say it.")
        let out = bare.rendered(title: "t", settings: englishLearningFrench)
        XCTAssertTrue(out.contains("- Using être for age. For example: \"Je suis 30 ans\""))
    }

    func testPatternEndingInPunctuationGetsNoExtraPeriod() {
        XCTAssertEqual(MeetingNotes.sentence("Using être for age."), "Using être for age.")
        XCTAssertEqual(MeetingNotes.sentence("Say \"J'ai\":"), "Say \"J'ai\":")
        XCTAssertEqual(MeetingNotes.sentence("  "), "")
    }

    // MARK: - Settings

    func testSettingsDefaultToNotesOff() {
        XCTAssertEqual(LearnerSettings(json: nil), LearnerSettings())
        XCTAssertFalse(LearnerSettings(json: [:]).feedback)
        XCTAssertEqual(LearnerSettings().level, .b1)
        XCTAssertEqual(LearnerSettings().explanationLanguage, .english)
    }

    func testSettingsRoundTripKeepOtherKeys() {
        let stored: [String: Any] = [
            "recordings_dir": "~/Meetings",
            "notes": ["api_key": "sk-ant-old", "levels": ["french": "Z9"]],
        ]
        XCTAssertEqual(
            LearnerSettings(json: stored).level(in: .french), .b1, "an unknown level falls back to B1")

        let changed = LearnerSettings(
            feedback: true, meetingLanguage: .german, levels: [.german: .a2, .spanish: .b2],
            nativeLanguage: .english)
        let merged = changed.merged(into: stored)
        XCTAssertEqual(merged["recordings_dir"] as? String, "~/Meetings")
        let reread = LearnerSettings(json: merged)
        XCTAssertEqual(reread.meetingLanguage, .german)
        XCTAssertEqual(reread.level, .a2)
        XCTAssertEqual(reread.level(in: .spanish), .b2)
        XCTAssertEqual(reread.nativeLanguage, .english)
        XCTAssertTrue(reread.feedback)
        XCTAssertNil((merged["notes"] as? [String: Any])?["api_key"], "an old Claude key is dropped on save")
    }

    func testOtherNativeLanguageIsSavedAsOther() {
        let merged = LearnerSettings(nativeLanguage: nil).merged(into: [:])
        XCTAssertEqual((merged["notes"] as? [String: Any])?["native_language"] as? String, "other")
        XCTAssertNil(LearnerSettings(json: merged).nativeLanguage)
    }

    func testOldDarnSettingsCarryOver() {
        let old: [String: Any] = [
            "darn": ["feedback": true, "level": "B2", "native_language": "french", "api_key": "old-key"]
        ]
        let settings = LearnerSettings(json: old)
        XCTAssertTrue(settings.feedback)
        XCTAssertEqual(settings.nativeLanguage, .french)

        let merged = settings.merged(into: old)
        XCTAssertNil(merged["darn"], "saving moves the settings under notes")
        XCTAssertNil((merged["notes"] as? [String: Any])?["api_key"])
    }
}

private final class MockTransport: NotesTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let handler: (URLRequest) throws -> (Int, Data)
    private var sent: [URLRequest] = []

    init(_ handler: @escaping (URLRequest) throws -> (Int, Data)) {
        self.handler = handler
    }

    var requests: [URLRequest] { lock.withLock { sent } }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        lock.withLock { sent.append(request) }
        let (status, body) = try handler(request)
        return (body, status)
    }
}

private final class MemoryStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PardonSession?

    init(_ session: PardonSession?) {
        stored = session
    }

    var session: PardonSession? { lock.withLock { stored } }

    func load() -> PardonSession? { session }
    func save(_ session: PardonSession) throws { lock.withLock { stored = session } }
    func clear() { lock.withLock { stored = nil } }
}
