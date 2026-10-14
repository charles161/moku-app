import Foundation
import QuartzCore

/// Opt-in startup allocation trace. Off by default; no recurring sampling work.
nonisolated(unsafe) private var lastMarkAt = 0.0
func memoryMark(_ phase: String) {
    if ProcessInfo.processInfo.environment["MOKU_LOAD_TIMING"] == "1" {  // how long since the last mark (a load's steps)
        let now = CACurrentMediaTime(); NSLog("mark %@: %.0f ms", phase, lastMarkAt > 0 ? (now - lastMarkAt) * 1000 : 0); lastMarkAt = now
    }
    guard ProcessInfo.processInfo.environment["MOKU_PROFILE_MEMORY"] == "1", let info = vmInfo() else { return }
    NSLog("Moku memory %@: resident %.2f MiB, physical %.2f MiB", phase, Double(info.resident_size) / 1_048_576, Double(info.phys_footprint) / 1_048_576)
}

/// The physical footprint (what Activity Monitor shows as Memory), in MiB.
func physicalFootprint() -> Double { vmInfo().map { Double($0.phys_footprint) / 1_048_576 } ?? 0 }

/// The most the physical footprint has been since launch, in MiB.
func peakPhysicalFootprint() -> Double { vmInfo().map { Double($0.ledger_phys_footprint_peak) / 1_048_576 } ?? 0 }

/// Seconds since this process started (the launch time to a first frame is measured from here).
func processAgeSeconds() -> Double {
    var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()], info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
    let started = info.kp_proc.p_un.__p_starttime
    return Date().timeIntervalSince1970 - (Double(started.tv_sec) + Double(started.tv_usec) / 1e6)
}

private func vmInfo() -> task_vm_info_data_t? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? info : nil
}
