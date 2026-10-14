import CoreGraphics
import Foundation

/// Identifies one window across samples.
struct WindowKey: Hashable, Sendable {
    var pid: pid_t
    var windowID: CGWindowID
}

/// Decides when the focused window must be read again by OCR. A different window is read at once.
/// The same window is read again only when its content visibly changed, and at most every `gap`
/// seconds: OCR of a full Retina window costs about 80–100 ms of CPU. While the picture keeps changing
/// but the words do not (a video, an animation), the gap doubles up to 30 seconds.
struct OCRPolicy: Sendable {
    static let minimumGap: TimeInterval = 9
    static let maximumGap: TimeInterval = 30

    private(set) var window: WindowKey?
    private var baseline: ContentFingerprint?
    private var lastReadAt: TimeInterval = -.infinity
    private var lastTextHash: String?
    private(set) var gap = minimumGap

    func shouldRead(window: WindowKey, fingerprint: ContentFingerprint?, now: TimeInterval) -> Bool {
        guard window == self.window, let baseline, let fingerprint else { return true }
        if fingerprint.isSimilar(to: baseline) { return false }
        return now - lastReadAt >= gap
    }

    mutating func didRead(window: WindowKey, fingerprint: ContentFingerprint?, textHash: String, now: TimeInterval) {
        if window == self.window, textHash == lastTextHash {
            gap = min(gap * 2, Self.maximumGap)
        } else {
            gap = Self.minimumGap
        }
        self.window = window
        baseline = fingerprint
        lastReadAt = now
        lastTextHash = textHash
    }

    mutating func reset() {
        self = OCRPolicy()
    }

    /// Whether the app's windows are read by OCR at all. Video and music players aren't: their words are subtitles and
    /// lyrics that change every few seconds, so OCR ran at every chance and each new line made a new screen to judge,
    /// while the app and the window title already say what's playing (2026-10-02: hours of VLC).
    static func reads(bundleId: String) -> Bool { !mediaPlayers.contains(bundleId) }

    static let mediaPlayers: Set<String> = [
        "org.videolan.vlc", "com.colliderli.iina", "io.mpv", "com.apple.QuickTimePlayerX", "com.apple.TV",
        "com.firecore.infuse", "com.movist.MovistPro", "com.Eltima.ElmediaPlayer", "tv.plex.desktop",
        "com.netflix.Netflix", "com.amazon.aiv.AIVApp", "com.disney.disneyplus",
        "com.apple.Music", "com.spotify.client", "com.apple.podcasts",
    ]
}

/// Apps and pages whose words Moku never reads or sends: password managers, authenticators and wallets, where a
/// revealed password, a one-time code or a recovery phrase can be on screen. Their window titles (which can name an
/// item) are blanked too; Moku still knows which app is in front. (Dayflow's code had such a list; Moku had none.)
public enum SensitiveScreens {
    public static let apps: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.apple.Passwords", "com.apple.keychainaccess", "com.bitwarden.desktop", "com.lastpass.LastPass",
        "org.keepassxc.keepassxc", "com.markmcguill.strongbox.mac", "in.sinew.Enpass-Desktop", "me.proton.pass.electron",
        "com.nordsec.nordpass", "com.authy.authy-mac", "com.ledger.live", "io.trezor.TrezorSuite", "com.electron.exodus",
    ]
    public static let hosts: [String] = [
        "1password.com", "vault.bitwarden.com", "passwords.google.com", "lastpass.com", "proton.me/pass", "app.dashlane.com",
    ]
    public static func contains(bundleId: String, url: String?) -> Bool {
        if apps.contains(bundleId) { return true }
        guard let url = url?.lowercased() else { return false }
        let address = url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        return hosts.contains { address.hasPrefix($0) || address.contains("." + $0) }
    }
}
