import AppKit
import SwiftUI
import MokuKit

/// Launch QA, lens 1: what a brand-new person meets, offscreen. `--firstuse <dir>` writes pictures and `firstuse.json`, and
/// throws when something a first day depends on is wrong: a window too tall for its screen, quiet text below WCAG AA, a name the
/// brain would refuse. (VoiceOver names are checked in code: FirstUseTests.everyIconControlAndFieldNamesItself; a SwiftUI
/// view's accessibility tree can't be read reliably offscreen.) Nothing is saved: the welcome here never remembers, and the
/// companion stays in memory.
extension MokuVisualDiagnostics {
    @MainActor static func png(_ view: NSView, to url: URL, appearance: NSAppearance? = nil) throws {
        if let appearance { view.appearance = appearance }
        try NSBitmapImageRep(cgImage: ReviewCapture.view(view)).representation(using: .png, properties: [:])!.write(to: url)
    }

    public static func firstUseCheck(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var report: [String: Any] = [:], problems: [String] = []
        let screen = NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let companions = Companion.available

        // 1. Names (#13): the Mac gives a very long, empty, emoji, right-to-left, CJK or titled name. The greeting, the window's
        // size on a tall and a short screen, and what the brain would be told.
        let names: [(String, String)] = [("normal", "Charles"), ("empty", ""), ("blank", "   "), ("long", String(repeating: "Wolfeschlegelsteinhausenbergerdorff ", count: 4)),
                                         ("emoji", String(repeating: "🦊", count: 70)), ("rtl", "مرحبا بالعالم الجميل جدا"), ("cjk", "山田太郎"), ("title", "Dr.")]
        var nameRows: [[String: Any]] = []
        for companion in companions {
            for (key, name) in names {
                let model = OnboardingModel(); model.suggestedName = name; model.companion = companion; model.choosing = Companion.hasChoice; model.greetedAt = .distantPast
                var sizes: [String: Double] = [:]
                for (screenName, visible) in [("tall", screen), ("short", CGRect(x: 0, y: 0, width: 1280, height: 640))] {
                    let size = MokuOnboardingPresenter.size(for: model, visible: visible)
                    sizes[screenName] = size.height
                    if size.height > max(480, visible.height - 24) { problems.append("welcome \(key) \(companion.rawValue): \(size.height) tall on a \(visible.height) screen") }
                }
                if model.resultName.utf16.count > PersonName.maxUTF16 { problems.append("name \(key): \(model.resultName.utf16.count) UTF-16 units, the brain takes \(PersonName.maxUTF16)") }
                nameRows.append(["companion": companion.rawValue, "name": key, "greeting": model.greeting, "sent": model.resultName, "units": model.resultName.utf16.count, "height": sizes])
                if ["long", "emoji", "rtl"].contains(key) {
                    let size = MokuOnboardingPresenter.size(for: model, visible: screen)
                    let card = NSHostingView(rootView: OnboardingView(model: model, size: size)); card.frame.size = size
                    try await Task.sleep(for: .milliseconds(100))
                    try png(card, to: directory.appendingPathComponent("name-\(key)-\(companion.rawValue).png"))
                }
            }
        }
        report["names"] = nameRows

        // 2. Permissions (#8): each state the welcome can be in, drawn; none, Accessibility only, Screen Recording only, both,
        // asked and denied, and revoked after being on.
        let states: [(String, PermissionStatus, Set<PermissionKind>)] = [
            ("none", PermissionStatus(accessibility: false, screenRecording: false), []),
            ("accessibility", PermissionStatus(accessibility: true, screenRecording: false), [.accessibility]),
            ("screen", PermissionStatus(accessibility: false, screenRecording: true), [.screenRecording]),
            ("both", PermissionStatus(accessibility: true, screenRecording: true), [.accessibility, .screenRecording]),
            ("denied", PermissionStatus(accessibility: false, screenRecording: false), [.accessibility, .screenRecording]),
        ]
        var stateRows: [[String: Any]] = []
        for (name, status, asked) in states {
            let model = OnboardingModel(); model.suggestedName = "Riley"; model.choosing = Companion.hasChoice; model.permissions = status; model.asked = asked; model.page = .read; model.readStartedAt = .distantPast; model.readStep = 4
            let size = MokuOnboardingPresenter.size(for: model, visible: screen)
            let card = NSHostingView(rootView: OnboardingView(model: model, size: size)); card.frame.size = size
            try await Task.sleep(for: .milliseconds(100))
            try png(card, to: directory.appendingPathComponent("permissions-\(name).png"))
            stateRows.append(["state": name, "reopenShown": model.waitingForReopen])
        }
        // Revoked mid-session: the welcome's poll turns a granted row back into an Allow button.
        let revoked = OnboardingModel(); revoked.permissions = PermissionStatus(accessibility: true, screenRecording: true); revoked.asked = [.accessibility, .screenRecording]
        revoked.permissions = PermissionStatus(accessibility: false, screenRecording: true)
        stateRows.append(["state": "revoked", "reopenShown": revoked.waitingForReopen, "accessibilityBackToAllow": !revoked.permissions.accessibility])
        report["permissions"] = stateRows

        // 3. A brand-new person's popover and Your day (nothing built yet), the popover without Accessibility, and each Settings page.
        let welcome = OnboardingModel(); welcome.suggestedName = "Riley"; welcome.choosing = Companion.hasChoice
        let welcomeSize = MokuOnboardingPresenter.size(for: welcome, visible: screen)
        VisualSessionState.shared.workState = .focused
        let scene = HomeScene(); scene.open(points: 0)
        while !scene.hasFrame && scene.error == nil { try await Task.sleep(for: .milliseconds(100)) }
        let popoverView = NSHostingView(rootView: HomeView(model: WorldModel(snapshot: .empty), state: ForestPresentation(), scene: scene)); popoverView.frame = CGRect(x: 0, y: 0, width: 370, height: HomeView.height)
        try await Task.sleep(for: .milliseconds(400))
        try png(popoverView, to: directory.appendingPathComponent("popover-empty.png"))
        let blind = ForestPresentation(); blind.permissions = PermissionStatus(accessibility: false, screenRecording: false)
        let blindView = NSHostingView(rootView: HomeView(model: WorldModel(snapshot: .empty), state: blind, scene: scene)); blindView.frame = popoverView.frame
        try png(blindView, to: directory.appendingPathComponent("popover-empty-no-accessibility.png"))
        // Day 22: the trial has ended and the relay refuses this Mac. The popover says so plainly and points at Settings.
        let ended = ForestPresentation(); ended.thinking = .accessRefused
        let endedView = NSHostingView(rootView: HomeView(model: WorldModel(snapshot: .empty), state: ended, scene: scene)); endedView.frame = popoverView.frame
        try png(endedView, to: directory.appendingPathComponent("popover-trial-ended.png"))
        let day = TodayModel()
        day.summary = TodaySummary(date: TodayModel.key(Date()), note: nil, focusedMinutes: 0, longestFocusMinutes: 0, returns: 0, unitsToday: 0, segments: [], built: [], wandered: [], quickCheckMinutes: 0, comebacks: [], bestComeback: nil, completions: [])
        let todayView = NSHostingView(rootView: TodayView(model: day, scene: scene, world: WorldModel(snapshot: .empty))); todayView.frame = CGRect(x: 0, y: 0, width: 1120, height: 760)
        try await Task.sleep(for: .milliseconds(300))
        try png(todayView, to: directory.appendingPathComponent("today-empty-\(Companion.current.rawValue).png"))
        scene.close()
        let settings = SettingsModel(); settings.config = .standard; settings.permissions = PermissionStatus(accessibility: false, screenRecording: false); settings.access = AccessStatus(plan: .trial, expiresAt: Date().addingTimeInterval(20 * 86_400))
        for tab in SettingsTab.allCases {
            let page = NSHostingView(rootView: tab.view(settings)); page.frame.size = page.fittingSize
            try png(page, to: directory.appendingPathComponent("settings-\(tab.title.lowercased().replacingOccurrences(of: " & ", with: "-").replacingOccurrences(of: " ", with: "-")).png"))
        }

        // 4. Increase Contrast (#15): the welcome and the popover drawn with the system's high contrast appearance, and the
        // contrast ratios of the quiet text in both.
        let high = NSAppearance(named: .accessibilityHighContrastAqua)
        try png(NSHostingView(rootView: OnboardingView(model: welcome, size: welcomeSize)).sized(welcomeSize), to: directory.appendingPathComponent("welcome-increased-contrast.png"), appearance: high)
        try png(NSHostingView(rootView: HomeView(model: WorldModel(snapshot: .empty), state: ForestPresentation(), scene: HomeScene())).sized(CGSize(width: 370, height: HomeView.height)), to: directory.appendingPathComponent("popover-increased-contrast.png"), appearance: high)
        report["quietContrast"] = ["secondary": Quiet.contrast(.secondary), "dimmed": Quiet.contrast(.dimmed), "secondaryIncreased": Quiet.contrast(.secondary, increased: true), "dimmedIncreased": Quiet.contrast(.dimmed, increased: true)]
        if Quiet.contrast(.secondary) < 4.5 { problems.append("quiet text is \(Quiet.contrast(.secondary)):1 on the paper, WCAG AA is 4.5:1") }
        report["reduceMotionNow"] = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        report["problems"] = problems
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("firstuse.json"))
        DotsCache.release()
        guard problems.isEmpty else { throw NSError(domain: "First use", code: 1, userInfo: [NSLocalizedDescriptionKey: problems.joined(separator: "; ")]) }
    }
}

private extension NSView {
    func sized(_ size: CGSize) -> Self { frame = CGRect(origin: .zero, size: size); return self }
}
