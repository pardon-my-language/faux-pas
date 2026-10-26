import Foundation
import XCTest

@testable import quill

/// Darn's feedback pass with the API mocked: what goes out, what comes back,
/// and every way it can fail without writing half a summary.
final class DarnFeedbackTests: XCTestCase {
    private let summary = DarnSummary(
        greeting: "Howdy, partner! You held your own in that meeting.",
        went_well: ["You asked clear questions."],
        mistakes: [
            .init(
                said: "I am agree with the plan",
                better: "I agree with the plan",
                reason: "In English, agree is a verb, so no am \u{2014} just I agree.",
                native_language_habit: true)
        ],
        patterns: [
            .init(pattern: "Using am before agree.", example: "I am agree", native_language_habit: true)
        ],
        practice: "Say \"I agree\" out loud three times before your next call."
    )

    private let transcript = Transcript(
        engine: "parakeet", model: "test", created_at: "2026-10-26T14:00:00Z",
        segments: [
            .init(speaker: "me", start_ms: 0, end_ms: 1000, text: "I am agree with the plan"),
            .init(speaker: "them", start_ms: 1000, end_ms: 2000, text: "CONFIDENTIAL budget numbers"),
            .init(speaker: "me", start_ms: 2000, end_ms: 3000, text: "  "),
            .init(speaker: "me", start_ms: 3000, end_ms: 4000, text: "We can ship it friday"),
        ]
    )

