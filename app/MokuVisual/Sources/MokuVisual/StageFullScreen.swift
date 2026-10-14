import AppKit

/// "Hide Moku when media is full screen" (Charles, 2026-10-08). The senses say which displays have a full-screen window
/// (MokuSense's `FullScreenRules`); Moku hides while its own display is one of them and comes back when that ends.
/// It is a third reason to be hidden, beside the app's (a call) and the person's ("Hide Moku"): Moku shows only when
/// none holds. The welcome is never hidden by it.
extension MokuCharacterStage {
    /// The displays (`CGDirectDisplayID`s) that have a full-screen window now.
    public func setFullScreenDisplays(_ displays: Set<UInt32>) {
        guard displays != fullScreenDisplays else { return }
        fullScreenDisplays = displays
        refreshHidden()
    }

    var hiddenByFullScreen: Bool {
        guard !inWelcome, !fullScreenDisplays.isEmpty, let display = displayIDOverride ?? currentDisplayID() else { return false }
        return fullScreenDisplays.contains(display)
    }

    /// The app in front is one the person asked Moku to step aside for (Settings › Privacy, the friends 2026-10-14).
    public func setSteppingAsideForApp(_ aside: Bool) {
        guard aside != steppingAsideForApp else { return }
        steppingAsideForApp = aside
        refreshHidden()
    }

    var hiddenForFrontApp: Bool { steppingAsideForApp && !inWelcome }

    func refreshHidden() {
        applyHidden(hiddenByApp || hiddenByPerson || hiddenByFullScreen || hiddenForFrontApp)
    }

    /// The display holding most of Moku's window (it can be dragged to another), else its home display.
    private func currentDisplayID() -> UInt32? {
        let frame = panel.frame
        func overlap(_ screen: NSScreen) -> CGFloat {
            let box = screen.frame.intersection(frame)
            return box.isNull ? 0 : box.width * box.height
        }
        let screen = NSScreen.screens.max { overlap($0) < overlap($1) }.flatMap { overlap($0) > 0 ? $0 : nil } ?? homeScreen()
        return (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
