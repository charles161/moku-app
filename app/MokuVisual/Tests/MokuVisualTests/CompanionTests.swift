import Foundation
import Testing
import MokuKit
@testable import MokuVisual

@Test func aCompanionsCharacterFilesAreItsOwn() {
    #expect(Companion.moku.resolve("character/moku_bunny.usdz") == "character/moku_bunny.usdz")
    #expect(Companion.moku.resolve("character/anims/wave.usdz") == "character/anims/wave.usdz")
    #expect(Companion.tetsu.resolve("character/moku_bunny.usdz") == "character/tetsu/tetsu.usdz")
    #expect(Companion.tetsu.resolve("character/anims/wave.usdz") == "character/tetsu/anims/wave.usdz")
    #expect(Companion.tetsu.resolve("character/moods.json") == "character/tetsu/moods.json")
    // Shared files, and paths already in a companion's folder (its material rules' textures), stay as they are.
    #expect(Companion.tetsu.resolve("runtime/studio.json") == "runtime/studio.json")
    #expect(Companion.tetsu.resolve("symbols/manifest.json") == "symbols/manifest.json")
    #expect(Companion.tetsu.resolve("character/tetsu/shell.png") == "character/tetsu/shell.png")
}

@MainActor @Test func onlyBundledCompanionsAreOffered() throws {
    CompanionChoice.keepInMemory()
    #expect(Companion.available.first == .moku)
    for companion in Companion.allCases { #expect(Companion.available.contains(companion) == (companion == .moku || companion.isBundled)) }
    #expect(Companion.hasChoice == (Companion.available.count > 1))
    #expect(MokuAssets.file("character/moku_bunny.usdz", companion: .moku) != nil)
    // Someone chosen but missing from this build: Moku shows, and nothing of Moku's stands in for theirs.
    if let missing = Companion.allCases.first(where: { !$0.isBundled }) {
        CompanionChoice.choose(missing)
        #expect(CompanionChoice.chosen == missing && Companion.current == .moku)
        #expect(MokuAssets.file("character/moku_bunny.usdz", companion: missing) == nil)
        if !MokuAssets.exists("world/\(missing.rawValue)/layout.json") { #expect(missing.homeLayoutPath == "world/dayhouse/layout.json" && missing.homeKey == "dayhouse") }
        CompanionChoice.choose(.moku)
        #expect(CompanionChoice.chosen == .moku)
    }
    // Moku keeps its own rules and its own flush.
    #expect(MaterialConfiguration.flushedNames(companion: .moku) == nil)
    #expect(try MaterialConfiguration.load()?.materials.isEmpty == false)
}

@Test func aCompanionsHomeKeepsItsPiecesInItsFolder() throws {
    let slot = { (home: String) in HomeLayout.Slot(asset: "hull", t: [0, 0, 0], q: [0, 0, 0, 1], s: [1, 1, 1], home: home).file }
    #expect(slot("tetsu") == "world/tetsu/hull.usdz")
    #expect(slot("dayhouse") == "world/dayhouse/hull.usdz" && slot("burrow") == "world/home/burrow/hull.usdz")
}

@Test func aHomesNamesNeedEveryStageAndPiece() {
    // Too few names are ignored: the cottage's stay (MokuMind's lines name the next piece through these).
    DayHouse.use(DayHouse.Names(home: "Today’s rocket", stages: ["The pad"], pieces: ["the pad"]))
    #expect(DayHouse.names == DayHouse.cottage)
    #expect(DayHouse.stages.map(\.first) == [0, 4, 8, 14, 18] && DayHouse.stages.first?.name == "The ground")
}

@Test func aHomesNamesReadAsNamesOrStageRecords() throws {
    let records = #"{"home": "Today’s rocket", "stages": [{"name": "The pad", "first": 0}, {"name": "The gantry", "first": 4}], "pieces": ["the chalk ring"], "finished": "Ready."}"#
    let names = try JSONDecoder().decode(HomeLayout.Names.self, from: Data(records.utf8))
    #expect(names.home == "Today’s rocket" && names.stages == ["The pad", "The gantry"] && names.pieces == ["the chalk ring"] && names.finished == "Ready.")
    let plain = try JSONDecoder().decode(HomeLayout.Names.self, from: Data(#"{"stages": ["The pad"], "pieces": 3}"#.utf8))
    #expect(plain.home == nil && plain.stages == ["The pad"] && plain.pieces.isEmpty)
}
