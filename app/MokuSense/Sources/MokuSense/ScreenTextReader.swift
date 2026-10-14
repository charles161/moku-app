import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

/// Text of the focused window read by OCR.
struct ScreenText: Sendable, Equatable {
    var text: String
    /// SHA-256 of `text`.
    var hash: String
}

/// Captures only the focused window with ScreenCaptureKit and reads it with Vision. Every sample takes a
/// tiny capture to fingerprint the content; the full-resolution capture and OCR run only when the
/// window or its content changed (see `OCRPolicy`). Runs on its own utility queue, off the main thread.
actor ScreenTextReader {
    /// Longest side of the fingerprint capture, in pixels.
    static let thumbnailSize: CGFloat = 512
    /// Longest side of the OCR capture. A full Retina window (2880 px) stays at native resolution.
    static let maxCaptureSize: CGFloat = 3200

    private let queue = DispatchSerialQueue(label: "ai.lightslips.moku.sense.ocr", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private var shareableWindows: [CGWindowID: SCWindow] = [:]
    private var policy = OCRPolicy()
    private var lastRead: (window: WindowKey, text: ScreenText)?
    private(set) var ocrRuns = 0
    private(set) var ocrMilliseconds = 0.0

    /// Nil when the window cannot be captured (closed, minimized, or no Screen Recording permission).
    /// `frame` is the window's current Quartz frame; a moved or resized window is looked up again.
    func read(_ key: WindowKey, frame: CGRect?, now: TimeInterval) async -> ScreenText? {
        guard let window = await shareableWindow(key.windowID, frame: frame) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard let thumbnail = await capture(filter, longestSide: Self.thumbnailSize) else {
            shareableWindows[key.windowID] = nil
            return nil
        }
        let fingerprint = ContentFingerprint(image: thumbnail)
        if let last = lastRead, last.window == key, !policy.shouldRead(window: key, fingerprint: fingerprint, now: now) {
            return last.text
        }
        let native = max(filter.contentRect.width, filter.contentRect.height) * CGFloat(filter.pointPixelScale)
        guard let image = await capture(filter, longestSide: min(native, Self.maxCaptureSize)) else { return nil }

        let started = ProcessInfo.processInfo.systemUptime
        let text = ((try? TextRecognizer.recognizeLines(in: image)) ?? []).joined(separator: "\n")
        ocrMilliseconds += (ProcessInfo.processInfo.systemUptime - started) * 1000
        ocrRuns += 1

        let result = ScreenText(text: text, hash: TextDigest.sha256(text))
        policy.didRead(window: key, fingerprint: fingerprint, textHash: result.hash, now: now)
        lastRead = (key, result)
        return result
    }

    func reset() {
        policy.reset()
        lastRead = nil
        shareableWindows = [:]
    }

    private func shareableWindow(_ id: CGWindowID, frame: CGRect?) async -> SCWindow? {
        if let cached = shareableWindows[id], frame.map({ WindowList.framesMatch(cached.frame, $0) }) ?? true {
            return cached
        }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else {
            return nil
        }
        shareableWindows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        return shareableWindows[id]
    }

    /// The window scaled so its longest side is `longestSide` pixels; no cursor.
    private func capture(_ filter: SCContentFilter, longestSide: CGFloat) async -> CGImage? {
        let rect = filter.contentRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        let scale = longestSide / max(rect.width, rect.height)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((rect.width * scale).rounded()))
        configuration.height = max(1, Int((rect.height * scale).rounded()))
        configuration.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
