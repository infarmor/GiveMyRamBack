import Darwin
import Foundation

public struct ProcessScanResult: Sendable {
    public let samplesByPID: [Int32: ProcessSample]
    public let cpuPercentByPID: [Int32: Double]
    public let protectedAncestors: Set<Int32>
}

public struct ProcessGroupingResult: Sendable {
    public let appPIDsByKey: [String: [Int32]]
    public let standaloneServices: [GroupedServiceCandidate]
}

public struct GroupedServiceCandidate: Sendable, Equatable {
    public let serviceKey: String
    public let mainPID: Int32
    public let pids: [Int32]
    public let name: String
    public let executablePath: String
    public let footprintBytes: UInt64
    public let residentBytes: UInt64
    public let cpuPercent: Double
    public let isStopped: Bool
}

public final class ProcessScanner: @unchecked Sendable {
    private let currentUID: uid_t = getuid()
    private let currentPID: pid_t = getpid()
    private let timebaseNumer: UInt64
    private let timebaseDenom: UInt64

    private var previousCPUTicks: [Int32: (startSec: UInt64, startUsec: UInt64, ticks: UInt64)] = [:]
    private var previousSampleDate: Date?

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        self.timebaseNumer = UInt64(max(1, info.numer))
        self.timebaseDenom = UInt64(max(1, info.denom))
    }

    public func scanUserProcesses() -> ProcessScanResult {
        let now = Date()
        let elapsedSeconds = previousSampleDate.map { max(0.1, now.timeIntervalSince($0)) }

        let allPIDs = listAllPIDs()
        let ancestors = computeAncestorPIDs(startingAt: currentPID)

        var samples: [Int32: ProcessSample] = [:]
        samples.reserveCapacity(allPIDs.count / 2)

        var cpuByPID: [Int32: Double] = [:]
        var nextCPUTicks: [Int32: (startSec: UInt64, startUsec: UInt64, ticks: UInt64)] = [:]

        for pid in allPIDs where pid > 0 {
            guard let bsd = Self.readBSDInfo(pid: pid) else { continue }
            guard bsd.pbi_uid == currentUID else { continue }

            var rusage = rusage_info_v4()
            let rusageOK = withUnsafeMutablePointer(to: &rusage) { ptr -> Bool in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rusagePtr in
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, rusagePtr) == 0
                }
            }

            let footprint = rusageOK ? rusage.ri_phys_footprint : 0
            let resident = rusageOK ? rusage.ri_resident_size : 0
            let cpuTicks = rusageOK ? (rusage.ri_user_time &+ rusage.ri_system_time) : 0
            let path = readProcessPath(pid: pid)
            let rawName = extractProcessName(bsd: bsd, path: path)
            let isStopped = (bsd.pbi_status == UInt32(SSTOP))

            let sample = ProcessSample(
                pid: pid,
                ppid: Int32(bsd.pbi_ppid),
                uid: bsd.pbi_uid,
                startTimeSec: bsd.pbi_start_tvsec,
                startTimeUsec: bsd.pbi_start_tvusec,
                name: rawName,
                executablePath: path,
                footprintBytes: footprint,
                residentBytes: resident,
                cpuTicks: cpuTicks,
                isStopped: isStopped
            )
            samples[pid] = sample

            nextCPUTicks[pid] = (bsd.pbi_start_tvsec, bsd.pbi_start_tvusec, cpuTicks)

            if let elapsedSeconds,
               let prev = previousCPUTicks[pid],
               prev.startSec == bsd.pbi_start_tvsec,
               prev.startUsec == bsd.pbi_start_tvusec,
               cpuTicks >= prev.ticks {
                let deltaTicks = cpuTicks - prev.ticks
                let deltaNano = (Double(deltaTicks) * Double(timebaseNumer)) / Double(timebaseDenom)
                let cpuPct = (deltaNano / (elapsedSeconds * 1_000_000_000.0)) * 100.0
                cpuByPID[pid] = max(0, cpuPct)
            } else {
                cpuByPID[pid] = 0
            }
        }

        previousCPUTicks = nextCPUTicks
        previousSampleDate = now

        return ProcessScanResult(
            samplesByPID: samples,
            cpuPercentByPID: cpuByPID,
            protectedAncestors: ancestors
        )
    }

    public static func readBSDInfo(pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let bytesRead = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize)
        guard bytesRead == expectedSize else { return nil }
        return info
    }

    private func listAllPIDs() -> [Int32] {
        let initialCount = max(256, Int(proc_listallpids(nil, 0)))
        let capacity = initialCount + 128
        var pids = [Int32](repeating: 0, count: capacity)
        let byteSize = Int32(capacity * MemoryLayout<Int32>.stride)
        let actualCount = pids.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return 0 }
            return proc_listallpids(base, byteSize)
        }
        guard actualCount > 0 else { return [] }
        return Array(pids.prefix(Int(actualCount)))
    }

    private func computeAncestorPIDs(startingAt pid: Int32) -> Set<Int32> {
        var result: Set<Int32> = [pid]
        var cursor = pid
        for _ in 0..<64 {
            guard cursor > 1, let info = Self.readBSDInfo(pid: cursor) else { break }
            let ppid = Int32(info.pbi_ppid)
            if ppid <= 1 || result.contains(ppid) {
                break
            }
            result.insert(ppid)
            cursor = ppid
        }
        return result
    }

    private func readProcessPath(pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let len = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return 0 }
            return proc_pidpath(pid, base, UInt32(ptr.count))
        }
        guard len > 0 else { return "" }
        return buffer.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return "" }
            return String(decoding: Data(bytes: base, count: Int(len)), as: UTF8.self)
        }
    }

    private func extractProcessName(bsd: proc_bsdinfo, path: String) -> String {
        let registered = withUnsafeBytes(of: bsd.pbi_name) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        if !registered.isEmpty {
            return registered
        }
        let comm = withUnsafeBytes(of: bsd.pbi_comm) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        if !path.isEmpty {
            let last = (path as NSString).lastPathComponent
            if !last.isEmpty && last.count >= comm.count {
                return last
            }
        }
        return comm.isEmpty ? "pid-\(bsd.pbi_pid)" : comm
    }

    // MARK: - Pure Process Grouping & Safety Classification

    public static func groupProcesses(
        samplesByPID: [Int32: ProcessSample],
        cpuPercentByPID: [Int32: Double],
        apps: [RunningAppDescriptor],
        protectedAncestors: Set<Int32>,
        currentPID: Int32
    ) -> ProcessGroupingResult {
        var childrenByPPID: [Int32: [Int32]] = [:]
        for sample in samplesByPID.values where sample.ppid > 1 && sample.ppid != sample.pid {
            childrenByPPID[sample.ppid, default: []].append(sample.pid)
        }

        let appMainPIDs = Set(apps.map(\.mainPID))
        var claimedPIDs = Set<Int32>()
        var ownedByKey: [String: Set<Int32>] = [:]

        // Pass 1: Claim each app's main PID + exact ppid subtree
        for app in apps {
            var ownedPIDs = Set<Int32>()
            if samplesByPID[app.mainPID] != nil && !claimedPIDs.contains(app.mainPID) {
                ownedPIDs.insert(app.mainPID)
            }

            var queue: [Int32] = [app.mainPID]
            var visited: Set<Int32> = [app.mainPID]
            while !queue.isEmpty {
                let current = queue.removeFirst()
                for child in childrenByPPID[current] ?? [] {
                    if visited.contains(child) { continue }
                    if appMainPIDs.contains(child) && child != app.mainPID { continue }
                    if claimedPIDs.contains(child) { continue }
                    visited.insert(child)
                    ownedPIDs.insert(child)
                    queue.append(child)
                }
            }

            ownedPIDs.subtract(protectedAncestors)
            ownedPIDs.remove(currentPID)
            ownedByKey[app.key] = ownedPIDs
            claimedPIDs.formUnion(ownedPIDs)
        }

        // Pass 2: Attach unclaimed LaunchServices/XPC helpers inside unique app bundles
        var bundleInstanceCounts: [String: Int] = [:]
        for app in apps {
            if let bundlePath = app.bundlePath, !bundlePath.isEmpty {
                bundleInstanceCounts[bundlePath, default: 0] += 1
            }
        }

        for app in apps {
            guard let bundlePath = app.bundlePath,
                  !bundlePath.isEmpty,
                  bundleInstanceCounts[bundlePath] == 1 else {
                continue
            }
            let prefix = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"
            for sample in samplesByPID.values {
                guard !claimedPIDs.contains(sample.pid),
                      !protectedAncestors.contains(sample.pid),
                      sample.pid != currentPID,
                      !appMainPIDs.contains(sample.pid),
                      sample.executablePath.hasPrefix(prefix) else {
                    continue
                }
                ownedByKey[app.key, default: []].insert(sample.pid)
                claimedPIDs.insert(sample.pid)
            }
        }

        var appPIDsByKey: [String: [Int32]] = [:]
        for app in apps {
            let owned = ownedByKey[app.key] ?? []
            appPIDsByKey[app.key] = sortPIDsMainLast(Array(owned), mainPID: app.mainPID)
        }

        // Remaining user processes form standalone service candidates
        let unclaimedSamples = samplesByPID.values.filter { sample in
            !claimedPIDs.contains(sample.pid) &&
            !protectedAncestors.contains(sample.pid) &&
            sample.pid != currentPID &&
            !isSystemCriticalProcess(path: sample.executablePath, name: sample.name, bundleID: nil)
        }

        let unclaimedPIDs = Set(unclaimedSamples.map(\.pid))
        var serviceRoots: [Int32] = []
        for sample in unclaimedSamples {
            if !unclaimedPIDs.contains(sample.ppid) {
                serviceRoots.append(sample.pid)
            }
        }

        var services: [GroupedServiceCandidate] = []
        var usedServicePIDs = Set<Int32>()

        for rootPID in serviceRoots {
            guard let rootSample = samplesByPID[rootPID] else { continue }
            var subtreePIDs: [Int32] = []
            var queue: [Int32] = [rootPID]
            var visited: Set<Int32> = [rootPID]
            while !queue.isEmpty {
                let pid = queue.removeFirst()
                if unclaimedPIDs.contains(pid) && !usedServicePIDs.contains(pid) {
                    subtreePIDs.append(pid)
                    usedServicePIDs.insert(pid)
                }
                for child in childrenByPPID[pid] ?? [] where unclaimedPIDs.contains(child) && !visited.contains(child) {
                    visited.insert(child)
                    queue.append(child)
                }
            }

            guard !subtreePIDs.isEmpty else { continue }
            let totalBytes = subtreePIDs.reduce(UInt64(0)) { $0 + (samplesByPID[$1]?.footprintBytes ?? 0) }
            let totalResident = subtreePIDs.reduce(UInt64(0)) { $0 + (samplesByPID[$1]?.residentBytes ?? 0) }
            let totalCPU = subtreePIDs.reduce(0.0) { $0 + (cpuPercentByPID[$1] ?? 0) }
            let allStopped = subtreePIDs.allSatisfy { samplesByPID[$0]?.isStopped ?? false }
            let key = serviceKey(name: rootSample.name, executablePath: rootSample.executablePath)

            services.append(
                GroupedServiceCandidate(
                    serviceKey: key,
                    mainPID: rootPID,
                    pids: sortPIDsMainLast(subtreePIDs, mainPID: rootPID),
                    name: rootSample.name,
                    executablePath: rootSample.executablePath,
                    footprintBytes: totalBytes,
                    residentBytes: totalResident,
                    cpuPercent: totalCPU,
                    isStopped: allStopped
                )
            )
        }

        return ProcessGroupingResult(
            appPIDsByKey: appPIDsByKey,
            standaloneServices: services.sorted { $0.footprintBytes > $1.footprintBytes }
        )
    }

    private static func sortPIDsMainLast(_ pids: [Int32], mainPID: Int32) -> [Int32] {
        let helpers = pids.filter { $0 != mainPID }.sorted()
        return pids.contains(mainPID) ? helpers + [mainPID] : helpers
    }

    public static func serviceKey(name: String, executablePath: String) -> String {
        if !executablePath.isEmpty {
            return "svc:\(executablePath)"
        }
        return "svc:\(name)"
    }

    public static let builtInProtectedBundleIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.Spotlight",
        "com.apple.loginwindow",
        "com.apple.systempreferences",
        "com.apple.ActivityMonitor",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "com.apple.dt.Xcode",
        "com.raycast.macos",
        "com.runningwithcrayons.Alfred",
        "com.1password.1password",
        "com.bitwarden.desktop",
        "io.tailscale.ipn.macsys",
        "com.docker.docker",
        "dev.orbstack.OrbStack",
        "org.pqrs.Karabiner-Elements",
        "dev.cryoram.CryoRAM",
        "dev.givemyramback.app"
    ]

    public static func isBuiltInSafelistedApp(bundleID: String?, bundlePath: String?, name: String) -> Bool {
        if let bundleID, builtInProtectedBundleIDs.contains(bundleID) {
            return true
        }
        if let bundleID, bundleID.hasPrefix("com.apple.") {
            // Protect core Apple system & utility apps (Finder, System Settings, Security, etc.),
            // while still allowing heavy Apple user apps like Safari/Pages/Keynote/Preview.
            let protectedPrefixes = [
                "com.apple.CoreServices",
                "com.apple.Security",
                "com.apple.ScreenTime",
                "com.apple.VoiceOver",
                "com.apple.universalaccess"
            ]
            if protectedPrefixes.contains(where: { bundleID.hasPrefix($0) }) {
                return true
            }
        }
        if let bundlePath, bundlePath.hasPrefix("/System/Library/CoreServices/") {
            return true
        }
        let criticalNames: Set<String> = [
            "Finder",
            "Dock",
            "WindowServer",
            "CryoRAM",
            "Give my ram back",
            "GiveMyRamBack",
            "loginwindow"
        ]
        return criticalNames.contains(name)
    }

    public static func isSystemCriticalProcess(path: String, name: String, bundleID: String?) -> Bool {
        if isBuiltInSafelistedApp(bundleID: bundleID, bundlePath: path, name: name) {
            return true
        }
        let protectedPathPrefixes = [
            "/System/",
            "/usr/",
            "/bin/",
            "/sbin/",
            "/Library/Apple/"
        ]
        if protectedPathPrefixes.contains(where: { path.hasPrefix($0) }) {
            return true
        }
        let lowerName = name.lowercased()
        let criticalSubstrings = [
            "windowserver",
            "launchd",
            "loginwindow",
            "cfprefsd",
            "distnoted",
            "usernoted",
            "trustd",
            "secd",
            "keychain",
            "icloud",
            "cloudd",
            "mds",
            "spotlight",
            "karabiner",
            "cryoram",
            "givemyramback",
            "give my ram back",
            "ssh-agent"
        ]
        return criticalSubstrings.contains { lowerName.contains($0) }
    }
}
