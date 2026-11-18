import Foundation

/// Mutable per-app / per-service bookkeeping carried between sampling ticks.
public struct TrackingState: Sendable, Equatable {
    public struct FootprintSample: Sendable, Equatable {
        public let date: Date
        public let bytes: UInt64
    }

    public var appIdleSeconds: [String: TimeInterval] = [:]
    public var serviceIdleSeconds: [String: TimeInterval] = [:]
    public var footprintHistory: [String: [FootprintSample]] = [:]
    /// Exponentially weighted CPU usage (percent of one core) while the app is in the background.
    public var backgroundCPU: [String: Double] = [:]

    public init() {}

    public mutating func resetIdle(_ key: String) {
        appIdleSeconds[key] = 0
        serviceIdleSeconds[key] = 0
    }

    public mutating func forget(_ key: String) {
        appIdleSeconds.removeValue(forKey: key)
        serviceIdleSeconds.removeValue(forKey: key)
        footprintHistory.removeValue(forKey: key)
        backgroundCPU.removeValue(forKey: key)
    }
}

/// Everything one evaluation pass needs, captured as plain values.
public struct SnapshotInput: Sendable {
    public var now: Date
    public var awakeDelta: TimeInterval
    public var settings: EngineSettings
    public var memoryPressure: MemoryPressureLevel
    public var powerSource: PowerSourceKind
    public var samplesByPID: [Int32: ProcessSample]
    public var cpuPercentByPID: [Int32: Double]
    public var runningApps: [RunningAppDescriptor]
    public var grouping: ProcessGroupingResult
    public var audio: AudioActivitySnapshot
    public var sleepAssertionPIDs: Set<Int32>
    public var visibleWindowPIDs: Set<Int32>
    public var frozenRecords: [String: FrozenRecord]
    public var resumeCooldowns: [String: Date]
    public var wakeCooldownUntil: Date?
    public var clipboardOwnerKey: String?

    public init(
        now: Date,
        awakeDelta: TimeInterval,
        settings: EngineSettings,
        memoryPressure: MemoryPressureLevel,
        powerSource: PowerSourceKind,
        samplesByPID: [Int32: ProcessSample],
        cpuPercentByPID: [Int32: Double],
        runningApps: [RunningAppDescriptor],
        grouping: ProcessGroupingResult,
        audio: AudioActivitySnapshot = AudioActivitySnapshot(),
        sleepAssertionPIDs: Set<Int32> = [],
        visibleWindowPIDs: Set<Int32> = [],
        frozenRecords: [String: FrozenRecord] = [:],
        resumeCooldowns: [String: Date] = [:],
        wakeCooldownUntil: Date? = nil,
        clipboardOwnerKey: String? = nil
    ) {
        self.now = now
        self.awakeDelta = awakeDelta
        self.settings = settings
        self.memoryPressure = memoryPressure
        self.powerSource = powerSource
        self.samplesByPID = samplesByPID
        self.cpuPercentByPID = cpuPercentByPID
        self.runningApps = runningApps
        self.grouping = grouping
        self.audio = audio
        self.sleepAssertionPIDs = sleepAssertionPIDs
        self.visibleWindowPIDs = visibleWindowPIDs
        self.frozenRecords = frozenRecords
        self.resumeCooldowns = resumeCooldowns
        self.wakeCooldownUntil = wakeCooldownUntil
        self.clipboardOwnerKey = clipboardOwnerKey
    }

    var policyContext: FreezeEvaluationContext {
        FreezeEvaluationContext(
            settings: settings,
            memoryPressure: memoryPressure,
            powerSource: powerSource,
            audioSnapshot: audio,
            sleepAssertionPIDs: sleepAssertionPIDs,
            now: now,
            wakeCooldownUntil: wakeCooldownUntil,
            visibleWindowPIDs: visibleWindowPIDs,
            clipboardOwnerKey: clipboardOwnerKey
        )
    }
}

public struct AppDecision: Sendable {
    public let descriptor: RunningAppDescriptor
    public let pids: [Int32]
    public let identities: [ProcessIdentity]
    public let footprintBytes: UInt64
    public let residentBytes: UInt64
    public let cpuPercent: Double
    public let backgroundCPUPercent: Double
    public let recentGrowthBytes: Int64
    public let idleSeconds: TimeInterval
    public let frozenRecord: FrozenRecord?
    public let outcome: AppEvaluationOutcome
}

public struct ServiceDecision: Sendable {
    public let candidate: GroupedServiceCandidate
    public let identities: [ProcessIdentity]
    public let frozenRecord: FrozenRecord?
    public let isOptedIn: Bool
    public let protection: ProtectionReason?
    public let backgroundCPUPercent: Double
    public let shouldAutoFreeze: Bool
}

