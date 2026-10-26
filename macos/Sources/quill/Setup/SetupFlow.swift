import Foundation

/// The steps of the first-run window (faux-pas#4), as in the release mock:
/// sign in, confirm languages, allow the two permissions, get the speech
/// model, then point at the menu bar. Kept apart from the window so the order
/// is tested without any UI.
enum SetupStep: Equatable, Sendable {
    case welcome
    case languages
    case permissions
    case model
    case ready
}

enum SetupFlow {
    /// Where the window opens, or nil when there is nothing to set up.
    /// Signing out sends the learner back to the start; a learner who signed
    /// in but closed the window halfway picks up at their languages.
    static func firstStep(signedIn: Bool, setupDone: Bool) -> SetupStep? {
        if !signedIn { return .welcome }
        return setupDone ? nil : .languages
    }

    /// The step after this one; nil after Ready, when setup is done.
    /// The model step is skipped when the model is already on this Mac.
    static func step(after step: SetupStep, modelReady: Bool) -> SetupStep? {
        switch step {
        case .welcome: .languages
        case .languages: .permissions
        case .permissions: modelReady ? .ready : .model
        case .model: .ready
        case .ready: nil
        }
    }
}
