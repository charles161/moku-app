import Foundation
import Testing
@testable import MokuMind

@MainActor
@Suite("moku:// links")
struct MokuLinksTests {
    @Test func eachLinkSaysWhatItAsksFor() {
        #expect(MokuLink(URL(string: "moku://break")!) == .toggleBreak)
        #expect(MokuLink(URL(string: "moku://day")!) == .openDay)
        #expect(MokuLink(URL(string: "moku://settings")!) == .openSettings)
        #expect(MokuLink(URL(string: "moku://invite/ABC123")!) == .invite(code: "ABC123"))
        #expect(MokuLink(URL(string: "moku://invite")!) == nil)  // no code: nothing to redeem
        #expect(MokuLink(URL(string: "moku://somewhere")!) == nil)
        #expect(MokuLink(URL(string: "https://hellomoku.com/day")!) == nil)
    }

    /// A link that opens Moku arrives before launch has finished (AppKit hands it over before applicationDidFinishLaunching;
    /// checked with a bare app opened by a URL: willFinishLaunching, open, didFinishLaunching). Before, moku://day, break and
    /// settings then did nothing at all: Moku opened, and Your day didn't.
    @Test func linksThatOpenMokuAreHandledOnceLaunchIsDoneAndLaterOnesAtOnce() {
        let handled = Recording<MokuLink>()
        let inbox = LinkInbox { handled.values.append($0) }
        inbox.receive([URL(string: "moku://day")!, URL(string: "moku://nothing")!, URL(string: "moku://break")!])
        #expect(handled.values.isEmpty)
        inbox.open()
        #expect(handled.values == [.openDay, .toggleBreak])
        inbox.receive([URL(string: "moku://settings")!])
        #expect(handled.values == [.openDay, .toggleBreak, .openSettings])
        inbox.open()  // a second open hands nothing over again
        #expect(handled.values.count == 3)
    }
}