/// Pure decision logic for one sampling tick. It never sends signals or touches AppKit: the
/// engine applies the returned decisions (freezing, events, publishing).
public enum SnapshotEvaluator {
    public static let minServiceFootprintBytes: UInt64 = 30 * 1_048_576
    /// Time constant (seconds) of the background CPU moving average.
    public static let cpuAverageTimeConstant: TimeInterval = 60

    /// Clamped awake time since the previous tick, immune to Mac sleep and wall-clock jumps.
    public static func awakeDelta(now: Date, previous: Date?, isAsleep: Bool, maxStep: TimeInterval) -> TimeInterval {
        guard !isAsleep, let previous else { return 0 }
        return min(maxStep, max(0, now.timeIntervalSince(previous)))
    }

    /// Frozen records none of whose processes are alive with the same (pid, start time) identity.
    public static func exitedRecordKeys(records: [FrozenRecord], samplesByPID: [Int32: ProcessSample]) -> [String] {
        records.compactMap { record in
            let alive = record.identities.contains { identity in
                guard let sample = samplesByPID[identity.pid] else { return false }
                return sample.startTimeSec == identity.startTimeSec && sample.startTimeUsec == identity.startTimeUsec
            }
            return alive ? nil : record.appKey
        }
    }

    public static func reclaimedDRAM(record: FrozenRecord?, residentNow: UInt64) -> UInt64 {
        guard let record, record.residentAtFreezeBytes > residentNow else { return 0 }
        return record.residentAtFreezeBytes - residentNow
    }

    public static func evaluate(
        _ input: SnapshotInput,
        state: inout TrackingState
    ) -> (apps: [AppDecision], services: [ServiceDecision]) {
        let context = input.policyContext
        let alpha = input.awakeDelta > 0 ? 1 - exp(-input.awakeDelta / cpuAverageTimeConstant) : 0

        var apps: [AppDecision] = []
        apps.reserveCapacity(input.runningApps.count)
        var seenAppKeys = Set<String>()

        for desc in input.runningApps {
            let pids = input.grouping.appPIDsByKey[desc.key] ?? []
            guard !pids.isEmpty else { continue }
            seenAppKeys.insert(desc.key)

            let footprint = pids.reduce(UInt64(0)) { $0 + (input.samplesByPID[$1]?.footprintBytes ?? 0) }
            let resident = pids.reduce(UInt64(0)) { $0 + (input.samplesByPID[$1]?.residentBytes ?? 0) }
            let cpu = pids.reduce(0.0) { $0 + (input.cpuPercentByPID[$1] ?? 0) }
            let frozenRecord = input.frozenRecords[desc.key]

            let growth = updateGrowth(
                state: &state, key: desc.key, now: input.now, footprintBytes: footprint, isFrontmost: desc.isFrontmost
            )

            // Idle clock. A window the user can see counts as "in use": the countdown starts only
            // once it is hidden, minimised, or covered by other windows.
            let isVisibleOnScreen = input.settings.keepVisibleWindowsAwake &&
                pids.contains { input.visibleWindowPIDs.contains($0) }
            if desc.isFrontmost || (isVisibleOnScreen && frozenRecord == nil) {
                state.appIdleSeconds[desc.key] = 0
            } else if frozenRecord == nil {
                state.appIdleSeconds[desc.key] = (state.appIdleSeconds[desc.key] ?? 0) + input.awakeDelta
            }

            // Background CPU average (what freezing would save on battery).
            if desc.isFrontmost {
                state.backgroundCPU[desc.key] = 0
            } else if frozenRecord == nil, alpha > 0 {
                let prev = state.backgroundCPU[desc.key] ?? cpu
                state.backgroundCPU[desc.key] = prev + (cpu - prev) * alpha
            }

            let idle = state.appIdleSeconds[desc.key] ?? 0
            let backgroundCPU = state.backgroundCPU[desc.key] ?? 0
            let outcome = FreezePolicy.evaluateApp(
                descriptor: desc,
                pids: pids,
                footprintBytes: footprint,
                idleSeconds: idle,
                frozenRecord: frozenRecord,
                resumeCooldownUntil: input.resumeCooldowns[desc.key],
                context: context,
                backgroundCPUPercent: backgroundCPU
            )

            apps.append(AppDecision(
                descriptor: desc,
                pids: pids,
                identities: pids.compactMap { input.samplesByPID[$0]?.identity },
                footprintBytes: footprint,
                residentBytes: resident,
                cpuPercent: cpu,
                backgroundCPUPercent: backgroundCPU,
                recentGrowthBytes: growth,
                idleSeconds: idle,
                frozenRecord: frozenRecord,
                outcome: outcome
            ))
        }

        var services: [ServiceDecision] = []
        var seenServiceKeys = Set<String>()

        for candidate in input.grouping.standaloneServices {
            let key = candidate.serviceKey
            let frozenRecord = input.frozenRecords[key]
            let isOptedIn = input.settings.autoFreezeServiceKeys.contains(key)
            if candidate.footprintBytes < minServiceFootprintBytes && frozenRecord == nil && !isOptedIn {
                continue
            }
            seenServiceKeys.insert(key)

            let protection = FreezePolicy.serviceProtection(pids: candidate.pids, context: context)
            if frozenRecord == nil && isOptedIn && protection == nil {
                state.serviceIdleSeconds[key] = (state.serviceIdleSeconds[key] ?? 0) + input.awakeDelta
            } else if protection != nil {
                state.serviceIdleSeconds[key] = 0
            }
            if frozenRecord == nil, alpha > 0 {
                let prev = state.backgroundCPU[key] ?? candidate.cpuPercent
                state.backgroundCPU[key] = prev + (candidate.cpuPercent - prev) * alpha
            }
            let backgroundCPU = state.backgroundCPU[key] ?? 0

            let shouldFreeze = frozenRecord == nil && isOptedIn && protection == nil &&
                FreezePolicy.shouldAutoFreezeService(
                    idleSeconds: state.serviceIdleSeconds[key] ?? 0,
                    resumeCooldownUntil: input.resumeCooldowns[key],
                    backgroundCPUPercent: backgroundCPU,
                    context: context
                )

            services.append(ServiceDecision(
                candidate: candidate,
                identities: candidate.pids.compactMap { input.samplesByPID[$0]?.identity },
                frozenRecord: frozenRecord,
                isOptedIn: isOptedIn,
                protection: protection,
                backgroundCPUPercent: backgroundCPU,
                shouldAutoFreeze: shouldFreeze
            ))
        }

        // Drop bookkeeping for apps and services that are gone.
        state.appIdleSeconds = state.appIdleSeconds.filter { seenAppKeys.contains($0.key) }
        state.footprintHistory = state.footprintHistory.filter { seenAppKeys.contains($0.key) }
        state.serviceIdleSeconds = state.serviceIdleSeconds.filter { seenServiceKeys.contains($0.key) }
        state.backgroundCPU = state.backgroundCPU.filter {
            seenAppKeys.contains($0.key) || seenServiceKeys.contains($0.key)
        }

        return (apps, services)
    }

