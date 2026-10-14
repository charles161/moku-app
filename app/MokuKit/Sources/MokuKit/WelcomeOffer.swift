import Foundation

/// When the welcome is offered. "Skip for now" and the close button leave it unfinished, and it's offered again at the next
/// launch; but Moku opens at login, so a person who has left it twice has said no, and a third welcome would greet them
/// every morning. "Say hi again" in the menu is still there. (macOS's Quit & Reopen for Screen Recording is not an exit.)
/// `inProgress`: a welcome macOS just quit for Screen Recording, which said "I'll pick up right here": it comes back where
/// it was, whatever came before (a "Say hi again" after the welcome was finished, or a try after two skips).
public enum WelcomeOffer {
    public static let maxEarlyExits = 2
    public static func shouldOffer(completed: Bool, earlyExits: Int, inProgress: Bool = false) -> Bool {
        inProgress || (!completed && earlyExits < maxEarlyExits)
    }
}
