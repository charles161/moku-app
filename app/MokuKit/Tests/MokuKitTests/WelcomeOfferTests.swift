import Testing
@testable import MokuKit

/// Launch QA, lens 1: "Skip for now" used to bring the welcome back at every launch, and at every login, for ever.
@Test func theWelcomeIsOfferedUntilItsFinishedOrLeftTwice() {
    #expect(WelcomeOffer.shouldOffer(completed: false, earlyExits: 0))  // a first launch
    #expect(WelcomeOffer.shouldOffer(completed: false, earlyExits: 1))  // skipped once: once more
    #expect(!WelcomeOffer.shouldOffer(completed: false, earlyExits: 2))  // twice is a no
    #expect(!WelcomeOffer.shouldOffer(completed: false, earlyExits: 9))
    #expect(!WelcomeOffer.shouldOffer(completed: true, earlyExits: 0))  // finished: never again
    #expect(!WelcomeOffer.shouldOffer(completed: true, earlyExits: 1))
}

/// A welcome macOS quit for Screen Recording ("Quit & Reopen") comes back where it was, whatever came before: "Say hi
/// again" after the welcome was finished, or a third try after two skips. It said "I'll pick up right here", and then Moku
/// reopened with no welcome at all.
@Test func aWelcomeInProgressComesBackAfterQuitAndReopen() {
    #expect(WelcomeOffer.shouldOffer(completed: true, earlyExits: 0, inProgress: true))   // "Say hi again", then Screen Recording
    #expect(WelcomeOffer.shouldOffer(completed: false, earlyExits: 2, inProgress: true))  // opened by hand after two skips
    #expect(!WelcomeOffer.shouldOffer(completed: true, earlyExits: 0, inProgress: false))
}
