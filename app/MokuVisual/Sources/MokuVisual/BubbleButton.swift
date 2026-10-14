import CoreGraphics
import Foundation

/// A button in a bubble ("What's new"'s link and ✕), drawn resting and under the pointer, and its size in points.
struct BubbleButton {
    var size: CGSize
    var resting: CGImage?
    var hovered: CGImage?

    /// How often the stage looks whether the pointer has left a bubble it could click, before taking the bubble down.
    static let pointerCheckEvery: Duration = .milliseconds(250)
}
