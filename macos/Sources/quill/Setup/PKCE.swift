import CryptoKit
import Foundation
import Security

/// The proof that ties a browser sign-in to this app (PKCE, RFC 7636, S256).
/// The app sends only the challenge to the browser; the verifier never leaves
/// the app until it trades the one-time code for a session.
struct PKCE: Equatable, Sendable {
    let verifier: String
    let challenge: String
    /// Echoed back with the code, so the app only accepts the sign-in it started.
    let state: String

    static func make() -> PKCE {
        let verifier = randomURLSafe(bytes: 32)
        return PKCE(verifier: verifier, challenge: challenge(for: verifier), state: randomURLSafe(bytes: 16))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "no secure random bytes")
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
