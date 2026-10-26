import AVFoundation
import AppKit
import FluidAudio
import SwiftUI

/// What the first-run window shows and does (faux-pas#4). Every change to the
/// learner's settings is saved as it happens, so closing the window halfway
/// loses nothing; the window opens again at the next launch until Ready.
@MainActor
final class SetupModel: ObservableObject {
    @Published private(set) var step: SetupStep
    @Published private(set) var settings: LearnerSettings
    @Published private(set) var fromPardon: Set<Language> = []
    @Published private(set) var waitingForBrowser = false
    @Published private(set) var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var soundAsked = false
    @Published private(set) var modelProgress: Double?
    @Published var errorText: String?

    let account: PardonAccount
    var onFinish: (() -> Void)?
    private var loopback: LoopbackCallback?

    init(step: SetupStep, account: PardonAccount) {
        self.step = step
        self.account = account
        settings = LearnerSettings.load()
        if step == .languages { loadProfile() }
    }

    // MARK: - Steps

    func next() {
        errorText = nil
        guard let following = SetupFlow.step(after: step, modelReady: Self.modelReady) else {
            finish()
            return
        }
        step = following
        if following == .languages { loadProfile() }
        if following == .model { downloadModel() }
    }

    private func finish() {
        settings.setupDone = true
        settings.feedback = true
        save()
        onFinish?()
    }

    // MARK: - Sign in

    func signIn() {
        errorText = nil
        do {
            let loopback = try LoopbackCallback()
            self.loopback = loopback
            waitingForBrowser = true
            Task {
                do {
                    try await PardonSignIn(account: account).run(loopback: loopback)
                    NSApp.activate()
                    waitingForBrowser = false
                    next()
                } catch PardonSignIn.Failure.cancelled {
                    waitingForBrowser = false
                } catch {
                    waitingForBrowser = false
                    errorText = "\(error)"
                }
            }
        } catch {
            errorText = "Pardon could not start signing in. Try again."
        }
    }

    func cancelSignIn() {
        loopback?.cancel()
    }

    // MARK: - Languages

    private func loadProfile() {
        Task {
            guard let profile = try? await MeetingProfile.fetch(account: account) else { return }
            settings = settings.applying(profile)
            fromPardon = Set(profile.languages.filter { $0.level != nil }.map(\.language))
            save()
        }
    }

    func setNative(_ language: Language?) {
        settings.nativeLanguage = language
        if let language { settings.levels[language] = nil }
        save()
    }

    func setIncluded(_ language: Language, _ included: Bool) {
        settings.levels[language] = included ? (settings.levels[language] ?? LearnerSettings.defaultLevel) : nil
        if !settings.workLanguages.contains(settings.meetingLanguage), let first = settings.workLanguages.first {
            settings.meetingLanguage = first
        }
        save()
    }

    func setLevel(_ level: LearnerSettings.Level, for language: Language) {
        settings.levels[language] = level
        fromPardon.remove(language)
        save()
    }

    // MARK: - Permissions

    func allowMicrophone() {
        if micStatus == .denied || micStatus == .restricted {
            openPrivacy("Privacy_Microphone")
            return
        }
        // macOS answers on a background queue. Without @Sendable the closure
        // would inherit this class's main-actor isolation and trap there.
        AVCaptureDevice.requestAccess(for: .audio) { @Sendable _ in
            Task { @MainActor in self.micStatus = AVCaptureDevice.authorizationStatus(for: .audio) }
        }
    }

    /// macOS asks about the Mac's sound the first time something listens to
    /// it, so listen for a moment and throw the audio away.
    func allowSound() {
        if soundAsked {
            openPrivacy("Privacy_AudioCapture")
            return
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pardon-permission-\(UUID().uuidString).caf")
        let recorder = SystemAudioRecorder()
        do {
            try recorder.start(url: file, clock: .started(), onEvent: { _ in })
        } catch {
            errorText = "macOS did not let Pardon hear the Mac's sound. You can allow it in System Settings."
        }
        Task {
            try? await Task.sleep(for: .seconds(1))
            _ = recorder.stop()
            try? FileManager.default.removeItem(at: file)
            soundAsked = true
        }
    }

    private func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Speech model

    static var modelReady: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
    }

    func downloadModel() {
        errorText = nil
        modelProgress = 0
        Task {
            do {
                _ = try await AsrModels.download(version: .v3) { progress in
                    Task { @MainActor in self.modelProgress = progress.fractionCompleted }
                }
                modelProgress = 1
            } catch {
                modelProgress = nil
                errorText = "The speech model did not download. Check your internet connection and try again."
            }
        }
    }

    private func save() {
        do {
            try settings.save()
        } catch {
            errorText = "Your settings were not saved: \(error.localizedDescription)"
        }
    }
}

