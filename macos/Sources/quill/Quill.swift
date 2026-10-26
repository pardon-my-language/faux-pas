import AppKit
import ArgumentParser
import Foundation

@main
struct Quill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: Brand.command,
        abstract:
            "Pardon for meetings: records your meetings on this Mac, transcribes them on-device, and gives you notes on how you spoke English, French, German or Spanish.",
        subcommands: [Run.self, Doctor.self, Install.self, Notes.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    func run() throws {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        try MainActor.assumeIsolated { try runMain() }
    }

    @MainActor
    private func runMain() throws {
        let root = Config.resolveRoot(cliOverride: out)

        // Non-blocking: permissions prompt on first recording, so warnings at
        // startup are informational, not fatal.
        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.print(checks)
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let controller = AppController(root: root)

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            MainActor.assumeIsolated { controller.shutdown() }
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        FileHandle.standardError.write(
            Data(
                "\(Brand.command) up · recordings → \(root.path) · ^C to quit\n".utf8
            ))
        app.run()
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, and recordings folder."
    )

    func run() throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

struct Notes: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Write (or rewrite) Pardon's notes for a transcribed session folder."
    )

    @Argument(help: "Session folder containing transcript.json.")
    var session: String

    /// Blocks on the async pass: the root command stays synchronous because
    /// the menu-bar daemon has to own the main thread.
    func run() throws {
        let dir = URL(fileURLWithPath: (session as NSString).expandingTildeInPath, isDirectory: true)
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                outcome.result = .success(
                    try await NotesPass(settings: LearnerSettings.load()).run(sessionDir: dir))
            } catch {
                outcome.result = .failure(error)
            }
            done.signal()
        }
        done.wait()
        switch outcome.result {
        case .success(let file)?:
            print(file.path)
        case .failure(let error)?:
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            throw ExitCode(1)
        case nil:
            throw ExitCode(1)
        }
    }

    private final class Outcome: @unchecked Sendable {
        var result: Result<URL, Error>?
    }
}

/// Owns the menu bar, the current recording session, and the elapsed-time
/// ticker. All state transitions happen on the main actor.
@MainActor
final class AppController {
    private let root: URL
    private let menuBar = MenuBarController()
    private let transcription = TranscriptionCoordinator()
    private var session: RecordingSession?
    private var captureStatus = RecordingSession.CaptureStatus.allHealthy
    private var ticker: Timer?

    init(root: URL) {
        self.root = root
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.onOpenLatestNotes = { [weak self] in self?.openLatestNotes() }
        menuBar.onSettingsChange = { [weak self] change in self?.changeSettings(change) }
        menuBar.showSettings(LearnerSettings.load())
        menuBar.update(.idle)

        Task { [transcription, root] in
            await transcription.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showTranscription(status)
                }
            }
            await transcription.resumePending(root: root)
        }
    }

    /// Stop any live session cleanly (finalizing files) and exit.
    func shutdown() {
        stopSession()
        NSApp.terminate(nil)
    }

    private func toggle() {
        if session == nil {
            startSession()
        } else {
            stopSession()
        }
    }

    private func startSession() {
        do {
            let newSession = try RecordingSession(root: root)
            newSession.onStatus = { [weak self] status in
                self?.captureStatus = status
                self?.refreshMenu()
            }
            newSession.onDegraded = { kind in
                // The session fires this once per degradation episode, so the
                // user gets one notification, not one per watchdog tick.
                notifyUser(
                    title: Brand.title("\(kind.label) capture lost"),
                    body: "Recovery failed; the recording will be marked incomplete."
                )
            }
            try newSession.start()
            session = newSession
            captureStatus = .allHealthy
            FileHandle.standardError.write(Data("● recording → \(newSession.dir.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            notifyUser(title: Brand.title("recording failed"), body: "\(error)")
            return
        }

        refreshMenu()
        // Explicitly .common so the elapsed counter and menu state keep
        // updating while the menu is open (event-tracking run-loop mode).
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopSession() {
        guard let session else { return }
        let result = session.stop()
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        FileHandle.standardError.write(
            Data(
                "○ stopped · \(elapsed) · \(result.status.rawValue) · \(session.dir.path)\n".utf8
            ))
        self.session = nil
        captureStatus = .allHealthy
        ticker?.invalidate()
        ticker = nil
        menuBar.update(.idle)

        // Warn about a gap before the later "transcript ready" notification
        // implies everything went fine. Transcription still runs — recovered
        // and incomplete sessions keep whatever audio they have.
        switch result.status {
        case .complete:
            break
        case .recovered:
            notifyUser(
                title: Brand.title("recording recovered"),
                body: "Capture was interrupted and resumed; see meta.json for the gap."
            )
        case .incomplete:
            notifyUser(
                title: Brand.title("recording incomplete"),
                body: "Part of the session was not captured; see meta.json."
            )
        }
        let dir = session.dir
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    /// Rebuild the menu presentation from capture status plus elapsed time.
    private func refreshMenu() {
        guard let session else { return }
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        let display: MenuBarController.Display
        switch captureStatus.display {
        case .healthy:
            display = .recording(elapsed: elapsed)
        case .recovering(let kind):
            display = .recovering(track: kind.label, elapsed: elapsed)
        case .degraded(let kind):
            display = .degraded(track: kind.label, elapsed: elapsed)
        }
        menuBar.update(display, signalWarning: captureStatus.signalWarning)
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle:
            menuBar.updateTranscription(nil)
        case .transcribing(let name, let queued):
            menuBar.updateTranscription(
                queued > 0 ? "transcribing \(name) · \(queued) queued" : "transcribing \(name)"
            )
        case .failed(let name):
            menuBar.updateTranscription("transcription failed · \(name)")
        case .writingNotes(let name):
            menuBar.updateTranscription("writing notes · \(name)")
        }
    }

    /// Save one settings change from the menu and reflect it straight back,
    /// so the checkmarks always show what is on disk.
    private func changeSettings(_ change: MenuBarController.SettingsChange) {
        var settings = LearnerSettings.load()
        switch change {
        case .feedback(let on): settings.feedback = on
        case .meetingLanguage(let language): settings.meetingLanguage = language
        case .level(let level): settings.levels[settings.meetingLanguage] = level
        case .nativeLanguage(let language): settings.nativeLanguage = language
        }
        do {
            try settings.save()
        } catch {
            notifyUser(title: Brand.title("settings not saved"), body: "\(error)")
        }
        menuBar.showSettings(LearnerSettings.load())
        if settings.feedback, settings.resolvedAPIKey == nil {
            notifyUser(
                title: Brand.title("one more step"),
                body: "Add notes.api_key to \(Config.path.path) to get notes after meetings."
            )
        }
    }

    /// Newest session folder with Pardon's notes. Folder names sort
    /// chronologically, so newest is the last name.
    private func openLatestNotes() {
        let fm = FileManager.default
        let latest =
            ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appendingPathComponent("notes.md") }
            .filter { fm.fileExists(atPath: $0.path) }
            .max { $0.deletingLastPathComponent().lastPathComponent < $1.deletingLastPathComponent().lastPathComponent }
        guard let latest else {
            notifyUser(title: Brand.title("no notes yet"), body: "Turn on Notes after meetings, then record a meeting.")
            return
        }
        NSWorkspace.shared.open(latest)
    }

    private func tick() {
        refreshMenu()
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