    private func response(_ summary: DarnSummary, stopReason: String = "end_turn") throws -> Data {
        let text = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: [
            "stop_reason": stopReason,
            "content": [["type": "text", "text": text]],
        ])
    }

    private let french = DarnSettings(feedback: true, level: .b1, nativeLanguage: .french, apiKey: "test-key")

    // MARK: - Happy path

    func testHappyPathWritesNotesFromOnlyTheLearnersLines() async throws {
        let transport = MockTransport(status: 200, body: try response(summary))
        let result = try await DarnFeedback(settings: french, transport: transport)
            .feedback(on: transcript)
        XCTAssertEqual(result, summary)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("I am agree with the plan"))
        XCTAssertTrue(body.contains("We can ship it friday"))
        XCTAssertFalse(body.contains("CONFIDENTIAL"), "the other speakers' words must stay on the Mac")
        XCTAssertTrue(body.contains("json_schema"))
    }

    func testRunWritesJSONAndMarkdownIntoTheSession() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("darn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try transcript.write(to: dir)

        let transport = MockTransport(status: 200, body: try response(summary))
        let file = try await DarnFeedback(settings: french, transport: transport).run(sessionDir: dir)

        XCTAssertEqual(file.lastPathComponent, "darn.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("darn.json").path))
        let markdown = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(markdown.contains("You said: \"I am agree with the plan\""))
        XCTAssertTrue(markdown.contains("A habit many French speakers have."))
    }

    // MARK: - Failures

    func testAPIErrorThrowsAndWritesNothing() async throws {
        let transport = MockTransport(status: 529, body: Data("{\"error\":\"overloaded\"}".utf8))
        do {
            _ = try await DarnFeedback(settings: french, transport: transport).feedback(on: transcript)
            XCTFail("expected an error")
        } catch let failure as DarnFeedback.Failure {
            guard case .http(let status, _) = failure else { return XCTFail("\(failure)") }
            XCTAssertEqual(status, 529)
        }
    }

    func testEmptyTranscriptSendsNoRequest() async throws {
        let silent = Transcript(
            engine: "parakeet", model: "test", created_at: "",
            segments: [.init(speaker: "them", start_ms: 0, end_ms: 1000, text: "Anyone there?")]
        )
        let transport = MockTransport(status: 200, body: try response(summary))
        do {
            _ = try await DarnFeedback(settings: french, transport: transport).feedback(on: silent)
            XCTFail("expected an error")
        } catch let failure as DarnFeedback.Failure {
            XCTAssertEqual(failure, .nothingSaid)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testMissingKeySendsNoRequest() async throws {
        var settings = french
        settings.apiKey = nil
        // The environment fallback would make this test depend on the shell.
        guard ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] == nil else {
            throw XCTSkip("ANTHROPIC_API_KEY is set in this environment")
        }
        let transport = MockTransport(status: 200, body: try response(summary))
        do {
            _ = try await DarnFeedback(settings: settings, transport: transport).feedback(on: transcript)
            XCTFail("expected an error")
        } catch let failure as DarnFeedback.Failure {
            XCTAssertEqual(failure, .noAPIKey)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testRefusalAndCutOffRepliesAreErrors() throws {
        XCTAssertThrowsError(try DarnFeedback.parse(try response(summary, stopReason: "refusal"))) {
            XCTAssertEqual($0 as? DarnFeedback.Failure, .refused)
        }
        XCTAssertThrowsError(try DarnFeedback.parse(try response(summary, stopReason: "max_tokens"))) {
            XCTAssertEqual($0 as? DarnFeedback.Failure, .truncated)
        }
        let garbage = try JSONSerialization.data(withJSONObject: [
            "stop_reason": "end_turn", "content": [["type": "text", "text": "not json"]],
        ])
        XCTAssertThrowsError(try DarnFeedback.parse(garbage))
    }

    // MARK: - Prompt and rendering

    func testPromptFollowsLevelAndNativeLanguage() {
        let a1 = DarnFeedback.systemPrompt(DarnSettings(level: .a1, nativeLanguage: .french))
        let b2 = DarnFeedback.systemPrompt(DarnSettings(level: .b2, nativeLanguage: .other))
        XCTAssertTrue(a1.contains("CEFR A1"))
        XCTAssertTrue(a1.contains("No grammar terms"))
        XCTAssertTrue(a1.contains("French speakers"))
        XCTAssertTrue(b2.contains("CEFR B2"))
        XCTAssertTrue(b2.contains("not set"))
        XCTAssertFalse(b2.contains("French"))
    }

    func testRenderedNotesHaveNoLongDashesOrEmojis() {
        let messy = DarnSummary(
            greeting: "Howdy \u{1F920} partner \u{2014} nice work!",
            went_well: ["Clear \u{2014} and calm."],
            mistakes: [],
            patterns: [],
            practice: "Practice \u{2728} once."
        )
        let out = messy.rendered(title: "t", settings: DarnSettings())
        XCTAssertFalse(out.contains("\u{2014}"))
        XCTAssertFalse(out.contains("\u{1F920}"))
        XCTAssertFalse(out.contains("\u{2728}"))
        XCTAssertTrue(out.contains("Howdy  partner, nice work!") || out.contains("Howdy partner, nice work!"))
    }

    func testNoHabitNoteWhenNativeLanguageIsNotSet() {
        let out = summary.rendered(title: "t", settings: DarnSettings(nativeLanguage: .other))
        XCTAssertFalse(out.contains("A habit many"))
    }

    // MARK: - Settings

    func testSettingsDefaultToFeedbackOff() {
        XCTAssertEqual(DarnSettings(json: nil), DarnSettings())
        XCTAssertFalse(DarnSettings(json: [:]).feedback)
    }

    func testSettingsRoundTripKeepOtherKeys() {
        let stored: [String: Any] = [
            "recordings_dir": "~/Meetings",
            "darn": ["api_key": "keep-me", "level": "Z9"],
        ]
        XCTAssertEqual(DarnSettings(json: stored).level, .b1, "an unknown level falls back to B1")

        let changed = DarnSettings(feedback: true, level: .a2, nativeLanguage: .spanish)
        let merged = changed.merged(into: stored)
        XCTAssertEqual(merged["recordings_dir"] as? String, "~/Meetings")
        let reread = DarnSettings(json: merged)
        XCTAssertEqual(reread.level, .a2)
        XCTAssertEqual(reread.nativeLanguage, .spanish)
        XCTAssertTrue(reread.feedback)
        XCTAssertEqual(reread.apiKey, "keep-me")
    }
}

private final class MockTransport: DarnTransport, @unchecked Sendable {
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
