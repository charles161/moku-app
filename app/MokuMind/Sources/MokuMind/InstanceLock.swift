import Darwin
import Foundation

/// One Moku at a time, decided by the system and not by a look at who is running: a lock on ~/.moku/moku.lock that the
/// first Moku takes and keeps until it ends (the system lets go of it when the process dies, however it dies).
///
/// Looking for another running Moku (NSRunningApplication) has a gap: two copies started in the same instant can each
/// see the other and both quit, or neither see the other and both run, with two characters on screen, two sets of sensors
/// and two brains fighting over the port.
public enum InstanceLock {
    /// Kept open for as long as this process runs: the lock is on the open file.
    nonisolated(unsafe) private static var held: Int32 = -1

    /// Takes the lock. False only when another Moku holds it. If the lock file can't be made (the folder isn't writable)
    /// it says true: that is no reason to keep Moku from starting.
    public static func acquire(at file: URL) -> Bool {
        if held >= 0 { return true }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return true }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let heldByAnother = errno == EWOULDBLOCK
            close(descriptor)
            return !heldByAnother
        }
        held = descriptor
        return true
    }

    /// For tests: lets go of this process's lock.
    static func release() {
        guard held >= 0 else { return }
        flock(held, LOCK_UN); close(held); held = -1
    }
}
