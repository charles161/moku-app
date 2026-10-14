import CoreGraphics
import Testing
@testable import MokuSense

/// Moku steps aside for full-screen *media* (the friends, 2026-10-14), not for every full-screen window: the 2026-10-12
/// rule hid it all day from someone working in a full-screen editor, or with a zoomed window and the menu bar set to
/// hide itself. A display shows media when its full-screen window's app keeps the display awake (a film playing) or is
/// an app for watching; once it counted, a pause doesn't bring Moku back over the film.
@Suite struct FullScreenMediaTests {
    static let editor = WindowEntry(id: 10, pid: 200, layer: 0, bounds: CGRect(x: 0, y: 32, width: 1470, height: 924), title: "")
    static let covering: [UInt32: WindowEntry] = [1: editor]

    static func media(_ covering: [UInt32: WindowEntry], playing: Set<pid_t> = [], watching: Set<pid_t> = [],
                      onWorkPage: Set<pid_t> = [], remembered: Set<CGWindowID> = []) -> (displays: Set<UInt32>, remembered: Set<CGWindowID>) {
        FullScreenMedia.displays(covering: covering, playing: playing, isWatchingApp: { watching.contains($0) },
                                 isOnWorkPage: { onWorkPage.contains($0) }, remembered: remembered)
    }

    @Test func aFullScreenEditorLeavesMokuOut() {
        #expect(Self.media(Self.covering).displays.isEmpty)
    }

    @Test func aFilmPlayingFullScreenHidesMoku() {
        let result = Self.media(Self.covering, playing: [200])
        #expect(result.displays == [1])
        #expect(result.remembered == [10])
    }

    @Test func aPausedFilmStillHidesMokuUntilFullScreenEnds() {
        #expect(Self.media(Self.covering, remembered: [10]).displays == [1])
        let left = Self.media([:], remembered: [10])
        #expect(left.displays.isEmpty && left.remembered.isEmpty)
    }

    /// A full-screen browser that showed a reel, then a tab of work: Moku comes back (the window is long-lived, so
    /// remembering it would hide Moku for the rest of the day).
    @Test func aBrowserMovedFromAVideoToWorkBringsMokuBack() {
        let worked = Self.media(Self.covering, onWorkPage: [200], remembered: [10])
        #expect(worked.displays.isEmpty && worked.remembered.isEmpty)
        #expect(Self.media(Self.covering, playing: [200], onWorkPage: [200]).displays == [1], "a film playing on any page counts")
    }

    @Test func anAppForWatchingCountsEvenPaused() {
        #expect(Self.media(Self.covering, watching: [200]).displays == [1])
    }

    @Test func aFilmInAnotherAppDoesNotHideMokuOverTheEditor() {
        #expect(Self.media(Self.covering, playing: [300]).displays.isEmpty)
    }

    @Test func aHelperPlaysForItsApp() {
        // Chrome's helpers are its children; WebKit's media process says whom it plays for.
        let helper = MediaPlayback.Assertion(pid: 301, onBehalfOf: nil, type: "PreventUserIdleDisplaySleep")
        let webKit = MediaPlayback.Assertion(pid: 400, onBehalfOf: 250, type: "PreventUserIdleDisplaySleep")
        let pids = MediaPlayback.playingPIDs([helper, webKit], parent: { $0 == 301 ? 200 : 1 })
        #expect(pids.isSuperset(of: [200, 250, 301, 400]))
        #expect(!pids.contains(1))  // launchd is nobody's player
    }

    @Test func coveringWindowsNameTheFrontmostFullScreenWindow() {
        let display = FullScreenRules.Display(id: 1, bounds: CGRect(x: 0, y: 0, width: 1470, height: 956))
        let behind = WindowEntry(id: 11, pid: 201, layer: 0, bounds: display.bounds, title: "")
        let windows = FullScreenRules.coveringWindows(windows: [Self.editor, behind], displays: [display], ownPID: 100)
        #expect(windows[1]?.id == 10)
    }

    /// Charles, 2026-10-14 (a photo: Moku over a cooking reel in a full-screen browser): a browser often holds no
    /// keep-awake lock for a reel, muted ones above all, so the page it's on counts too.
    @Test func aBrowserFullScreenOnAVideoOrReelSiteIsMedia() {
        for page in ["https://www.youtube.com/shorts/abc", "https://m.youtube.com/watch?v=1", "https://www.instagram.com/reels/xyz/",
                     "https://www.netflix.com/watch/1", "https://www.primevideo.com/detail/x", "https://www.hotstar.com/in/shows/x",
                     "https://www.twitch.tv/someone", "https://vimeo.com/123", "https://www.tiktok.com/@a/video/1", "https://youtu.be/x"] {
            #expect(MediaPlayback.isMediaPage(page), "\(page)")
        }
        for page in ["https://docs.google.com/document/d/1", "https://github.com/x/y", "https://notyoutube.com/", "https://www.figma.com/file/1", "not a url"] {
            #expect(!MediaPlayback.isMediaPage(page), "\(page)")
        }
    }
}
