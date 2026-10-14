import Foundation

public enum MokuAssets {
    public static var root: URL? {
        if let pin = ProcessInfo.processInfo.environment["MOKU_ASSETS_DIR"] ?? ProcessInfo.processInfo.environment["MOKU_ASSET_ROOT"] {
            let url = URL(fileURLWithPath: pin).standardizedFileURL
            return FileManager.default.fileExists(atPath: url.appendingPathComponent("SPEC.md").path) ? url : nil
        }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("assets")
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("MokuAssets"), source]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("SPEC.md").path) }
    }
    /// A bundled file. Character files (`character/…`) are the companion's: `companion`'s when given, otherwise the
    /// one on show (Companion.resolve).
    public static func file(_ path: String, companion: Companion? = nil) -> URL? {
        let resolved = (companion ?? Companion.current).resolve(path)
        guard let url = root?.appendingPathComponent(resolved), FileManager.default.fileExists(atPath: url.path) else { return nil }; return url
    }
    /// Whether a file is bundled, exactly at `path`.
    static func exists(_ path: String) -> Bool {
        root.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(path).path) } ?? false
    }
}
