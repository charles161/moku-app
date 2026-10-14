import Foundation
import Testing
@testable import MokuKit

/// Apps Moku never watches (Settings › Privacy, Charles 2026-10-08): the person picks any number of them; a picked app
/// is not read, judged or counted while it's in front. The list is theirs, kept on this Mac.
@Suite struct IgnoredAppsTests {
    static let messages = IgnoredApp(bundleId: "com.apple.MobileSMS", name: "Messages")
    static let signal = IgnoredApp(bundleId: "org.whispersystems.signal-desktop", name: "Signal")

    private func store() -> UserDefaults {
        let name = "IgnoredAppsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func startsEmptyAndWatchesEverything() {
        let list = IgnoredApps.load(from: store())
        #expect(list.apps.isEmpty)
        #expect(!list.contains(bundleId: "com.apple.MobileSMS"))
    }

    @Test func severalAppsCanBePickedAndTheyStayInTheOrderPicked() {
        var list = IgnoredApps()
        do { let added = list.add(Self.signal); #expect(added) }
        do { let added = list.add(Self.messages); #expect(added) }
        #expect(list.apps == [Self.signal, Self.messages])
        #expect(list.contains(bundleId: "com.apple.MobileSMS"))
        #expect(list.contains(bundleId: "org.whispersystems.signal-desktop"))
        #expect(!list.contains(bundleId: "com.apple.Safari"))
    }

    @Test func anAppPickedTwiceIsListedOnce() {
        var list = IgnoredApps()
        do { let added = list.add(Self.messages); #expect(added) }
        do { let added = list.add(IgnoredApp(bundleId: "com.apple.mobilesms", name: "Messages (again)")); #expect(!added) }  // ids match without case
        #expect(list.apps == [Self.messages])
        #expect(list.contains(bundleId: "COM.APPLE.MOBILESMS"))
    }

    @Test func removingOneKeepsTheOthers() {
        var list = IgnoredApps()
        list.add(Self.messages); list.add(Self.signal)
        list.remove(bundleId: "com.apple.mobilesms")
        #expect(list.apps == [Self.signal])
        list.remove(bundleId: "not.there")  // nothing happens
        #expect(list.apps == [Self.signal])
    }

    @Test func mokuItselfAndAnEmptyIdAreNotListed() {
        var list = IgnoredApps()
        do { let added = list.add(IgnoredApp(bundleId: "ai.lightslips.moku", name: "Moku")); #expect(!added) }  // Moku's own windows are never read anyway
        do { let added = list.add(IgnoredApp(bundleId: "  ", name: "Nothing")); #expect(!added) }
        #expect(list.apps.isEmpty)
    }

    @Test func aNameIsKeptEvenWhenTheAppHasNone() {
        var list = IgnoredApps()
        list.add(IgnoredApp(bundleId: "com.example.quiet", name: ""))
        #expect(list.apps.first?.name == "com.example.quiet")
    }

    @Test func theListSurvivesARestart() {
        let defaults = store()
        var list = IgnoredApps()
        list.add(Self.messages); list.add(Self.signal)
        list.save(to: defaults)
        #expect(IgnoredApps.load(from: defaults) == list)
    }

    @Test func savingAnEmptyListClearsTheKey() {
        let defaults = store()
        var list = IgnoredApps()
        list.add(Self.messages); list.save(to: defaults)
        list.remove(bundleId: Self.messages.bundleId); list.save(to: defaults)
        #expect(defaults.object(forKey: IgnoredApps.key) == nil)
    }

    @Test func aDamagedValueMeansNoneIgnoredNotACrash() {
        let defaults = store()
        defaults.set(Data("not json".utf8), forKey: IgnoredApps.key)
        #expect(IgnoredApps.load(from: defaults).apps.isEmpty)
        defaults.set("a string", forKey: IgnoredApps.key)
        #expect(IgnoredApps.load(from: defaults).apps.isEmpty)
    }

    @Test func theListHasALimit() {
        var list = IgnoredApps()
        for number in 0..<(IgnoredApps.limit + 10) { list.add(IgnoredApp(bundleId: "com.example.app\(number)", name: "App \(number)")) }
        #expect(list.apps.count == IgnoredApps.limit)
    }

    // MARK: Hide Moku, or hide and don't watch (the friends, 2026-10-14)

    @Test func aNewAppHidesMokuAndStillCountsTheWork() {
        var list = IgnoredApps()
        list.add(IgnoredApp(bundleId: "com.figma.Desktop", name: "Figma"))
        #expect(list.stepsAside(bundleId: "com.figma.desktop"))
        #expect(!list.ignores(bundleId: "com.figma.Desktop"))
    }

    @Test func anAppCanBeHiddenAndNotWatched() {
        var list = IgnoredApps()
        list.add(IgnoredApp(bundleId: "com.apple.MobileSMS", name: "Messages", keepsWatching: false))
        #expect(list.stepsAside(bundleId: "com.apple.MobileSMS"))
        #expect(list.ignores(bundleId: "com.apple.MobileSMS"))
        list.setKeepsWatching(true, bundleId: "com.apple.mobilesms")
        #expect(!list.ignores(bundleId: "com.apple.MobileSMS"))
        #expect(list.stepsAside(bundleId: "com.apple.MobileSMS"))
    }

    @Test func aListSavedBeforeTheChoiceStillMeansNeverWatch() throws {
        let defaults = store()
        defaults.set(Data(#"[{"bundleId":"com.apple.MobileSMS","name":"Messages"}]"#.utf8), forKey: IgnoredApps.key)
        let list = IgnoredApps.load(from: defaults)
        #expect(list.ignores(bundleId: "com.apple.MobileSMS"))
    }

    @Test func theChoiceIsKept() {
        let defaults = store()
        var list = IgnoredApps()
        list.add(IgnoredApp(bundleId: "com.figma.Desktop", name: "Figma"))
        list.add(IgnoredApp(bundleId: "com.apple.MobileSMS", name: "Messages", keepsWatching: false))
        list.save(to: defaults)
        let again = IgnoredApps.load(from: defaults)
        #expect(!again.ignores(bundleId: "com.figma.Desktop") && again.ignores(bundleId: "com.apple.MobileSMS"))
    }

    /// The senses ask several times a sample; the list is read once, and again only when Settings saves it.
    @MainActor @Test func theCacheFollowsSettings() {
        let defaults = store()
        let cache = IgnoredAppsCache(store: defaults)
        #expect(!cache.list.stepsAside(bundleId: "com.figma.Desktop"))
        var list = IgnoredApps()
        list.add(IgnoredApp(bundleId: "com.figma.Desktop", name: "Figma"))
        list.save(to: defaults)
        #expect(cache.list.stepsAside(bundleId: "com.figma.Desktop"))
    }
}
