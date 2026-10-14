import AppKit

/// A menu bar for Moku's own windows (Settings, Your day). Moku never shows it (no Dock icon), but its key
/// equivalents are what make ⌘C, ⌘V, ⌘A, ⌘Z and ⌘W work there.
enum AppMenu {
    @MainActor static func install() {
        let bar = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(), menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu; bar.addItem(item)
        }
        // ⌘Q goes the way the other Quit Moku items do (QuitRequest): the day's card may say goodbye first.
        menu("Moku", [NSMenuItem(title: "Quit Moku", action: #selector(AppDelegate.quitFromMenu(_:)), keyEquivalent: "q")])
        menu("Edit", [
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
            NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"),
            .separator(),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ])
        menu("Window", [NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")])
        NSApp.mainMenu = bar
    }
}