/// The window itself: one step at a time, in the release mock's words.
struct SetupView: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.step {
                case .welcome: welcome
                case .languages: languages
                case .permissions: permissions
                case .model: speechModel
                case .ready: ready
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if let error = model.errorText {
                Text(error).foregroundStyle(.red).font(.callout).padding(.top, 8)
            }
        }
        .padding(32)
        .frame(width: 480, height: 440)
    }

    private var mark: some View {
        Group {
            if let image = SetupWindowController.markImage {
                Image(nsImage: image).resizable().frame(width: 48, height: 48)
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            mark.padding(.top, 24)
            Text("Notes after every meeting").font(.title2.weight(.semibold))
            Text("Sign in so your notes match your levels and show up in Pardon.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            if model.waitingForBrowser {
                ProgressView().padding(.top, 8)
                Text("Finish signing in in your browser.").foregroundStyle(.secondary)
                Button("Cancel") { model.cancelSignIn() }
            } else {
                Button("Sign in with Pardon") { model.signIn() }
                    .buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 8)
                Text("This opens your browser. New to Pardon? You can make an account there.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    private var languages: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which languages do you speak at work?").font(.title3.weight(.semibold))
            Picker(
                "Your native language",
                selection: Binding(get: { model.settings.nativeLanguage }, set: { model.setNative($0) })
            ) {
                ForEach(Language.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                Text("Other").tag(Language?.none)
            }
            .frame(maxWidth: 300)
            ForEach(Language.allCases.filter { $0 != model.settings.nativeLanguage }, id: \.self) { language in
                HStack {
                    Toggle(
                        language.label,
                        isOn: Binding(
                            get: { model.settings.levels[language] != nil },
                            set: { model.setIncluded(language, $0) })
                    )
                    .frame(width: 120, alignment: .leading)
                    if let level = model.settings.levels[language] {
                        Picker(
                            "Level",
                            selection: Binding(get: { level }, set: { model.setLevel($0, for: language) })
                        ) {
                            ForEach(LearnerSettings.Level.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().frame(width: 200)
                        if model.fromPardon.contains(language) {
                            Text("from your Pardon level").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer()
            HStack {
                Spacer()
                Button("Continue") { model.next() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.settings.workLanguages.isEmpty)
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Pardon needs two permissions").font(.title3.weight(.semibold))
            permission(
                icon: "mic", title: "Your microphone",
                detail: "To hear what you say. Only your side of the call gets notes.",
                state: model.micStatus == .authorized
                    ? "Allowed" : model.micStatus == .notDetermined ? nil : "Not allowed",
                button: model.micStatus == .denied ? "Open Settings" : "Allow",
                done: model.micStatus == .authorized
            ) { model.allowMicrophone() }
            permission(
                icon: "speaker.wave.2", title: "Your Mac's sound",
                detail: "To tell your voice apart from the others in the call. It stays on your Mac.",
                state: model.soundAsked ? "Asked" : nil,
                button: model.soundAsked ? "Open Settings" : "Allow",
                done: false
            ) { model.allowSound() }
            Spacer()
            HStack {
                Spacer()
                Button("Continue") { model.next() }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func permission(
        icon: String, title: String, detail: String, state: String?, button: String, done: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title2).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                if let state { Text(state).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if !done { Button(button, action: action) }
        }
    }

    private var speechModel: some View {
        VStack(spacing: 14) {
            Text("Getting the speech model ready").font(.title3.weight(.semibold)).padding(.top, 40)
            Text("About 600 MB, once. It turns your meetings into text on this Mac.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let progress = model.modelProgress {
                ProgressView(value: progress).frame(width: 300)
                Text("\(Int(progress * 100))%").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Try again") { model.downloadModel() }
            }
            Spacer()
            HStack {
                Spacer()
                Button("Continue") { model.next() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.modelProgress != 1)
            }
        }
    }

    private var ready: some View {
        VStack(spacing: 14) {
            mark.padding(.top, 24)
            Text("Pardon lives in your menu bar").font(.title2.weight(.semibold))
            Text(
                "Click the asterisk at the top of your screen and choose Start recording when a meeting starts. Your notes arrive when it ends."
            )
            .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
            Button("Done") { model.next() }.buttonStyle(.borderedProminent).controlSize(.large)
        }
    }
}

/// Opens the setup window when there is something to set up.
@MainActor
final class SetupWindowController {
    private var window: NSWindow?
    private var model: SetupModel?
    var onFinish: (() -> Void)?

    static let markImage: NSImage? = PardonMark.svg.data(using: .utf8).flatMap(NSImage.init(data:))

    /// Show the window at the right step; does nothing when setup is done.
    func showIfNeeded(account: PardonAccount) async {
        let signedIn = await account.isSignedIn
        guard let step = SetupFlow.firstStep(signedIn: signedIn, setupDone: LearnerSettings.load().setupDone)
        else { return }
        show(step: step, account: account)
    }

    func show(step: SetupStep, account: PardonAccount) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let model = SetupModel(step: step, account: account)
        model.onFinish = { [weak self] in
            self?.window?.close()
            self?.onFinish?()
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Welcome to \(Brand.name)"
        window.contentView = NSHostingView(rootView: SetupView(model: model))
        window.isReleasedWhenClosed = false
        window.center()
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model?.cancelSignIn()
                self?.window = nil
                self?.model = nil
            }
        }
        self.window = window
        self.model = model
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
