import CoreGraphics
import Testing
@testable import MokuSense

@Suite struct OCRPolicyTests {
    let windowA = WindowKey(pid: 10, windowID: 1)
    let windowB = WindowKey(pid: 10, windowID: 2)
    let screen = ContentFingerprint(image: TestImages.window(showing: TestImages.code, width: 720, height: 450))!
    let otherScreen = ContentFingerprint(image: TestImages.window(showing: TestImages.otherCode, width: 720, height: 450))!

    @Test func readsANewWindowAndSkipsAnUnchangedOne() {
        var policy = OCRPolicy()
        #expect(policy.shouldRead(window: windowA, fingerprint: screen, now: 0))
        policy.didRead(window: windowA, fingerprint: screen, textHash: "a", now: 0)
        #expect(!policy.shouldRead(window: windowA, fingerprint: screen, now: 30), "unchanged content is never read again")
        #expect(policy.shouldRead(window: windowB, fingerprint: screen, now: 3), "another window is read at once")
        #expect(policy.shouldRead(window: windowA, fingerprint: nil, now: 3), "no fingerprint, no shortcut")
    }

    @Test func readsChangedContentAtMostEveryGap() {
        var policy = OCRPolicy()
        policy.didRead(window: windowA, fingerprint: screen, textHash: "a", now: 0)
        #expect(!policy.shouldRead(window: windowA, fingerprint: otherScreen, now: 3), "too soon after the last read")
        #expect(policy.shouldRead(window: windowA, fingerprint: otherScreen, now: OCRPolicy.minimumGap))
    }

    @Test func backsOffWhileThePictureChangesButTheWordsDoNot() {
        var policy = OCRPolicy()
        var reads = 0
        // A video: every capture looks different, the text never changes.
        for tick in 0..<40 {
            let now = Double(tick) * 3
            let fingerprint = tick.isMultiple(of: 2) ? screen : otherScreen
            if policy.shouldRead(window: windowA, fingerprint: fingerprint, now: now) {
                reads += 1
                policy.didRead(window: windowA, fingerprint: fingerprint, textHash: "same words", now: now)
            }
        }
        #expect(reads <= 7, "two minutes of a video should need only a few reads, got \(reads)")
        #expect(policy.gap == OCRPolicy.maximumGap)
    }

    @Test func neverReadsMediaPlayers() {
        #expect(!OCRPolicy.reads(bundleId: "org.videolan.vlc"), "subtitles change every few seconds")
        #expect(!OCRPolicy.reads(bundleId: "com.spotify.client"), "so do lyrics")
        #expect(OCRPolicy.reads(bundleId: "com.todesktop.230313mzl4w4u92"), "an editor is read")
        #expect(OCRPolicy.reads(bundleId: "com.google.Chrome"), "a browser is read")
    }

    @Test func neverReadsPasswordManagersOrVaultPages() {
        #expect(SensitiveScreens.contains(bundleId: "com.1password.1password", url: nil))
        #expect(SensitiveScreens.contains(bundleId: "com.apple.Passwords", url: nil))
        #expect(SensitiveScreens.contains(bundleId: "com.google.Chrome", url: "https://vault.bitwarden.com/#/vault"))
        #expect(SensitiveScreens.contains(bundleId: "com.google.Chrome", url: "https://my.1password.com/vaults"))
        #expect(!SensitiveScreens.contains(bundleId: "com.google.Chrome", url: "https://github.com/1password"))
        #expect(!SensitiveScreens.contains(bundleId: "com.todesktop.230313mzl4w4u92", url: nil))
    }

    @Test func newWordsResetTheGap() {
        var policy = OCRPolicy()
        policy.didRead(window: windowA, fingerprint: screen, textHash: "a", now: 0)
        policy.didRead(window: windowA, fingerprint: otherScreen, textHash: "a", now: 9)
        #expect(policy.gap == OCRPolicy.minimumGap * 2)
        policy.didRead(window: windowA, fingerprint: screen, textHash: "b", now: 27)
        #expect(policy.gap == OCRPolicy.minimumGap)
    }
}
