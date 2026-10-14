import Foundation

/// The name the companion calls the person by, made safe wherever it comes from (the Mac account, the welcome,
/// Settings). The brain refuses a name that is empty, longer than 60 UTF-16 units (an emoji counts two) or has a tab or
/// a line break in it, and a refused name used to leave the person "friend" for good, so every name goes through here first.
public enum PersonName {
    /// The brain's limit (brain-go/internal/brain/config.go), in UTF-16 units.
    public static let maxUTF16 = 60
    /// What the companion calls someone who has no name to give.
    public static let fallback = "friend"

    /// `text` as a name: any run of spaces, tabs and line breaks becomes one space, the ends are trimmed, other control
    /// characters are dropped, and it's cut to the brain's limit at a whole character (never half an emoji). Nil when
    /// nothing is left.
    public static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        var line = "", gap = false
        for character in text {
            if character.isWhitespace || character.isNewline { gap = true; continue }
            if character.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) { continue }
            if gap, !line.isEmpty { line.append(" ") }
            gap = false
            line.append(character)
        }
        var kept = "", units = 0
        for character in line {
            units += character.utf16.count
            if units > maxUTF16 { break }
            kept.append(character)
        }
        while kept.last?.isWhitespace == true { kept.removeLast() }
        return kept.isEmpty ? nil : kept
    }

    /// Titles that come before a first name ("Dr. Rao" is Rao's first name only by accident).
    private static let titles: Set<String> = ["mr", "mrs", "ms", "miss", "mx", "dr", "prof", "sir", "madam"]
    /// Account names a Mac gives itself, which aren't a name ("Hi, Admin.").
    private static let generic: Set<String> = ["admin", "administrator", "user", "owner", "guest", "root", "test", "apple", "mac", "macbook", "imac", "my"]

    /// A first name guessed from the macOS account's full name ("Charles Joseph" gives "Charles"). Skips a title or an
    /// initial in front, calls "CHARLES" "Charles", and gives nothing for an empty or generic account ("Administrator").
    public static func suggestion(fromFullName full: String?) -> String? {
        guard let full else { return nil }
        for word in full.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            if bare.isEmpty || titles.contains(bare.lowercased()) { continue }
            if bare.count == 1, bare.first?.isLetter == true, word.hasSuffix(".") { continue }  // "J. Robert": an initial
            guard !generic.contains(bare.lowercased()), !bare.lowercased().hasPrefix("macbook") else { return nil }
            guard var name = clean(bare) else { return nil }
            if name.count > 1, name == name.uppercased(), name != name.lowercased() { name = name.capitalized }
            return name
        }
        return nil
    }
}
