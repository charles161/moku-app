import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MokuKit

/// Settings › Privacy › "Apps where Moku steps aside": picking apps from the Applications folder, or from the ones that are
/// open now. The list itself is `IgnoredApps` (MokuKit), which the senses read.
enum IgnoredAppPicker {
    /// The app at a bundle's address: its id and the name Finder shows. Nil for anything that isn't an app with an id.
    static func app(at url: URL) -> IgnoredApp? {
        guard let bundle = Bundle(url: url), let bundleId = bundle.bundleIdentifier, !bundleId.isEmpty else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return IgnoredApp(bundleId: bundleId, name: name)
    }

    /// The apps open now with a Dock icon, by name, without Moku and the apps already listed.
    @MainActor static func runningApps(excluding listed: [IgnoredApp]) -> [IgnoredApp] {
        let skip = Set(listed.map(\.id))
        var seen: Set<String> = []
        return NSWorkspace.shared.runningApplications.compactMap { running -> IgnoredApp? in
            guard running.activationPolicy == .regular, let id = running.bundleIdentifier, running.processIdentifier != getpid() else { return nil }
            let app = IgnoredApp(bundleId: id, name: running.localizedName ?? id)
            guard !skip.contains(app.id), seen.insert(app.id).inserted else { return nil }
            return app
        }
        .filter { $0.id != "ai.lightslips.moku" }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The Applications folder's panel, with any number of apps chosen at once.
    @MainActor static func chooseFromApplications() -> [IgnoredApp] {
        let panel = NSOpenPanel()
        panel.title = "Choose apps where Moku steps aside"
        panel.prompt = "Add"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap { app(at: $0) }
    }

    @MainActor static func icon(for app: IgnoredApp) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleId) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}

extension SettingsModel {
    /// Adds the apps not listed yet; says `setting_changed` once (its name only, never which app).
    func addIgnored(_ apps: [IgnoredApp]) {
        var list = IgnoredApps.load(from: preferences)
        var added = false
        for app in apps where list.add(app) { added = true }
        guard added else { return }
        list.save(to: preferences)
        ignoredApps = list.apps
        settingChanged("ignored_apps", turned: true)
    }

    /// "Hide Moku" (still watched, the work counts) or "Hide, don't watch".
    func setKeepsWatching(_ keepsWatching: Bool, bundleId: String) {
        var list = IgnoredApps.load(from: preferences)
        guard list.contains(bundleId: bundleId) else { return }
        list.setKeepsWatching(keepsWatching, bundleId: bundleId)
        list.save(to: preferences)
        ignoredApps = list.apps
        settingChanged("ignored_apps_watch", turned: keepsWatching)
    }

    func removeIgnored(bundleId: String) {
        var list = IgnoredApps.load(from: preferences)
        guard list.contains(bundleId: bundleId) else { return }
        list.remove(bundleId: bundleId)
        list.save(to: preferences)
        ignoredApps = list.apps
        settingChanged("ignored_apps", turned: false)
    }
}

/// The rows: each app with its choice (hide Moku, or hide and don't watch) and a way to remove it, and one menu to add more.
struct IgnoredAppsList: View {
    @Bindable var model: SettingsModel

    var body: some View {
        ForEach(model.ignoredApps) { app in
            HStack(spacing: 10) {
                Image(nsImage: IgnoredAppPicker.icon(for: app)).resizable().frame(width: 22, height: 22)
                Text(app.name)
                Spacer()
                Picker("", selection: Binding(get: { app.keepsWatching }, set: { model.setKeepsWatching($0, bundleId: app.bundleId) })) {
                    Text("Hide Moku").tag(true)
                    Text("Hide, don’t watch").tag(false)
                }
                .labelsHidden().fixedSize()
                .accessibilityLabel("What Moku does in \(app.name)")
                Button {
                    model.removeIgnored(bundleId: app.bundleId)
                } label: {
                    Image(systemName: "minus.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Show Moku in \(app.name) again")
                .accessibilityLabel("Show Moku in \(app.name) again")
            }
        }
        Menu("Add an app…") {
            let running = IgnoredAppPicker.runningApps(excluding: model.ignoredApps)
            if !running.isEmpty {
                Section("Open now") {
                    ForEach(running) { app in Button(app.name) { model.addIgnored([app]) } }
                }
            }
            Button("Choose from Applications…") { model.addIgnored(IgnoredAppPicker.chooseFromApplications()) }
        }
        .menuStyle(.button).fixedSize()
        .disabled(model.ignoredApps.count >= IgnoredApps.limit)
    }
}