    /// Footprint growth over the last ~2 minutes in the background (0 until 20 s of history).
    static func updateGrowth(
        state: inout TrackingState,
        key: String,
        now: Date,
        footprintBytes: UInt64,
        isFrontmost: Bool
    ) -> Int64 {
        let sample = TrackingState.FootprintSample(date: now, bytes: footprintBytes)
        if isFrontmost {
            state.footprintHistory[key] = [sample]
            return 0
        }
        var samples = state.footprintHistory[key] ?? []
        samples.append(sample)
        let cutoff = now.addingTimeInterval(-120)
        samples.removeAll { $0.date < cutoff }
        state.footprintHistory[key] = samples

        guard let oldest = samples.first, now.timeIntervalSince(oldest.date) >= 20 else { return 0 }
        return Int64(footprintBytes) - Int64(oldest.bytes)
    }

    public static func makeTrackedApp(
        _ decision: AppDecision,
        frozenRecord: FrozenRecord?,
        status: TrackedAppStatus,
        rule: AppFreezeRule
    ) -> TrackedApp {
        let desc = decision.descriptor
        return TrackedApp(
            id: desc.key,
            bundleIdentifier: desc.bundleIdentifier,
            name: desc.name,
            bundlePath: desc.bundlePath,
            mainPID: desc.mainPID,
            pids: decision.pids,
            footprintBytes: decision.footprintBytes,
            residentBytes: decision.residentBytes,
            reclaimedDRAMBytes: reclaimedDRAM(record: frozenRecord, residentNow: decision.residentBytes),
            recentGrowthBytes: decision.recentGrowthBytes,
            cpuPercent: decision.cpuPercent,
            isFrozen: frozenRecord != nil,
            status: status,
            rule: rule,
            idleSeconds: decision.idleSeconds,
            isRegularApp: desc.isRegularApp,
            backgroundCPUPercent: decision.backgroundCPUPercent,
            frozenReason: frozenRecord?.cause?.localized
        )
    }

    public static func makeTrackedService(_ decision: ServiceDecision, frozenRecord: FrozenRecord?) -> TrackedService {
        let c = decision.candidate
        return TrackedService(
            serviceKey: c.serviceKey,
            mainPID: c.mainPID,
            pids: c.pids,
            name: c.name,
            executablePath: c.executablePath,
            footprintBytes: c.footprintBytes,
            residentBytes: c.residentBytes,
            reclaimedDRAMBytes: reclaimedDRAM(record: frozenRecord, residentNow: c.residentBytes),
            cpuPercent: c.cpuPercent,
            isFrozen: frozenRecord != nil,
            isProtected: decision.protection != nil,
            protectionReason: decision.protection,
            isAutoFreezeEnabled: decision.isOptedIn
        )
    }
}
