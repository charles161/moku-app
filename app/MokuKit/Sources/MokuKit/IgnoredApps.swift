import Foundation

/// An app Moku steps aside for: hidden while it's in front (the friends, 2026-10-14: "they want it to be hidden in
/// specific apps they select"), and, if the person says so, not watched at all.
public struct IgnoredApp: Codable, Sendable, Hashable, Identifiable {
    public var bundleId: String
    /// As Settings shows it.
    public var name: String
    /// True: Moku only hides, and still watches the app, so its work counts. False: it hides and reads nothing from it.
    public var keepsWatching: Bool
    public var id: String { bundleId.lowercased() }

    public init(bundleId: String, name: String, keepsWatching: Bool = true) {
        self.bundleId = bundleId
        self.name = name
        self.keepsWatching = keepsWatching
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bundleId = try values.decode(String.self, forKey: .bundleId)
        name = try values.decode(String.self, forKey: .name)
        // A list saved before the choice existed was "Apps Moku never watches".
        keepsWatching = try values.decodeIfPresent(Bool.self, forKey: .keepsWatching) ?? false
    }
}

/// The apps Moku steps aside for (Settings › Privacy): it hides while one is in front. For one the person also chose
/// not to have watched, Moku reads nothing from it (no window, address or text), judges nothing and sends nothing. The
/// person picks any number. The list is in the app's defaults on this Mac and goes nowhere.
public struct IgnoredApps: Sendable, Equatable {
    public static let key = "Moku.ignoredApps"
    /// More than anyone needs; keeps the defaults small.
    public static let limit = 100
    /// Moku's own windows are never read, so there is nothing to ignore.
    private static let mokuBundleId = "ai.lightslips.moku"

    public private(set) var apps: [IgnoredApp] = []

    public init() {}

    public static func load(from store: UserDefaults = .standard) -> IgnoredApps {
        var list = IgnoredApps()
        guard let data = store.data(forKey: key), let apps = try? JSONDecoder().decode([IgnoredApp].self, from: data) else { return list }
        for app in apps { list.add(app) }
        return list
    }

    /// Posted after every save (`IgnoredAppsCache` reloads).
    public static let changed = Notification.Name("Moku.ignoredAppsChanged")

    public func save(to store: UserDefaults = .standard) {
        defer { NotificationCenter.default.post(name: Self.changed, object: store) }
        guard !apps.isEmpty, let data = try? JSONEncoder().encode(apps) else { return store.removeObject(forKey: Self.key) }
        store.set(data, forKey: Self.key)
    }

    public func contains(bundleId: String) -> Bool {
        let id = bundleId.lowercased()
        return apps.contains { $0.id == id }
    }

    /// Moku hides while this app is in front.
    public func stepsAside(bundleId: String) -> Bool { contains(bundleId: bundleId) }

    /// Moku reads nothing from this app while it's in front: no window, address or text, no judging, nothing sent.
    public func ignores(bundleId: String) -> Bool {
        let id = bundleId.lowercased()
        return apps.contains { $0.id == id && !$0.keepsWatching }
    }

    public mutating func setKeepsWatching(_ keepsWatching: Bool, bundleId: String) {
        let id = bundleId.lowercased()
        for index in apps.indices where apps[index].id == id { apps[index].keepsWatching = keepsWatching }
    }

    /// False when it isn't added: already listed, Moku itself, no id, or the list is full.
    @discardableResult
    public mutating func add(_ app: IgnoredApp) -> Bool {
        let bundleId = app.bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleId.isEmpty, bundleId.lowercased() != Self.mokuBundleId, apps.count < Self.limit,
              !contains(bundleId: bundleId) else { return false }
        let name = app.name.trimmingCharacters(in: .whitespacesAndNewlines)
        apps.append(IgnoredApp(bundleId: bundleId, name: name.isEmpty ? bundleId : name, keepsWatching: app.keepsWatching))
        return true
    }

    public mutating func remove(bundleId: String) {
        let id = bundleId.lowercased()
        apps.removeAll { $0.id == id }
    }
}

/// The list as last saved, read once and again after each save: the senses ask several times a sample, and decoding the
/// defaults each time was waste (2026-10-14 review).
@MainActor public final class IgnoredAppsCache {
    public private(set) var list: IgnoredApps
    private let store: UserDefaults
    private var observer: (any NSObjectProtocol)?

    public init(store: UserDefaults = .standard) {
        self.store = store
        list = IgnoredApps.load(from: store)
        observer = NotificationCenter.default.addObserver(forName: IgnoredApps.changed, object: store, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    private func reload() { list = IgnoredApps.load(from: store) }
}
