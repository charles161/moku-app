import Testing
@testable import MokuSense

@Suite struct NormalizationTests {
    @Test func titlesDropUnreadCountersAndInvisibleCharacters() {
        #expect(Normalize.title("(3) YouTube") == "YouTube")
        #expect(Normalize.title("(99+) Inbox - sam@example.com - Gmail") == "Inbox - sam@example.com - Gmail")
        #expect(Normalize.title("\u{200E}WhatsApp") == "WhatsApp")
        #expect(Normalize.title("  auth.ts \u{2014}\n  moku   ") == "auth.ts \u{2014} moku")
        #expect(Normalize.title("(3)") == "(3)", "a title that is only a counter keeps it")
        #expect(Normalize.title("Area (2) notes") == "Area (2) notes", "only a leading counter is removed")
    }

    @Test func titlesAreCapped() {
        #expect(Normalize.title(String(repeating: "a", count: 1000)).count == Normalize.maxTitleLength)
    }

    @Test func namesKeepTheirParentheses() {
        #expect(Normalize.name("\u{200E}WhatsApp ") == "WhatsApp")
        #expect(Normalize.name("(3) Notes") == "(3) Notes")
    }

    @Test func urlsDropTrackingAndCredentials() {
        #expect(Normalize.url("https://example.com/post?id=7&utm_source=x&utm_medium=y&fbclid=abc")
                == "https://example.com/post?id=7")
        #expect(Normalize.url("https://example.com/?utm_campaign=z") == "https://example.com/")
        #expect(Normalize.url("https://user:secret@example.com/private") == "https://example.com/private")
        #expect(Normalize.url("https://mail.google.com/mail/u/0/#inbox") == "https://mail.google.com/mail/u/0/#inbox")
        #expect(Normalize.url("https://www.youtube.com/watch?v=dQw4w9WgXcQ&si=share")
                == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    @Test func urlsHandleOddInput() {
        #expect(Normalize.url(nil) == nil)
        #expect(Normalize.url("   ") == nil)
        #expect(Normalize.url(" about:blank ") == "about:blank")
        #expect(Normalize.url("github.com/lightslips") == "github.com/lightslips", "an address without a scheme is kept as is")
        #expect(Normalize.url("https://example.com/" + String(repeating: "a", count: 5000))?.count == Normalize.maxURLLength)
    }
}
