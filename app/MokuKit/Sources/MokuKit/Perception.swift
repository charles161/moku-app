import CoreGraphics
import Foundation

/// One moment of the user's work, sent to the brain for judgment (POST /v1/judge).
/// JSON is camelCase; dates are epoch milliseconds (use `MokuJSON`).
public struct ActivitySample: Codable, Sendable, Equatable {
    public var id: String
    public var ts: Date
    public var app: AppInfo
    public var window: WindowInfo?
    /// Text of the focused window (accessibility first, OCR when needed), capped by the sensor.
    /// Nil when the window's content has not changed since the last sample that carried text.
    public var text: String?
    public var textSource: TextSource?
    /// Hash of the focused window's full text whenever any text was read; lets the brain spot "same screen".
    /// When `text` is nil because nothing changed, `textHash` and `textSource` repeat the last read.
    public var textHash: String?
    public var activity: InputActivity
    public var context: MeetingContext

    public init(id: String, ts: Date, app: AppInfo, window: WindowInfo?, text: String?, textSource: TextSource?,
                textHash: String?, activity: InputActivity, context: MeetingContext) {
        self.id = id
        self.ts = ts
        self.app = app
        self.window = window
        self.text = text
        self.textSource = textSource
        self.textHash = textHash
        self.activity = activity
        self.context = context
    }
}

public struct AppInfo: Codable, Sendable, Hashable {
    public var bundleId: String
    public var name: String

    public init(bundleId: String, name: String) {
        self.bundleId = bundleId
        self.name = name
    }
}

public struct WindowInfo: Codable, Sendable, Hashable {
    public var title: String
    /// Current page address when the focused app is a browser.
    public var url: String?

    public init(title: String, url: String?) {
        self.title = title
        self.url = url
    }
}

public enum TextSource: String, Codable, Sendable {
    case accessibility, ocr
}

/// Typing rhythm only: counts over the last 60 seconds, never which keys.
public struct InputActivity: Codable, Sendable, Equatable {
    public var keysPerMinute: Int
    public var clicksPerMinute: Int
    public var scrollsPerMinute: Int
    public var idleSeconds: Double

    public init(keysPerMinute: Int, clicksPerMinute: Int, scrollsPerMinute: Int, idleSeconds: Double) {
        self.keysPerMinute = keysPerMinute
        self.clicksPerMinute = clicksPerMinute
        self.scrollsPerMinute = scrollsPerMinute
        self.idleSeconds = idleSeconds
    }
}

public struct MeetingContext: Codable, Sendable, Equatable {
    public var inCall: Bool
    public var sharingScreen: Bool
    public var micInUse: Bool
    public var cameraInUse: Bool

    public init(inCall: Bool, sharingScreen: Bool, micInUse: Bool, cameraInUse: Bool) {
        self.inCall = inCall
        self.sharingScreen = sharingScreen
        self.micInUse = micInUse
        self.cameraInUse = cameraInUse
    }

    public static let none = MeetingContext(inCall: false, sharingScreen: false, micInUse: false, cameraInUse: false)
}

/// Real-time, local-only events from the sensors. Screen points are AppKit global coordinates
/// (origin at the bottom-left of the primary display, y up), the same as `NSEvent.mouseLocation`.
public enum SenseEvent: Sendable {
    /// Every `sampleIntervalSec`: the full reading, to be judged by the brain.
    case sample(ActivitySample)
    /// Immediately when the frontmost app or its focused window changes (fast return detection).
    case focusChanged(AppInfo, WindowInfo?)
    /// Where the user is working right now (cursor or text caret), at most ~15 per second.
    case attention(CGPoint)
    /// Whenever call or screen-sharing state changes.
    case meeting(MeetingContext)
    /// On start and whenever a permission changes.
    case permissions(PermissionStatus)
}

public struct PermissionStatus: Sendable, Equatable {
    public var accessibility: Bool
    public var screenRecording: Bool

    public init(accessibility: Bool, screenRecording: Bool) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
    }
}
