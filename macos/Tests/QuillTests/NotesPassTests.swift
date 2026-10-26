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

    private func response(_ notes: MeetingNotes, stopReason: String = "end_turn") throws -> Data {
        let text = String(decoding: try JSONEncoder().encode(notes), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: [
            "stop_reason": stopReason,
            "content": [["type": "text", "text": text]],
        ])
    }

    /// Riley's case: an English speaker learning French.
    private let englishLearningFrench = LearnerSettings(
        feedback: true, meetingLanguage: .french, levels: [.french: .b1],
        nativeLanguage: .english, apiKey: "test-key")

    // MARK: - Happy path

    func testHappyPathSendsOnlyTheLearnersLines() async throws {
        let transport = MockTransport(status: 200, body: try response(notes))
        let result = try await NotesPass(settings: englishLearningFrench, transport: transport)
            .notes(on: transcript)
        XCTAssertEqual(result, notes)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("Je suis 30 ans"))
        XCTAssertTrue(body.contains("On peut livrer vendredi"))
        XCTAssertFalse(body.contains("CONFIDENTIAL"), "the other speakers' words must stay on the Mac")
        XCTAssertTrue(body.contains("json_schema"))
    }

    func testRunWritesJSONAndMarkdownIntoTheSession() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try transcript.write(to: dir)

        let transport = MockTransport(status: 200, body: try response(notes))
        let file = try await NotesPass(settings: englishLearningFrench, transport: transport)
            .run(sessionDir: dir)

        XCTAssertEqual(file.lastPathComponent, "notes.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("notes.json").path))
        let markdown = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(markdown.contains("# Pardon's notes:"))
        XCTAssertTrue(markdown.contains("You said: \"Je suis 30 ans\""))
        XCTAssertTrue(markdown.contains("A habit many English speakers have."))
    }

    // MARK: - Failures

    func testAPIErrorThrowsAndWritesNothing() async throws {
        let transport = MockTransport(status: 529, body: Data("{\"error\":\"overloaded\"}".utf8))
        do {
            _ = try await NotesPass(settings: englishLearningFrench, transport: transport)
                .notes(on: transcript)
            XCTFail("expected an error")
        } catch let failure as NotesPass.Failure {
            guard case .http(let status, _) = failure else { return XCTFail("\(failure)") }
            XCTAssertEqual(status, 529)
        }
    }

    func testEmptyTranscriptSendsNoRequest() async throws {
        let silent = Transcript(
            engine: "parakeet", model: "test", created_at: "",
            segments: [.init(speaker: "them", start_ms: 0, end_ms: 1000, text: "Il y a quelqu'un ?")]
        )
        let transport = MockTransport(status: 200, body: try response(notes))
        do {
            _ = try await NotesPass(settings: englishLearningFrench, transport: transport).notes(on: silent)
            XCTFail("expected an error")
        } catch let failure as NotesPass.Failure {
            XCTAssertEqual(failure, .nothingSaid)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testMeetingInNativeLanguageSendsNoRequest() async throws {
        var settings = englishLearningFrench
        settings.meetingLanguage = .english
        let transport = MockTransport(status: 200, body: try response(notes))
        do {
            _ = try await NotesPass(settings: settings, transport: transport).notes(on: transcript)
            XCTFail("expected an error")
        } catch let failure as NotesPass.Failure {
            XCTAssertEqual(failure, .nativeLanguageMeeting)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testMissingKeySendsNoRequest() async throws {
        var settings = englishLearningFrench
        settings.apiKey = nil
        // The environment fallback would make this test depend on the shell.
        guard ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] == nil else {
            throw XCTSkip("ANTHROPIC_API_KEY is set in this environment")
        }
        let transport = MockTransport(status: 200, body: try response(notes))
        do {
            _ = try await NotesPass(settings: settings, transport: transport).notes(on: transcript)
            XCTFail("expected an error")
        } catch let failure as NotesPass.Failure {
            XCTAssertEqual(failure, .noAPIKey)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testRefusalAndCutOffRepliesAreErrors() throws {
        XCTAssertThrowsError(try NotesPass.parse(try response(notes, stopReason: "refusal"))) {
            XCTAssertEqual($0 as? NotesPass.Failure, .refused)
        }
        XCTAssertThrowsError(try NotesPass.parse(try response(notes, stopReason: "max_tokens"))) {
            XCTAssertEqual($0 as? NotesPass.Failure, .truncated)
        }
        let garbage = try JSONSerialization.data(withJSONObject: [
            "stop_reason": "end_turn", "content": [["type": "text", "text": "not json"]],
        ])
        XCTAssertThrowsError(try NotesPass.parse(garbage))
    }

    // MARK: - Prompt

    func testPromptPutsCorrectionsInTheMeetingLanguageAndReasonsInTheNativeOne() {
        let prompt = NotesPass.systemPrompt(englishLearningFrench)
        XCTAssertTrue(prompt.contains("The meeting was in French"))
        XCTAssertTrue(prompt.contains("CEFR B1"))
        XCTAssertTrue(prompt.contains("every pattern description and the practice tip in English."))
        XCTAssertTrue(prompt.contains("Write every correction and example in French, in standard French."))
        XCTAssertTrue(prompt.contains("native language is English"))
        XCTAssertFalse(prompt.contains("Darn"))
        XCTAssertFalse(prompt.lowercased().contains("cowboy"))
    }

    func testPromptFollowsTheLevelForThisMeetingsLanguage() {
        let settings = LearnerSettings(
            meetingLanguage: .german, levels: [.french: .b2, .german: .a1], nativeLanguage: .english)
        let prompt = NotesPass.systemPrompt(settings)
        XCTAssertTrue(prompt.contains("CEFR A1"))
        XCTAssertTrue(prompt.contains("no grammar terms"))
        XCTAssertTrue(prompt.contains("standard German"))
    }

    func testPromptForASpanishSpeakerLearningEnglishIsInformalSpanish() {
        let settings = LearnerSettings(meetingLanguage: .english, nativeLanguage: .spanish)
        let prompt = NotesPass.systemPrompt(settings)
        XCTAssertTrue(prompt.contains("practice tip in Spanish. Address the learner as tú."))
        XCTAssertTrue(prompt.contains("standard American English"))
    }

    func testPromptWithoutNativeLanguageExplainsInEnglishWithNoHabits() {
        let prompt = NotesPass.systemPrompt(LearnerSettings(meetingLanguage: .spanish))
        XCTAssertTrue(prompt.contains("practice tip in English."))
        XCTAssertTrue(prompt.contains("not set"))
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
            "notes": ["api_key": "keep-me", "levels": ["french": "Z9"]],
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
        XCTAssertEqual(reread.apiKey, "keep-me")
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
        XCTAssertEqual(settings.apiKey, "old-key")
        XCTAssertEqual(settings.nativeLanguage, .french)

        let merged = settings.merged(into: old)
        XCTAssertNil(merged["darn"], "saving moves the settings under notes")
        XCTAssertEqual(LearnerSettings(json: merged).apiKey, "old-key")
    }
}

private final class MockTransport: NotesTransport, @unchecked Sendable {
    let status: Int
    let body: Data
    private(set) var requests: [URLRequest] = []

    init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        return (body, status)
    }
}
