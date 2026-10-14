import Darwin
import Foundation
import MokuKit
import MokuSense

/// The app's part of the daily heartbeat (MokuMind's DailyHeartbeat), taken when it's sent: the versions, the Mac,
/// the plan, and how Moku itself is doing (permissions, CPU and memory since launch, brain restarts, crash reports).
/// Numbers, booleans and a few short strings; nothing from the screen.
enum AppFacts {
    @MainActor static func collect(launchedAt: Date, plan: AccessStatus.Plan, localModel: String?, brainExits: Int) -> [String: Any] {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let permissions = SenseHub.permissionStatus()
        let running = max(1, Date().timeIntervalSince(launchedAt))
        #if arch(arm64)
        let chip = "arm64"
        #else
        let chip = "x86_64"
        #endif
        return [
            "version": info["CFBundleShortVersionString"] as? String ?? "0",
            "build": info["CFBundleVersion"] as? String ?? "0",
            "macos": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "chip": chip,
            "plan": plan.rawValue,
            "app": [
                "memoryGB": Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()),
                "screenRecording": permissions.screenRecording,
                "accessibility": permissions.accessibility,
                "onboarded": Onboarding.isCompleted,
                "hoursRunning": (running / 360).rounded() / 10,
                "cpuPercent": (cpuSeconds() / running * 1000).rounded() / 10,
                "footprintMB": footprintMB(),
                "brainExits": brainExits,
                "localModelReady": localModel == "ready" || localModel == "running",
                "crashReports7d": crashReports(within: 7 * 86_400),
            ] as [String: Any],
        ]
    }

    /// CPU time this process has used since launch, in seconds.
    static func cpuSeconds() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    /// The memory this process is charged for now (what Activity Monitor shows), in MB.
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return status == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : 0
    }

    /// How many crash reports macOS wrote for Moku lately (their names and dates only; they aren't read).
    private static func crashReports(within seconds: TimeInterval) -> Int {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { url in
            url.lastPathComponent.hasPrefix("Moku-") && url.pathExtension == "ips"
                && ((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).flatMap { $0 }.map { Date().timeIntervalSince($0) < seconds } ?? false)
        }.count
    }
}

/// Memory and CPU for the day's summary (`day_summary`: the median memory in steps of 50 MB, and the share of a core in
/// steps): one sample every 10 minutes, from numbers the system already keeps (no polling in between). The share of a
/// core is the CPU time used since the last sample over the time the Mac was awake meanwhile, so a night asleep isn't an
/// idle Moku.
@MainActor final class ResourceSamples {
    static let every: TimeInterval = 600
    private var last = (cpu: AppFacts.cpuSeconds(), awake: ProcessInfo.processInfo.systemUptime)

    /// A sample now; nil when too little time has passed to say.
    func take() -> UsageCount? {
        let now = (cpu: AppFacts.cpuSeconds(), awake: ProcessInfo.processInfo.systemUptime)
        defer { last = now }
        let awake = now.awake - last.awake
        guard awake >= 60 else { return nil }
        return .resources(memoryMB: AppFacts.footprintMB(), corePermille: Int(((now.cpu - last.cpu) / awake * 1000).rounded()))
    }
}

/// The brain sets a damaged store aside as moku.sqlite.damaged and starts a new one (brain-go store.go): `trouble`
/// (store_set_aside), once for each time it happens. Only the file's date is read.
@MainActor enum StoreSetAside {
    static let seenKey = "Moku.storeSetAsideSeen"
    static func isNew(home: URL, defaults: UserDefaults = .standard) -> Bool {
        let damaged = home.appendingPathComponent("moku.sqlite.damaged")
        guard let date = (try? FileManager.default.attributesOfItem(atPath: damaged.path))?[.modificationDate] as? Date else { return false }
        let seen = defaults.double(forKey: seenKey)
        guard date.timeIntervalSince1970 > seen + 1 else { return false }
        defaults.set(date.timeIntervalSince1970, forKey: seenKey)
        return seen > 0 || Date().timeIntervalSince(date) < 86_400  // one set aside before this check existed isn't news
    }
}

/// Main-thread stalls (`day_summary`'s stalls): the main run loop busy for more than a quarter of a second between waking
/// and going back to sleep, so nothing on screen could move meanwhile. The run loop reports its own wakes: two clock reads
/// each time, nothing polled.
@MainActor final class MainThreadStalls {
    static let threshold: CFAbsoluteTime = 0.25
    private var observer: CFRunLoopObserver?

    func start(onStall: @escaping @MainActor () -> Void) {
        guard observer == nil else { return }
        var wokeAt: CFAbsoluteTime = 0
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, activity in
            let now = CFAbsoluteTimeGetCurrent()
            if activity == .afterWaiting { wokeAt = now; return }
            if wokeAt > 0, now - wokeAt > Self.threshold { MainActor.assumeIsolated { onStall() } }
            wokeAt = 0
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }
}
