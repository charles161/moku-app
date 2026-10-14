import Testing
@testable import MokuSense

@Suite struct TextDigestTests {
    @Test func shortTextIsUntouched() {
        #expect(TextDigest.capped("hello") == "hello")
        let exact = String(repeating: "a", count: TextDigest.maxLength)
        #expect(TextDigest.capped(exact) == exact)
    }

    @Test func longTextIsCappedAtFourThousand() {
        let long = String(repeating: "abcdefghij", count: 1000)
        let capped = TextDigest.capped(long)
        #expect(capped.utf16.count == 4000)
        #expect(long.hasPrefix(capped))
    }

    @Test func cappingNeverSplitsACharacter() {
        // Each family emoji is 11 UTF-16 units; 3999 + 11 would overflow, so it is dropped whole.
        let text = String(repeating: "a", count: 3999) + "👨‍👩‍👧‍👦" + "tail"
        let capped = TextDigest.capped(text)
        #expect(capped == String(repeating: "a", count: 3999))
        #expect(capped.utf16.count <= TextDigest.maxLength)
    }

    @Test func hashIsSHA256OfTheFullText() {
        #expect(TextDigest.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let long = String(repeating: "x", count: 5000)
        let longer = long + "y"
        #expect(TextDigest.sha256(long) != TextDigest.sha256(longer), "the hash covers text beyond the cap")
        #expect(TextDigest.sha256(long).count == 64)
    }
}
