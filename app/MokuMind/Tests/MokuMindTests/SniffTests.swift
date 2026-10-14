import Foundation
import Testing
import MokuKit
@testable import MokuMind

/// Moku's sniff (next-wave.md §2): a window new to it comes to the front while you work.
@Suite("The sniff of a new window")
struct SniffTests {
    @Test func aNewWindowWhileWorkingIsSniffed() {
        var h = EngineHarness()
        h.send(.focusChanged(Fixtures.editorApp, Fixtures.editorWindow))
        h.work(120, context: Fixtures.editor)
        #expect(h.send(.focusChanged(Fixtures.terminalApp, nil)).gestures == [.sniff])
    }

    @Test func goingBackAndForthIsntNewsAndSniffsAreSpaced() {
        var h = EngineHarness()
        h.send(.focusChanged(Fixtures.editorApp, Fixtures.editorWindow))
        h.work(120, context: Fixtures.editor)
        #expect(h.send(.focusChanged(Fixtures.terminalApp, nil)).gestures == [.sniff])
        h.work(30)
        // The editor was in front half a minute ago: not new.
        #expect(h.send(.focusChanged(Fixtures.editorApp, Fixtures.editorWindow)).gestures.isEmpty)
        h.work(20)
        // A new place, but within a minute of the last sniff.
        #expect(h.send(.focusChanged(Fixtures.browserApp, Fixtures.docsWindow)).gestures.isEmpty)
        h.work(61, context: Fixtures.docs)
        // Back to the terminal after more than a minute, but it was in front two minutes ago.
        #expect(h.send(.focusChanged(Fixtures.terminalApp, nil)).gestures.isEmpty)
        h.work(700)
        // Ten minutes on, the editor is new again.
        #expect(h.send(.focusChanged(Fixtures.editorApp, Fixtures.editorWindow)).gestures == [.sniff])
    }

    @Test func noSniffOutsideWork() {
        var h = EngineHarness()
        // Before anything is known (just launched).
        #expect(h.send(.focusChanged(Fixtures.editorApp, Fixtures.editorWindow)).gestures.isEmpty)
        h.work(120, context: Fixtures.editor)
        // The switch to a new window is sniffed (Moku can't know yet that it's a drift), and then judged.
        #expect(h.send(.focusChanged(Fixtures.browserApp, Fixtures.youtubeWindow)).gestures == [.sniff])
        h.drift(90, context: Fixtures.youtube)
        // In a drift Moku is looking at you; a switch is the drift's business (or the return's).
        #expect(!h.send(.focusChanged(Fixtures.terminalApp, nil)).gestures.contains(.sniff))
        h.work(120)
        h.send(.startBreak)
        #expect(!h.send(.focusChanged(Fixtures.browserApp, Fixtures.docsWindow)).gestures.contains(.sniff))
    }

    @Test func aBrowserSniffsOnceItsAddressArrives() {
        var h = EngineHarness()
        h.send(.focusChanged(Fixtures.browserApp, Fixtures.docsWindow))  // Safari is a browser from now on
        h.work(700, context: Fixtures.docs)
        h.send(.focusChanged(Fixtures.editorApp, Fixtures.editorWindow))
        h.work(70, context: Fixtures.editor)
        #expect(h.send(.focusChanged(Fixtures.browserApp, nil)).gestures.isEmpty)  // the address follows
        #expect(h.send(.focusChanged(Fixtures.browserApp, Fixtures.youtubeWindow)).gestures == [.sniff])
    }
}
