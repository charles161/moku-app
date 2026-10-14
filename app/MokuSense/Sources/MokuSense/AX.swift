import ApplicationServices
import Foundation

/// Typed reads over the Accessibility C API. Every call is a synchronous IPC round trip to the
/// target app, bounded by the global messaging timeout set in `AX.boundTimeouts()`.
enum AX {
    /// Keeps a hung app from blocking Moku for the system default of 6 seconds.
    static func boundTimeouts(seconds: Float = 0.25) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }

    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func int(_ element: AXUIElement, _ attribute: String) -> Int? {
        (value(element, attribute) as? NSNumber)?.intValue
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func url(_ element: AXUIElement, _ attribute: String = "AXURL") -> String? {
        switch value(element, attribute) {
        case let url as URL: url.absoluteString
        case let string as String: string
        default: nil
        }
    }

    /// Frame in Quartz global coordinates (origin top-left of the primary display, y down).
    static func frame(_ element: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let position = axValue(element, kAXPositionAttribute), AXValueGetValue(position, .cgPoint, &origin),
              let extent = axValue(element, kAXSizeAttribute), AXValueGetValue(extent, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func range(_ element: AXUIElement, _ attribute: String) -> CFRange? {
        var range = CFRange()
        guard let value = axValue(element, attribute), AXValueGetValue(value, .cfRange, &range) else { return nil }
        return range
    }

    static func string(_ element: AXUIElement, forRange range: CFRange) -> String? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value) == .success
        else { return nil }
        return value as? String
    }

    /// Role and children in one round trip.
    static func roleAndChildren(_ element: AXUIElement) -> (role: String?, children: [AXUIElement]) {
        var values: CFArray?
        let attributes = [kAXRoleAttribute, kAXChildrenAttribute] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(element, attributes, AXCopyMultipleAttributeOptions(), &values) == .success,
              let list = values as? [Any], list.count == 2
        else { return (nil, []) }
        return (list[0] as? String, (list[1] as? [AXUIElement]) ?? [])
    }

    @discardableResult
    static func set(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }
}
