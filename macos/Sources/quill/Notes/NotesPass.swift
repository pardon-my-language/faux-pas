import Foundation

/// Pardon's post-meeting notes pass (faux-pas#1, #7). Takes the learner's own
/// lines from a finished transcript (the "me" track only; other speakers'
/// words never leave the Mac), sends them to Pardon's server on the learner's
/// account (D-181), and writes notes.json plus a readable notes.md into the
/// session folder.
///
/// The server holds the prompt and the model key, so no learner needs one.
/// It reads the learner's level and native language from their Pardon
/// profile; the menu's level covers languages they do not study with Pardon.
struct NotesPass: Sendable {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case signedOut
        case nothingSaid
        case nativeLanguageMeeting
        case dailyCap(String)
        case notAvailable
        case server(status: Int, message: String)
        case unreadable(String)

        var description: String {
            switch self {
            case .signedOut:
                "Sign in to Pardon to get notes after meetings."
            case .nothingSaid:
                "You did not speak in this recording, so there are no notes this time."
            case .nativeLanguageMeeting:
                "This meeting is in your native language, so there are no notes."
            case .dailyCap(let message):
                message
            case .notAvailable:
                "Meeting notes are not available yet."
            case .server(_, let message):
                message
            case .unreadable(let detail):
                "Pardon's notes could not be read: \(detail)"
            }
        }
    }

    /// What the server sends back: the notes, and the native language it
    /// wrote the reasons in (from the learner's profile).
    struct Reply: Equatable, Sendable {
        let notes: MeetingNotes
        let nativeLanguage: Language?
    }

    let settings: LearnerSettings
    let account: PardonAccount
    let transport: NotesTransport

    init(
        settings: LearnerSettings, account: PardonAccount = .live(),
        transport: NotesTransport = URLSessionTransport()
    ) {
        self.settings = settings
        self.account = account
        self.transport = transport
    }

    /// Run the pass for one session folder that already has transcript.json.
    /// Returns the notes file's URL.
    @discardableResult
    func run(sessionDir: URL) async throws -> URL {
        let data = try Data(contentsOf: sessionDir.appendingPathComponent("transcript.json"))
        let transcript = try JSONDecoder().decode(Transcript.self, from: data)
        let started = (try? Data(contentsOf: sessionDir.appendingPathComponent("meta.json")))
            .flatMap { try? JSONDecoder().decode(SessionMeta.self, from: $0) }?.started
        let reply = try await notes(on: transcript, title: sessionDir.lastPathComponent, startedAt: started)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(reply.notes)
            .write(to: sessionDir.appendingPathComponent("notes.json"), options: .atomic)
        // Headings follow the language the server wrote the reasons in.
        var rendering = settings
        rendering.nativeLanguage = reply.nativeLanguage
        let markdown = sessionDir.appendingPathComponent("notes.md")
        try Data(reply.notes.rendered(title: sessionDir.lastPathComponent, settings: rendering).utf8)
            .write(to: markdown, options: .atomic)
        return markdown
    }

    /// The server round trip. Checked in this order so no request is ever
    /// sent for a meeting in the learner's own language or with nothing to
    /// say. A token the server turns down is refreshed once and retried.
    func notes(on transcript: Transcript, title: String? = nil, startedAt: String? = nil) async throws -> Reply {
        guard !settings.meetingIsInNativeLanguage else { throw Failure.nativeLanguageMeeting }
        let lines = Self.learnerLines(transcript)
        guard !lines.isEmpty else { throw Failure.nothingSaid }

        let body = try requestBody(lines: lines, title: title, startedAt: startedAt)
        var (data, status) = try await send(body, token: try await token())
        if status == 401 {
            (data, status) = try await send(body, token: try await token(forceRefresh: true))
        }
        guard status == 200 else { throw Self.failure(status: status, data: data) }
        return try Self.parse(data)
    }

    private func token(forceRefresh: Bool = false) async throws -> String {
        do {
            return try await account.accessToken(forceRefresh: forceRefresh)
        } catch PardonAccount.Failure.signedOut {
            throw Failure.signedOut
        }
    }

    private func send(_ body: Data, token: String) async throws -> (Data, Int) {
        var request = URLRequest(url: account.endpoints.notesURL)
        request.httpMethod = "POST"
        // The server allows itself two minutes to write the notes.
        request.timeoutInterval = 150
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = body
        return try await transport.send(request)
    }

    /// Only the learner's lines, in order. Empty and whitespace-only segments
    /// are dropped so a silent mic does not cost a request.
    static func learnerLines(_ transcript: Transcript) -> [String] {
        transcript.segments
            .filter { $0.speaker == "me" }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func requestBody(lines: [String], title: String?, startedAt: String?) throws -> Data {
        var body: [String: Any] = [
            "meetingLanguage": settings.meetingLanguage.rawValue,
            "level": settings.level.rawValue,
            "lines": lines,
        ]
        if let title { body["title"] = title }
        if let startedAt { body["startedAt"] = startedAt }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// The server's refusals, as the learner should read them.
    static func failure(status: Int, data: Data) -> Failure {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = json?["code"] as? String
        let message = json?["error"] as? String
        switch (status, code) {
        case (401, _): return .signedOut
        case (_, "native_language_meeting"): return .nativeLanguageMeeting
        case (_, "nothing_said"): return .nothingSaid
        case (429, _): return .dailyCap(message ?? "You've had all your notes for today. Notes are back tomorrow.")
        case (503, _): return .notAvailable
        default:
            return .server(
                status: status, message: message ?? "Notes could not be written right now. Try again in a moment.")
        }
    }

    static func parse(_ data: Data) throws -> Reply {
        struct Body: Decodable {
            let notes: MeetingNotes
            let nativeLanguage: String?
        }
        do {
            let body = try JSONDecoder().decode(Body.self, from: data)
            return Reply(notes: body.notes, nativeLanguage: body.nativeLanguage.flatMap(Language.init(rawValue:)))
        } catch {
            throw Failure.unreadable("\(error)")
        }
    }
}

/// How requests go out. Swappable so tests never hit a real server.
protocol NotesTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

struct URLSessionTransport: NotesTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
