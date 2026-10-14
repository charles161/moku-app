import Darwin
import Foundation
import Testing
@testable import MokuMind

@Suite("Instance lock", .serialized)
struct InstanceLockTests {
    func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("moku-lock-\(UUID().uuidString)/.moku/moku.lock") }

    @Test func theFirstMokuTakesItAndASecondIsRefused() throws {
        let lock = file(); defer { InstanceLock.release(); try? FileManager.default.removeItem(at: lock.deletingLastPathComponent().deletingLastPathComponent()) }
        #expect(InstanceLock.acquire(at: lock))
        // Another process (a second Moku) asks for the same lock.
        let other = Process(); other.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        other.arguments = ["-c", "import fcntl,sys; f=open(sys.argv[1],'w'); \ntry:\n fcntl.flock(f, fcntl.LOCK_EX|fcntl.LOCK_NB); sys.exit(0)\nexcept OSError: sys.exit(7)", lock.path]
        try other.run(); other.waitUntilExit()
        #expect(other.terminationStatus == 7, "a second Moku got the lock too")
    }

    @Test func theLockIsFreeAgainWhenTheHolderIsGone() throws {
        let lock = file(); defer { try? FileManager.default.removeItem(at: lock.deletingLastPathComponent().deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A holder that is killed, the way a crashed Moku is.
        let holder = Process(); holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        holder.arguments = ["-c", "import fcntl,sys,time; f=open(sys.argv[1],'w'); fcntl.flock(f, fcntl.LOCK_EX); print('held', flush=True); time.sleep(60)", lock.path]
        let out = Pipe(); holder.standardOutput = out
        try holder.run()
        _ = out.fileHandleForReading.availableData  // "held"
        #expect(!InstanceLock.acquire(at: lock), "took a lock another process holds")
        kill(holder.processIdentifier, SIGKILL); holder.waitUntilExit()
        #expect(InstanceLock.acquire(at: lock), "a dead Moku's lock keeps the next one out")
        InstanceLock.release()
    }

    @Test func aFolderThatCantBeWrittenDoesNotKeepMokuFromStarting() {
        #expect(InstanceLock.acquire(at: URL(fileURLWithPath: "/nonexistent-root-folder/.moku/moku.lock")))
        InstanceLock.release()
    }
}
