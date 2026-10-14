import AppKit
import Foundation
import Testing
import MokuKit
@testable import MokuVisual

/// Settings › Privacy › "Apps Moku never watches" (Charles, 2026-10-08): the person picks any number of apps; the list is
/// kept on this Mac, and the senses read it (MokuSense stops reading an app on it).
@MainActor @Suite struct IgnoredAppsSettingsTests {
    private func model() -> (SettingsModel, UserDefaults) {
        let name = "IgnoredAppsSettingsTests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        let model = SettingsModel()
        model.preferences = store
        model.ignoredApps = IgnoredApps.load(from: store).apps
        return (model, store)
    }

    @Test func anAppBundleGivesItsIdAndItsName() {
        let calculator = IgnoredAppPicker.app(at: URL(fileURLWithPath: "/System/Applications/Calculator.app"))
        #expect(calculator?.bundleId == "com.apple.calculator")
        #expect(calculator?.name == "Calculator")
        #expect(IgnoredAppPicker.app(at: URL(fileURLWithPath: "/System/Applications/NotThere.app")) == nil)
        #expect(IgnoredAppPicker.app(at: URL(fileURLWithPath: "/usr/bin")) == nil)  // a folder with no bundle id
    }

    @Test func severalAppsPickedAtOnceAreKeptAndSaved() {
        let (model, store) = model()
        var events: [(String, [String: UsageValue])] = []
        model.track = { name, props in events.append((name, props)) }
        model.addIgnored([IgnoredApp(bundleId: "com.apple.MobileSMS", name: "Messages"),
                          IgnoredApp(bundleId: "com.apple.calculator", name: "Calculator"),
                          IgnoredApp(bundleId: "com.apple.mobilesms", name: "Messages")])  // the same app twice
        #expect(model.ignoredApps.map(\.name) == ["Messages", "Calculator"])
        #expect(IgnoredApps.load(from: store).apps == model.ignoredApps)
        #expect(events.count == 1 && events.first?.1["key"] == .word("ignored_apps") && events.first?.1["turned"] == .word("on"),
                "one change, said by its name only: never which app")
    }

    @Test func removingAnAppStopsIgnoringIt() {
        let (model, store) = model()
        model.addIgnored([IgnoredApp(bundleId: "com.apple.MobileSMS", name: "Messages"), IgnoredApp(bundleId: "com.apple.calculator", name: "Calculator")])
        model.removeIgnored(bundleId: "com.apple.MobileSMS")
        #expect(model.ignoredApps.map(\.name) == ["Calculator"])
        #expect(!IgnoredApps.load(from: store).contains(bundleId: "com.apple.MobileSMS"))
        model.removeIgnored(bundleId: "com.apple.calculator")
        #expect(store.object(forKey: IgnoredApps.key) == nil)
    }

    @Test func nothingNewPickedSaysNothing() {
        let (model, _) = model()
        var events = 0
        model.track = { _, _ in events += 1 }
        model.addIgnored([])
        model.addIgnored([IgnoredApp(bundleId: "ai.lightslips.moku", name: "Moku")])
        #expect(events == 0 && model.ignoredApps.isEmpty)
    }

    /// The friends (2026-10-14): each app either only hides Moku (its work still counts) or also isn't watched.
    @Test func eachAppChoosesHideOrHideAndDontWatch() {
        let (model, store) = model()
        var events: [(String, [String: UsageValue])] = []
        model.track = { name, props in events.append((name, props)) }
        model.addIgnored([IgnoredApp(bundleId: "com.figma.Desktop", name: "Figma")])
        #expect(!IgnoredApps.load(from: store).ignores(bundleId: "com.figma.Desktop"), "a new app only hides Moku")
        model.setKeepsWatching(false, bundleId: "com.figma.Desktop")
        #expect(IgnoredApps.load(from: store).ignores(bundleId: "com.figma.Desktop"))
        #expect(model.ignoredApps.first?.keepsWatching == false)
        #expect(events.last?.1["key"] == .word("ignored_apps_watch") && events.last?.1["turned"] == .word("off"),
                "said by its name only: never which app")
    }
}
