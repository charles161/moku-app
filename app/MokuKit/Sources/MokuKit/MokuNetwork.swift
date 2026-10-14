import Foundation

/// The one URLSession for Moku's own calls: the brain on 127.0.0.1, the relay and PostHog. It keeps nothing, on disk or
/// in memory. `URLSession.shared` saved every brain answer in ~/Library/Caches/ai.lightslips.moku/Cache.db (macOS
/// counted 2.1 GB written in 18 hours, 2026-10-10; 300 fresh answers of 120 KB wrote 36 MB there, none with this
/// session) and kept the relay's install answer, token and all, in plain text.
public enum MokuNetwork {
    public static let session = URLSession(configuration: configuration)

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    /// Clears what `URLSession.shared` saved before (brain answers, the relay's install answer with its token). Cheap, so
    /// every launch does it: Sparkle's appcast is all that lands there now, and it's fetched afresh anyway.
    public static func forgetSharedCache() {
        URLCache.shared.removeAllCachedResponses()
    }
}
