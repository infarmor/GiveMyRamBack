import CoreAudio
import Darwin
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

public struct AudioActivitySnapshot: Sendable {
    public let outputPIDs: Set<Int32>
    public let inputPIDs: Set<Int32>
    public let outputBundleIDs: Set<String>
    public let inputBundleIDs: Set<String>

    public init(
        outputPIDs: Set<Int32> = [],
        inputPIDs: Set<Int32> = [],
        outputBundleIDs: Set<String> = [],
        inputBundleIDs: Set<String> = []
    ) {
        self.outputPIDs = outputPIDs
        self.inputPIDs = inputPIDs
        self.outputBundleIDs = outputBundleIDs
        self.inputBundleIDs = inputBundleIDs
    }
}

public final class SystemMetricsCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var currentPressure: MemoryPressureLevel = .normal
    private var pressureSource: DispatchSourceMemoryPressure?

    public init() {
        setupMemoryPressureMonitor()
    }

    deinit {
        pressureSource?.cancel()
    }

    private func setupMemoryPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let event = source.data
            let level: MemoryPressureLevel
            if event.contains(.critical) {
                level = .critical
            } else if event.contains(.warning) {
                level = .warning
            } else {
                level = .normal
            }
            self.lock.lock()
            self.currentPressure = level
            self.lock.unlock()
        }
        source.resume()
        pressureSource = source
    }

    public func readMemoryStats() -> SystemMemoryStats {
        let totalPhysical = ProcessInfo.processInfo.physicalMemory

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let pageBytes = UInt64(pageSize > 0 ? pageSize : vm_size_t(getpagesize()))

        var vmStats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let kr = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }

        var appMemory: UInt64 = 0
        var wired: UInt64 = 0
        var compressed: UInt64 = 0
        var cachedFiles: UInt64 = 0
        var freeMemory: UInt64 = 0

        if kr == KERN_SUCCESS {
            let internalPages = UInt64(vmStats.internal_page_count)
            let purgeablePages = UInt64(vmStats.purgeable_count)
            let appPages = internalPages > purgeablePages ? (internalPages - purgeablePages) : 0

            appMemory = appPages * pageBytes
            wired = UInt64(vmStats.wire_count) * pageBytes
            compressed = UInt64(vmStats.compressor_page_count) * pageBytes
            cachedFiles = (UInt64(vmStats.external_page_count) + purgeablePages) * pageBytes
            freeMemory = UInt64(vmStats.free_count) * pageBytes
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.stride
        var swapUsed: UInt64 = 0
        var swapTotal: UInt64 = 0
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            swapUsed = swap.xsu_used
            swapTotal = swap.xsu_total
        }

        let pressure = effectiveMemoryPressure(
            totalPhysical: totalPhysical,
            usedBytes: appMemory + wired + compressed,
            compressedBytes: compressed,
            swapUsedBytes: swapUsed
        )

        return SystemMemoryStats(
            totalPhysicalBytes: totalPhysical,
            appMemoryBytes: appMemory,
            wiredBytes: wired,
            compressedBytes: compressed,
            cachedFilesBytes: cachedFiles,
            freeBytes: freeMemory,
            swapUsedBytes: swapUsed,
            swapTotalBytes: swapTotal,
            pressure: pressure,
            powerSource: readPowerSource()
        )
    }

    public func readPowerSource() -> PowerSourceKind {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return .unknown
        }
        guard let rawType = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else {
            return .unknown
        }
        if rawType == kIOPMBatteryPowerKey {
            return .battery
        }
        if rawType == kIOPMACPowerKey {
            return .ac
        }
        return .unknown
    }

    private func effectiveMemoryPressure(
        totalPhysical: UInt64,
        usedBytes: UInt64,
        compressedBytes: UInt64,
        swapUsedBytes: UInt64
    ) -> MemoryPressureLevel {
        lock.lock()
        let eventLevel = currentPressure
        lock.unlock()

        var levelValue: Int32 = 0
        var size = MemoryLayout<Int32>.stride
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &levelValue, &size, nil, 0) == 0 {
            if levelValue >= 4 || eventLevel == .critical {
                return .critical
            }
            if levelValue >= 2 || eventLevel == .warning {
                return .warning
            }
            return .normal
        }

        if eventLevel != .normal {
            return eventLevel
        }

        guard totalPhysical > 0 else { return .normal }
        let usedRatio = Double(usedBytes) / Double(totalPhysical)
        let compressedRatio = Double(compressedBytes) / Double(totalPhysical)
        if usedRatio >= 0.90 || (usedRatio >= 0.82 && swapUsedBytes > 2_147_483_648) {
            return .critical
        }
        if usedRatio >= 0.78 || compressedRatio >= 0.25 {
            return .warning
        }
        return .normal
    }

    public func readSleepAssertionPIDs() -> Set<Int32> {
        var rawDict: Unmanaged<CFDictionary>?
        let status = IOPMCopyAssertionsByProcess(&rawDict)
        guard status == kIOReturnSuccess, let cfDict = rawDict?.takeRetainedValue() else {
            return []
        }

        guard let dict = cfDict as? [NSNumber: [[String: Any]]] else {
            return []
        }

        let blockingTypes: Set<String> = [
            "PreventUserIdleSystemSleep",
            "PreventUserIdleDisplaySleep",
            "PreventSystemSleep",
            "NoIdleSleepAssertion",
            "NoDisplaySleepAssertion"
        ]

        var result = Set<Int32>()
        for (pidNum, assertions) in dict {
            let pid = pidNum.int32Value
            guard pid > 0 else { continue }
            for entry in assertions {
                let typeName = entry[kIOPMAssertionTypeKey as String] as? String ?? ""
                let level = (entry[kIOPMAssertionLevelKey as String] as? NSNumber)?.intValue ?? 0
                if level > 0 && blockingTypes.contains(typeName) {
                    result.insert(pid)
                    break
                }
            }
        }
        return result
    }

    public func readAudioActivity() -> AudioActivitySnapshot {
        guard #available(macOS 14.2, *) else {
            return AudioActivitySnapshot()
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard sizeStatus == noErr, dataSize > 0 else {
            return AudioActivitySnapshot()
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.stride
        var processObjects = [AudioObjectID](repeating: 0, count: count)
        let dataStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &processObjects
        )
        guard dataStatus == noErr else {
            return AudioActivitySnapshot()
        }

        var outputPIDs = Set<Int32>()
        var inputPIDs = Set<Int32>()
        var outputBundleIDs = Set<String>()
        var inputBundleIDs = Set<String>()

        for objectID in processObjects {
            guard let pid = readProcessPID(objectID), pid > 0 else { continue }
            let bundleID = readProcessBundleID(objectID)
            if readBoolProperty(objectID, selector: kAudioProcessPropertyIsRunningOutput) {
                outputPIDs.insert(pid)
                if let bundleID, !bundleID.isEmpty {
                    outputBundleIDs.insert(bundleID)
                }
            }
            if readBoolProperty(objectID, selector: kAudioProcessPropertyIsRunningInput) {
                inputPIDs.insert(pid)
                if let bundleID, !bundleID.isEmpty {
                    inputBundleIDs.insert(bundleID)
                }
            }
        }

        return AudioActivitySnapshot(
            outputPIDs: outputPIDs,
            inputPIDs: inputPIDs,
            outputBundleIDs: outputBundleIDs,
            inputBundleIDs: inputBundleIDs
        )
    }

    @available(macOS 14.2, *)
    private func readProcessPID(_ objectID: AudioObjectID) -> Int32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.stride)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &pid)
        return status == noErr ? pid : nil
    }

    @available(macOS 14.2, *)
    private func readProcessBundleID(_ objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.stride)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &cfStr)
        guard status == noErr, let cfStr else { return nil }
        return cfStr.takeRetainedValue() as String
    }

    @available(macOS 14.2, *)
    private func readBoolProperty(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.stride)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }
}
