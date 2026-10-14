import Foundation

/// The logs in ~/.moku name apps, goals and what was done in them: brain.log has a line per judgment ("working
/// \"Moku launch\" … Cursor (fixing the popover)"), and app.log notes the day's cards. So "Delete my data" empties them
/// too, with the older copies (`<name>.1`), or a history the person asked to delete would live on there.
public enum HistoryLogs {
    /// The logs Moku keeps in `home`: the brain's and the app's.
    public static let names = ["brain.log", "app.log"]

    /// Empties each log in place and removes its older copy. In place, so a process that holds a log open for appending
    /// (the brain writes brain.log with O_APPEND) goes on writing at the start of the emptied file.
    public static func forget(in home: URL) {
        let fm = FileManager.default
        for name in names {
            let log = home.appendingPathComponent(name)
            try? fm.removeItem(at: log.appendingPathExtension("1"))
            if let handle = try? FileHandle(forWritingTo: log) {
                try? handle.truncate(atOffset: 0)
                try? handle.close()
            }
        }
    }
}
