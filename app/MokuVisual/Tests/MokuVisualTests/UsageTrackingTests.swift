import Foundation
import Testing
import MokuKit
@testable import MokuMind
@testable import MokuVisual

/// Settings' usage events: a setting's name when it changes, and a permission turned on from Settings.
@MainActor
@Suite("Settings: usage events")
struct SettingsUsageTests {
    @MainActor final class Recorded { var events: [(name: String, props: [String: UsageValue])] = [] }

    func model(_ recorded: Recorded) -> SettingsModel {
        let model = SettingsModel()
        model.track = { [recorded] name, props in recorded.events.append((name, props)) }
        return model
    }

    @Test func aSavedChangeNamesOnlyTheSettingsThatChanged() async {
        let recorded = Recorded(), settings = model(recorded)
        settings.config = .standard
        settings.saveConfig = { patch in
            var config = CompanionConfig.standard
            config.drinkEverySec = patch.drinkEverySec ?? config.drinkEverySec
            return config
        }
        settings.setDrink(25)
        for _ in 0..<200 where recorded.events.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(recorded.events.map(\.name) == ["setting_changed"])
        #expect(recorded.events.first?.props == ["key": .word("drink_every_sec")])
        let patch = CompanionConfigPatch(drinkEverySec: 0, teaBreakMaxSec: CompanionConfig.standard.teaBreakMaxSec, userName: "Riley")
        #expect(patch.changedKeys(from: .standard) == ["user_name", "drink_every_sec"])
        #expect(patch.changedKeys(from: nil) == ["user_name", "drink_every_sec", "tea_break_max_sec"])
    }

    @Test func turningWaterOrBreaksOffOrOnSaysSoButNeverTheMinutes() async {
        let recorded = Recorded(), settings = model(recorded)
        settings.config = .standard
        var served = CompanionConfig.standard
        settings.saveConfig = { patch in
            served.drinkEverySec = patch.drinkEverySec ?? served.drinkEverySec
            served.breakAfterSec = patch.breakAfterSec ?? served.breakAfterSec
            return served
        }
        settings.setDrinkOn(false)
        for _ in 0..<200 where recorded.events.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        settings.setBreakAfter(40)
        for _ in 0..<200 where recorded.events.count < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(recorded.events.map(\.props) == [["key": .word("drink_every_sec"), "turned": .word("off")], ["key": .word("break_after_sec")]])
        #expect(CompanionConfigPatch(drinkEverySec: 1800).turned("drink_every_sec", from: served) == true)
        #expect(CompanionConfigPatch(breakAfterSec: 0).turned("break_after_sec", from: .standard) == false)
        #expect(CompanionConfigPatch(userName: "Riley").turned("user_name", from: .standard) == nil)
        // Settings' tabs are words the usage schema takes.
        guard case let .word(tabs)? = UsageEvents.schema["settings_opened"]?["tab"] else { Issue.record("settings_opened.tab"); return }
        #expect(Set(SettingsTab.allCases.map(\.usageWord)) == tabs)
    }

    @Test func aSettingIsKeptOrChangedBackAndOnlyItsNameAndSecondsSay() async {
        var outcomes: [(String, String, Int)] = []
        let watch = SettingOutcomes(keptAfter: .milliseconds(60)) { key, outcome, seconds in outcomes.append((key, outcome, seconds)) }
        let now = Date()
        watch.changed("size", from: "1.0", to: "0.75", now: now)
        watch.changed("size", from: "0.75", to: "0.5", now: now.addingTimeInterval(3))   // still changing: keeps waiting
        watch.changed("size", from: "0.5", to: "1.0", now: now.addingTimeInterval(8))    // back where it was
        watch.changed("companion", from: "moku", to: "tetsu", now: now)
        for _ in 0..<100 where outcomes.count < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(outcomes.map(\.0) == ["size", "companion"])
        #expect(outcomes.map(\.1) == ["changed_back", "kept"] && outcomes.first?.2 == 8)
    }

    @Test func aPermissionTurnedOnWhileSettingsIsOpenIsAnAnswerFromSettings() {
        let recorded = Recorded(), settings = model(recorded)
        var status = PermissionStatus(accessibility: false, screenRecording: false)
        settings.permissionStatus = { status }
        settings.refreshPermissions(whileOpen: true)  // the first read is where things stand, not an answer
        status.screenRecording = true
        settings.refreshPermissions(whileOpen: true)  // back from System Settings with the switch on
        status.accessibility = true
        settings.refreshPermissions(whileOpen: false)  // turned on while Settings was closed: not from here
        status.accessibility = false; settings.refreshPermissions(whileOpen: true)  // turned off: not an answer
        #expect(recorded.events.map(\.name) == ["permission_answered"])
        #expect(recorded.events.first?.props == ["kind": .word("screen"), "granted": .bool(true), "where": .word("settings")])
    }
}

/// The popover's controls and the menu bar icon's right-click menu: one list of actions, each sent as `popover_action`
/// with a word the usage schema takes.
@MainActor
@Suite("The popover: usage events")
struct PopoverUsageTests {
    @Test func everyActionIsAWordTheUsageSchemaTakes() throws {
        let shapes = try #require(UsageEvents.schema["popover_action"])
        guard case let .word(actions)? = shapes["action"], case let .word(places)? = shapes["from"] else {
            Issue.record("popover_action takes something other than words"); return
        }
        #expect(Set(HomeAction.allCases.map(\.rawValue)) == actions)
        #expect(places == ["popover", "menu"])
    }

    @Test func threeDotsHoldEverythingTheThreeControlsDontOnceWithQuitLast() {
        let controls: Set<HomeAction> = [.takeBreak, .hide, .show, .settings]
        let more = HomeAction.more.flatMap { $0 }
        #expect(more.count == Set(more).count && Set(more).isDisjoint(with: controls))
        #expect(Set(more).union(controls) == Set(HomeAction.allCases))
        #expect(more.last == .quit)
    }

    @Test func theMenuSaysWhatEachDoesWithTheCompanionsName() {
        #expect(HomeAction.takeBreak.title(onBreak: false, name: "Tetsu") == "Take a break")
        #expect(HomeAction.takeBreak.title(onBreak: true, name: "Tetsu") == "End the break")
        #expect(HomeAction.hide.title(onBreak: false, name: "Tetsu") == "Hide Tetsu")
        #expect(HomeAction.putBack.title(onBreak: false, name: "Tetsu") == "Put Tetsu back in the corner")
    }
}

/// Settings opened again (the gear, the companion's menu, moku://settings) reloads what the brain has. A name being typed,
/// not yet saved (it saves on Return or leaving the field), was replaced by the old one.
@MainActor
@Suite("Settings: opening again")
struct SettingsReopenTests {
    @MainActor final class Served { var config = CompanionConfig.standard }

    @Test func openingSettingsAgainKeepsANameBeingTyped() async {
        let served = Served(), settings = SettingsModel()
        served.config.userName = "Charles"
        settings.loadConfig = { [served] in served.config }
        await settings.load()
        #expect(settings.name == "Charles")
        settings.name = "Charlie"  // typing, not saved yet
        await settings.load()      // Settings opened again
        #expect(settings.name == "Charlie")
        settings.name = "Charles"  // typed back as it was
        served.config.userName = "Ada"  // changed elsewhere (the welcome)
        await settings.load()
        #expect(settings.name == "Ada")  // a field left alone follows the brain
    }
}
