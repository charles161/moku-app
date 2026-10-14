import Foundation

/// When Moku is added to the login items (launch QA, lens 1, call 4): only when the person presses the welcome's Start
/// with "Start with your Mac" on. The switch is the consent; nothing is registered at first launch (macOS used to show
/// its "added to login items" banner before the person had seen the switch).
public enum LoginItemConsent {
    /// Start: the switch, applied. On registers the login item, off removes it; nil when it already matches.
    public static func atStart(switchOn: Bool, registered: Bool) -> Bool? { switchOn == registered ? nil : switchOn }
    /// Skip or the close button: only a switch the person flipped counts (a welcome left untouched changes nothing).
    public static func atEarlyExit(switchOn: Bool, switchAtOpen: Bool) -> Bool? { switchOn == switchAtOpen ? nil : switchOn }
    /// Only a copy in Applications is ever added: a development build (build/Moku.app) never adds itself.
    public static func mayRegister(bundlePath: String) -> Bool { bundlePath.hasPrefix("/Applications/") }
}
