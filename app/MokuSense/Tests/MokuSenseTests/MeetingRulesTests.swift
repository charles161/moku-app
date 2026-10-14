import MokuKit
import Testing
@testable import MokuSense

@Suite struct MeetingRulesTests {
    func context(mic: Bool = false, camera: Bool = false, running: Set<String> = [],
                 windows: [TitledWindow] = [], url: String? = nil, front: String? = nil) -> MeetingContext {
        MeetingRules.context(from: MeetingEvidence(micInUse: mic, cameraInUse: camera, runningBundleIds: running,
                                                   windows: windows, focusedURL: url, focusedBundleId: front))
    }

    @Test func aCallLastsWhileTheMicStaysLiveEvenAwayFromItsTab() {
        let meet = context(mic: true, running: ["com.google.Chrome"], url: "https://meet.google.com/abc-defg-hij")
        #expect(meet.inCall)
        // Switched to another tab: no call surface in sight, but the mic is still live.
        let elsewhere = MeetingEvidence(micInUse: true, runningBundleIds: ["com.google.Chrome"], focusedURL: "https://github.com")
        #expect(MeetingRules.context(from: elsewhere, previous: meet).inCall)
        // Hung up: the mic goes quiet, and that's the end of it.
        let hungUp = MeetingEvidence(runningBundleIds: ["com.google.Chrome"], focusedURL: "https://github.com")
        #expect(!MeetingRules.context(from: hungUp, previous: meet).inCall)
        // Dictation that never started as a call still isn't one.
        #expect(!MeetingRules.context(from: elsewhere, previous: .none).inCall)
    }

    @Test func whatsAppAndTelegramCallsAreCalls() {
        let running: Set<String> = ["net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "com.electron.wispr-flow"]
        // A voice call with the call window in front; a video call wherever the window is.
        #expect(context(mic: true, running: running, front: "net.whatsapp.WhatsApp").inCall)
        #expect(context(mic: true, running: running, front: "ru.keepcoder.Telegram").inCall)
        #expect(context(mic: true, camera: true, running: running, front: "com.apple.Safari").inCall)
        // Running all day: with nothing live, or dictating somewhere else, it's no call.
        #expect(!context(running: running, front: "net.whatsapp.WhatsApp").inCall)
        #expect(!context(mic: true, running: running, front: "com.apple.dt.Xcode").inCall)
    }

    @Test func nothingLiveIsNoCall() {
        #expect(context() == .none)
    }

    @Test func micAloneIsNotACall() {
        // Dictation, a voice memo: the mic is live but nothing holds a call.
        let result = context(mic: true, running: ["com.apple.Notes", "com.electron.wispr-flow"])
        #expect(!result.inCall)
        #expect(result.micInUse)
    }

    @Test func idleCallAppIsNotACall() {
        #expect(!context(running: ["us.zoom.xos"]).inCall)
    }

    /// The 2026-09-28 audit: dictating with Zoom, Discord or FaceTime just running hid Moku as if in a call.
    @Test func dictationWithACallAppJustRunningIsNotACall() {
        let running: Set<String> = ["us.zoom.xos", "com.hnc.Discord", "com.apple.FaceTime", "com.electron.wispr-flow"]
        let zoomHome = TitledWindow(bundleId: "us.zoom.xos", title: "Zoom Workplace")
        #expect(!context(mic: true, running: running, windows: [zoomHome], front: "com.apple.dt.Xcode").inCall)
        #expect(!context(mic: true, running: running, front: "com.apple.Notes").inCall)
    }

    @Test func aCallAppInFrontOrShowingACallIsACall() {
        #expect(context(mic: true, running: ["us.zoom.xos"], front: "us.zoom.xos").inCall)
        #expect(context(mic: true, running: ["com.hnc.Discord"], front: "com.hnc.Discord").inCall)
        // Zoom's meeting window says so, even behind the editor.
        let meeting = TitledWindow(bundleId: "us.zoom.xos", title: "Zoom Meeting")
        #expect(context(mic: true, running: ["us.zoom.xos"], windows: [meeting], front: "com.apple.dt.Xcode").inCall)
        // Dictation never turns the camera on: the camera live while a call app runs is a call.
        #expect(context(camera: true, running: ["com.apple.FaceTime"]).inCall)
    }

    @Test func chatAppsNeedACallWindow() {
        let slackChat = TitledWindow(bundleId: "com.tinyspeck.slackmacgap", title: "general (Channel) - Lightslips - Slack")
        let slackHuddle = TitledWindow(bundleId: "com.tinyspeck.slackmacgap", title: "Huddle: #general - Lightslips")
        let teamsChat = TitledWindow(bundleId: "com.microsoft.teams2", title: "Chat | Microsoft Teams")
        let teamsMeeting = TitledWindow(bundleId: "com.microsoft.teams2", title: "Meeting with Priya | Microsoft Teams")
        let running: Set<String> = ["com.tinyspeck.slackmacgap", "com.microsoft.teams2"]
        #expect(!context(mic: true, running: running, windows: [slackChat, teamsChat]).inCall)
        #expect(context(mic: true, running: running, windows: [slackChat, slackHuddle]).inCall)
        #expect(context(mic: true, running: running, windows: [teamsMeeting]).inCall)
    }

    @Test func browserMeetingTabsAreCalls() {
        let meet = TitledWindow(bundleId: "com.google.Chrome", title: "Meet - abc-defg-hij")
        let teamsWeb = TitledWindow(bundleId: "com.microsoft.edgemac", title: "Meeting with Sam | Microsoft Teams")
        let docs = TitledWindow(bundleId: "com.google.Chrome", title: "Meet the team - Google Docs")
        #expect(context(mic: true, windows: [meet]).inCall)
        #expect(context(camera: true, windows: [teamsWeb]).inCall)
        #expect(!context(mic: true, windows: [docs]).inCall)
        #expect(!context(windows: [meet]).inCall, "a Meet tab with no live mic or camera is not a call")
    }

    @Test func focusedMeetingAddressIsACall() {
        #expect(context(mic: true, url: "https://meet.google.com/abc-defg-hij").inCall)
        #expect(context(mic: true, url: "https://app.zoom.us/wc/123456/join").inCall)
        #expect(context(mic: true, url: "https://teams.microsoft.com/l/meetup-join/19%3ameeting").inCall)
        #expect(!context(mic: true, url: "https://meet.google.com/").inCall)
        #expect(!context(mic: true, url: "https://github.com/lightslips/moku").inCall)
    }

    @Test func sharingIndicatorsMeanSharing() {
        let chromeBar = TitledWindow(bundleId: "com.google.Chrome", title: "meet.google.com is sharing your screen.")
        let zoomBar = TitledWindow(bundleId: "us.zoom.xos", title: "zoom share toolbar window")
        let teamsBar = TitledWindow(bundleId: "com.microsoft.teams2", title: "Sharing control bar | Microsoft Teams")
        let editor = TitledWindow(bundleId: "com.microsoft.VSCode", title: "SenseHub.swift — MokuSense")
        #expect(context(windows: [chromeBar]).sharingScreen)
        #expect(context(windows: [zoomBar]).sharingScreen)
        #expect(context(windows: [teamsBar]).sharingScreen)
        #expect(!context(windows: [editor]).sharingScreen)
    }
}
