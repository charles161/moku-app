import Darwin
import Foundation

/// What Moku does about a brain that already answers on its port when it starts, and about one it didn't start going away.
///
/// Moku only ever adopted such a brain ("a developer started one by hand") and then left it alone for good: if it
/// later died, nobody started another, and Moku stayed calm until the next launch. The commonest such brain was Moku's
/// own, orphaned when the app crashed or was killed (before 0.1.8 a brain never noticed its app was gone). After an
/// update it would be an older version, answering without the brain token, for as long as the Mac stayed on.
///
/// - A brain whose parent is launchd (pid 1) and that is a `moku-brain` of this user was left behind by an app that's
///   gone: it's stopped and Moku starts its own, whatever its version. A developer's brain, started from a shell,
///   has the shell for a parent and is left alone.
/// - Any other brain that takes Moku's token is adopted. One that answers /health but not with Moku's token isn't
///   Moku's to use: Moku says so in its log and stays calm until it's gone.
/// - A brain Moku adopted that stops answering is replaced after two checks (a minute), as one Moku started is.
public enum BrainAdoption {
    /// The process holding the brain's port.
    public struct Listener: Equatable, Sendable {
        public var pid: Int32
        public var parent: Int32
        public var owner: uid_t
        public var name: String

        public init(pid: Int32, parent: Int32, owner: uid_t, name: String) {
            self.pid = pid; self.parent = parent; self.owner = owner; self.name = name
        }

        /// A moku-brain of this user that no app is parent of any more.
        public var isOrphanedMokuBrain: Bool { name == "moku-brain" && parent == 1 && owner == getuid() }
    }

    public enum Decision: Equatable, Sendable {
        /// Nothing answers: start Moku's own brain.
        case start
        /// A brain answers and takes Moku's token: use it, don't manage it.
        case adopt
        /// An orphaned moku-brain answers: stop it, then start Moku's own.
        case replace(pid: Int32)
        /// Something answers /health but not with Moku's token (another user's brain, another program): leave it, stay calm.
        case standOff
    }

    public static func decide(answersHealth: Bool, acceptsToken: Bool, listener: Listener?) -> Decision {
        guard answersHealth else { return .start }
        if let listener, listener.isOrphanedMokuBrain { return .replace(pid: listener.pid) }
        return acceptsToken ? .adopt : .standOff
    }

    /// Checks in a row (30 s apart) without an answer from a brain Moku didn't start before it starts its own.
    public static let missesBeforeStartingOwn = 2

    /// The process listening on 127.0.0.1:`port`, or nil when none (or lsof can't say).
    public static func listener(onPort port: Int) async -> Listener? {
        await Task.detached(priority: .utility) { () -> Listener? in
            let lsof = Process()
            lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            lsof.arguments = ["-nP", "-iTCP@127.0.0.1:\(port)", "-sTCP:LISTEN", "-Fp"]
            let out = Pipe()
            lsof.standardOutput = out
            lsof.standardError = FileHandle.nullDevice
            guard (try? lsof.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            lsof.waitUntilExit()
            let pid = String(decoding: data, as: UTF8.self).split(separator: "\n")
                .compactMap { $0.hasPrefix("p") ? Int32($0.dropFirst()) : nil }.first
            return pid.flatMap(Self.process)
        }.value
    }

    /// What the system says about `pid`.
    public static func process(_ pid: Int32) -> Listener? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let name = URL(fileURLWithPath: String(cString: path)).lastPathComponent
        return Listener(pid: pid, parent: Int32(info.pbi_ppid), owner: info.pbi_uid, name: name)
    }
}

/// Which port Moku's brain lives on. 8020 when it's free or already Moku's; when something else holds it (a developer's
/// server, another program, another macOS user's Moku), the next of ten: 8021 to 8029. Without this, a friend whose Mac
/// already ran something on 8020 got a Moku that stayed calm for good, said only by a line in the popover.
public enum BrainPorts {
    public static let first = 8020
    public static let count = 10
    public static var all: [Int] { Array(first..<(first + count)) }

    /// What is on a port.
    public enum Probe: Equatable, Sendable {
        /// A brain that takes Moku's token: use it.
        case ours
        /// A moku-brain an earlier Moku left behind: stop it, then use the port.
        case orphan(pid: Int32)
        /// Nothing is listening and the port can be bound.
        case free
        /// Something else: another program, another user's brain, or a listener that answers no one.
        case taken
    }

    public enum Choice: Equatable, Sendable {
        case adopt(port: Int)
        case replace(port: Int, pid: Int32)
        case start(port: Int)
        /// Every port is taken.
        case none
    }

    /// The first port that is Moku's to use, in order.
    public static func choose(among ports: [Int] = all, isolation: isolated (any Actor)? = #isolation, probe: (Int) async -> Probe) async -> Choice {
        for port in ports {
            switch await probe(port) {
            case .ours: return .adopt(port: port)
            case let .orphan(pid): return .replace(port: port, pid: pid)
            case .free: return .start(port: port)
            case .taken: continue
            }
        }
        return .none
    }

    /// Whether a brain could listen on 127.0.0.1:`port` now: a bind as Go's listener makes it (SO_REUSEADDR), which fails
    /// while another process listens there. Nothing keeps the socket.
    public static func isFree(_ port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return true }
        defer { close(descriptor) }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port)).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return bound == 0
    }
}
