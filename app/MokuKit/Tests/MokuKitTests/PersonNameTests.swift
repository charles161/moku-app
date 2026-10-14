import Foundation
import Testing
@testable import MokuKit

/// The first day's names (launch QA, lens 1, parameter 13): from the Mac account or typed, very long, empty, emoji,
/// right to left. The brain refuses an empty name, one past 60 UTF-16 units and one with a tab or line break, and a
/// refused name left the person "friend", so every name is made safe before it goes anywhere.
@Test func aNameIsOneLineTrimmedAndKnowsWhenThereIsNone() {
    #expect(PersonName.clean("Charles") == "Charles")
    #expect(PersonName.clean("  Charles \n") == "Charles")
    #expect(PersonName.clean("Mary\t Ann\nLou") == "Mary Ann Lou")
    #expect(PersonName.clean("") == nil)
    #expect(PersonName.clean("   \n\t ") == nil)
    #expect(PersonName.clean(nil) == nil)
    #expect(PersonName.clean("Bell\u{7}") == "Bell")  // a control character is dropped
}

@Test func aLongNameIsCutToTheBrainsLimitWithoutSplittingACharacter() {
    let latin = PersonName.clean(String(repeating: "a", count: 200))
    #expect(latin?.utf16.count == PersonName.maxUTF16)
    // An emoji is two UTF-16 units: forty of them are 80, so thirty fit, and none is cut in half.
    let foxes = PersonName.clean(String(repeating: "🦊", count: 40))
    #expect(foxes == String(repeating: "🦊", count: 30))
    #expect(foxes?.utf16.count == 60)
    // A family emoji is one character of eleven units: five fit in 60, not six.
    let family = PersonName.clean(String(repeating: "👨‍👩‍👧‍👦", count: 8))
    #expect(family == String(repeating: "👨‍👩‍👧‍👦", count: 5))
    // The cut never leaves a trailing space.
    #expect(PersonName.clean(String(repeating: "a", count: 59) + " bcd") == String(repeating: "a", count: 59))
}

@Test func namesInOtherScriptsPassThrough() {
    #expect(PersonName.clean("مريم") == "مريم")  // right to left
    #expect(PersonName.clean("山田太郎") == "山田太郎")
    #expect(PersonName.clean("Zoë 🌿") == "Zoë 🌿")
    #expect(PersonName.suggestion(fromFullName: "مريم أحمد") == "مريم")
    #expect(PersonName.suggestion(fromFullName: "李 雷") == "李")
}

@Test func theMacAccountsFullNameGivesAFirstNameOrNothing() {
    #expect(PersonName.suggestion(fromFullName: "Charles Joseph") == "Charles")
    #expect(PersonName.suggestion(fromFullName: "Charles") == "Charles")
    #expect(PersonName.suggestion(fromFullName: "  Riley   Park ") == "Riley")
    #expect(PersonName.suggestion(fromFullName: "Dr. Priya Rao") == "Priya")  // not "Hi, Dr.. I'm Moku."
    #expect(PersonName.suggestion(fromFullName: "Mrs Alvarez") == "Alvarez")
    #expect(PersonName.suggestion(fromFullName: "J. Robert Oppenheimer") == "Robert")
    #expect(PersonName.suggestion(fromFullName: "CHARLES JOSEPH") == "Charles")
    #expect(PersonName.suggestion(fromFullName: "McKenzie Lee") == "McKenzie")  // mixed case is left alone
    #expect(PersonName.suggestion(fromFullName: "O'Brien") == "O'Brien")
}

@Test func anAccountWithNoRealNameIsNotCalledByIt() {
    for generic in ["Administrator", "Admin", "User", "Owner", "Guest", "root", "MacBook Pro", "MacBook", "iMac", "", "   ", "Dr."] {
        #expect(PersonName.suggestion(fromFullName: generic) == nil, "\(generic)")
    }
    #expect(PersonName.suggestion(fromFullName: nil) == nil)
}

@Test func aSuggestionIsAlwaysSomethingTheBrainTakes() {
    for full in [String(repeating: "x", count: 500), String(repeating: "🦊", count: 90) + " Fox", "Ana\u{2028}Maria"] {
        let name = PersonName.suggestion(fromFullName: full)
        #expect(name != nil)
        #expect((name?.utf16.count ?? 99) <= PersonName.maxUTF16)
        #expect(name?.contains(where: { $0.isNewline }) == false)
    }
}
