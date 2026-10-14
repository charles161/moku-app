import Foundation

/// Cleans window titles and page addresses before they leave the sensor, so that
/// cosmetic flicker (unread counters, invisible characters, tracking parameters) never looks like a new context.
enum Normalize {
    static let maxTitleLength = 300
    static let maxURLLength = 1000

    /// Query parameters that only track where a click came from.
    static let trackingParameters: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "igshid",
        "mc_cid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok", "ref_src", "si",
    ]

    static func title(_ raw: String) -> String {
        String(stripLeadingCounter(name(raw)).prefix(maxTitleLength))
    }

    /// Visible characters only, whitespace collapsed: "\u{200E}WhatsApp " → "WhatsApp".
    static func name(_ raw: String) -> String {
        let visible = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !isInvisible($0) }))
        return visible.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A clean page address, or nil when there is nothing usable.
    static func url(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        guard var components = URLComponents(string: trimmed), components.scheme != nil else {
            return String(trimmed.prefix(maxURLLength))
        }
        components.user = nil
        components.password = nil
        if let items = components.queryItems {
            let kept = items.filter { !isTrackingParameter($0.name) }
            components.queryItems = kept.isEmpty ? nil : kept
        }
        let cleaned = components.string ?? trimmed
        return String(cleaned.prefix(maxURLLength))
    }

    static func isTrackingParameter(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("utm_") || trackingParameters.contains(lower)
    }

    /// Zero-width, bidi-control and other control characters that some apps put in titles.
    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0xFEFF: return true
        default: return scalar.properties.generalCategory == .control && !scalar.properties.isWhitespace
        }
    }

    /// "(3) YouTube" → "YouTube"; "(99+) Inbox" → "Inbox". Unread counts change constantly and carry no context.
    private static func stripLeadingCounter(_ title: String) -> String {
        guard let match = title.firstMatch(of: /^\(\d+\+?\)\s+/) else { return title }
        let rest = title[match.range.upperBound...]
        return rest.isEmpty ? title : String(rest)
    }
}
