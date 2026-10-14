import CryptoKit
import Foundation

/// Caps window text for the wire and fingerprints the full text, so the brain can spot "same screen"
/// even when the text itself is left out.
enum TextDigest {
    /// Measured in UTF-16 code units, the unit the brain's JavaScript sees as `length`.
    static let maxLength = 4000

    /// The text cut to at most `maxLength` UTF-16 units, never splitting a character.
    static func capped(_ text: String, maxLength: Int = maxLength) -> String {
        guard text.utf16.count > maxLength else { return text }
        var length = 0
        var end = text.startIndex
        for index in text.indices {
            let next = text.index(after: index)
            let characterLength = text.utf16.distance(from: index, to: next)
            guard length + characterLength <= maxLength else { break }
            length += characterLength
            end = next
        }
        return String(text[..<end])
    }

    /// Lowercase hex SHA-256 of the full (uncapped) text.
    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
