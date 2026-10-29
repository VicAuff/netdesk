import Darwin
import Foundation
import IOKit.ps

public struct SystemSnapshot: Sendable {
    public var cpuUsage: Double = 0
    public var memoryUsed: Int64 = 0
    public var memoryTotal: Int64 = 0
    public var memoryCompressed: Int64 = 0
    public var diskAvailable: Int64 = 0
    public var diskTotal: Int64 = 0
    public var batteryLevel: Int?
    public var isCharging = false
    public var uptime: TimeInterval = 0
    public var thermalState: ProcessInfo.ThermalState = .nominal

    public init() {}

    public var memoryRatio: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0 }
    public var diskUsedRatio: Double { diskTotal > 0 ? Double(diskTotal - diskAvailable) / Double(diskTotal) : 0 }
}

/// Read-only system figures for the monitor, sampled while the app is open.
public final class SystemMonitor: @unchecked Sendable {
    private var previousTicks: (used: UInt64, total: UInt64)?

    public init() {}

    public func sample() -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        snapshot.cpuUsage = cpuUsage()
        let memory = memoryUsage()
        snapshot.memoryUsed = memory.used
        snapshot.memoryCompressed = memory.compressed
        snapshot.memoryTotal = Int64(ProcessInfo.processInfo.physicalMemory)
        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            snapshot.diskTotal = Int64(values.volumeTotalCapacity ?? 0)
            snapshot.diskAvailable = values.volumeAvailableCapacityForImportantUsage ?? 0
        }
        let battery = batteryState()
        snapshot.batteryLevel = battery.level
        snapshot.isCharging = battery.charging
        snapshot.uptime = ProcessInfo.processInfo.systemUptime
        snapshot.thermalState = ProcessInfo.processInfo.thermalState
        return snapshot
    }

    private func cpuUsage() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1), idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let used = user + system + nice
        let total = used + idle
        defer { previousTicks = (used, total) }
        guard let previous = previousTicks, total > previous.total else {
            return total > 0 ? Double(used) / Double(total) : 0
        }
        return Double(used - previous.used) / Double(total - previous.total)
    }

    private func memoryUsage() -> (used: Int64, compressed: Int64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        let page = Int64(vm_kernel_page_size)
        // Close to Activity Monitor's "memory used": app memory + wired + compressed.
        let appMemory = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
        let used = (appMemory + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * page
        return (used, Int64(stats.compressor_page_count) * page)
    }

    private func batteryState() -> (level: Int?, charging: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, false) }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int
            let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            if let current { return (Int(Double(current) / Double(max) * 100), charging) }
        }
        return (nil, false)
    }
}
