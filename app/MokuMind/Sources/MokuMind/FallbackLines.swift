import MokuKit

/// Short built-in lines for when Luna's line isn't ready. Each kind has at least two variants
/// so Moku never has to repeat itself.
enum FallbackLines {
    static func variants(for request: VoiceRequest) -> [String] {
        let name = request.userName
        switch request.kind {
        case .nudge:
            if let unit = request.nextUnit, let minutes = request.minutesToNextUnit, let thread = request.threadTitle {
                let time = minutes == 1 ? "A minute" : "\(minutes) minutes"
                return ["\(time) until \(unit) goes up. Back to \(topic(of: thread))?",
                        "Hey, weren't we working on \(topic(of: thread))?"]
            }
            if let thread = request.threadTitle {
                return ["Hey, weren't we working on \(topic(of: thread))?", "Shall we get back to \(topic(of: thread))?"]
            }
            return ["Hey, weren't we in the middle of something?", "Shall we get back to it?"]
        case .callName:
            // Before onboarding there's no name yet: calling out "friend." would sound odd.
            let named = !name.isEmpty && name.lowercased() != "friend"
            return named ? ["\(name).", "\(name)?"] : ["Hey, friend.", "Hey there."]
        case .remindFocus:
            let minutes = max(1, request.focusMinutes ?? 1)
            let unit = minutes == 1 ? "minute" : "minutes"
            return ["You were focused for \(minutes) \(unit).", "You had \(minutes) good \(unit) going."]
        case .comeOn:
            return ["Come on, let's finish this first.", "Come on, just a little more."]
        case .welcomeBack:
            return ["Welcome back.", "There you are."]
        case .celebrate:
            if let label = request.completionLabel {
                return [completion(label), "Nice work: \(label)."]
            }
            return ["Look what we built!", "We built something!"]
        case .proud:
            return ["What a stretch.", "Look at you go."]
        case .water:
            return ["Sip of water?", "Water break?"]
        case .stretch:
            return ["Time for a little stretch.", "Stretch with me?"]
        case .lookAway:
            return ["Rest your eyes. Look far away for a bit.", "Look out the window for a moment?"]
        case .walk:
            return ["How about a short walk?", "Little walk?"]
        case .greeting:
            return ["Hi \(name)!", "Good to see you, \(name)."]
        }
    }

    /// A finished piece of work, in its own words: "Pushed auth-flow! Nice work."
    static func completion(_ label: String) -> String {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = label.first else { return "Nice work!" }
        return first.uppercased() + label.dropFirst() + "! Nice work."
    }

    /// "Auth · Login flow" reads as "login flow" in a sentence; acronyms like "DSA" keep their case.
    static func topic(of threadTitle: String) -> String {
        let parts = threadTitle.components(separatedBy: " · ")
        let topic = parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : threadTitle
        guard let first = topic.first, !topic.dropFirst().prefix(1).contains(where: \.isUppercase) else {
            return topic.isEmpty ? threadTitle : topic
        }
        return first.lowercased() + topic.dropFirst()
    }
}
