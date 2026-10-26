import Foundation

/// User-facing names. The Swift target and source folders keep Quill's names
/// so upstream changes keep merging cleanly; everything a person sees says
/// Darn (Pardon's English companion, D-170 in the pml decision log).
enum Brand {
    static let name = "Darn"
    static let command = "darn"
    static let bundleID = "com.joinpardon.darn"

    /// Notification title, e.g. "Darn: transcript ready".
    static func title(_ event: String) -> String {
        "\(name): \(event)"
    }
}
