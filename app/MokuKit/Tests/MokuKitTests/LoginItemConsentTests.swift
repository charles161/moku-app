import Testing
@testable import MokuKit

/// The login item is the person's: registered on Start with the switch on, never at first launch, never for a
/// development build, and Skip or close keep only a switch that was flipped.
@Test func theLoginItemFollowsTheSwitchOnStartOnly() {
    #expect(LoginItemConsent.atStart(switchOn: true, registered: false) == true)   // the first Start: added
    #expect(LoginItemConsent.atStart(switchOn: false, registered: false) == nil)   // switched off: nothing to do
    #expect(LoginItemConsent.atStart(switchOn: false, registered: true) == false)  // "Say hi again", switched off: removed
    #expect(LoginItemConsent.atStart(switchOn: true, registered: true) == nil)
    #expect(LoginItemConsent.atEarlyExit(switchOn: true, switchAtOpen: true) == nil)    // skipped, untouched: nothing
    #expect(LoginItemConsent.atEarlyExit(switchOn: false, switchAtOpen: true) == false) // switched off, then skipped: kept off
    #expect(LoginItemConsent.atEarlyExit(switchOn: true, switchAtOpen: false) == true)
    #expect(LoginItemConsent.mayRegister(bundlePath: "/Applications/Moku.app"))
    #expect(!LoginItemConsent.mayRegister(bundlePath: "/Users/charles/bunny/build/Moku.app"))
    #expect(!LoginItemConsent.mayRegister(bundlePath: "/Volumes/Moku/Moku.app"))  // running from the disk image
}
