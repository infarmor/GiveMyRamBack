import Foundation

public struct FreezeEvaluationContext: Sendable {
    public let settings: EngineSettings
    public let memoryPressure: MemoryPressureLevel
    public let powerSource: PowerSourceKind
    public let audioSnapshot: AudioActivitySnapshot
    public let sleepAssertionPIDs: Set<Int32>
    public let now: Date
    public let wakeCooldownUntil: Date?

    public init(
        settings: EngineSettings,
        memoryPressure: MemoryPressureLevel,
        powerSource: PowerSourceKind = .ac,
        audioSnapshot: AudioActivitySnapshot,
        sleepAssertionPIDs: Set<Int32>,
        now: Date,
        wakeCooldownUntil: Date?
    ) {
        self.settings = settings
        self.memoryPressure = memoryPressure
        self.powerSource = powerSource
        self.audioSnapshot = audioSnapshot
        self.sleepAssertionPIDs = sleepAssertionPIDs
        self.now = now
        self.wakeCooldownUntil = wakeCooldownUntil
    }
}

public struct AppEvaluationOutcome: Sendable, Equatable {
    public let status: TrackedAppStatus
    public let shouldAutoFreeze: Bool
    public let protectionReasons: [ProtectionReason]
}

public enum FreezePolicy {
    public static let launchGraceSeconds: TimeInterval = 45
    public static let resumeCooldownSeconds: TimeInterval = 30
    public static let systemWakeGraceSeconds: TimeInterval = 20

    public static func effectiveIdleTimeoutSeconds(
        settings: EngineSettings,
        pressure: MemoryPressureLevel,
        powerSource: PowerSourceKind,
        rule: AppFreezeRule = .automatic
    ) -> TimeInterval {
        let baseMinutes = (rule == .fast) ? settings.fastModeMinutes : settings.idleTimeoutMinutes
        var timeout = max(60, baseMinutes * 60.0)

        if settings.batterySaverMode && powerSource == .battery {
            timeout *= 0.5
        }

        if settings.aggressivePressureMode {
            switch pressure {
            case .normal:
                break
            case .warning:
                timeout *= 0.5
            case .critical:
                timeout *= 0.25
            }
        }

        return max(60, timeout)
    }

    public static func evaluateApp(
        descriptor: RunningAppDescriptor,
        pids: [Int32],
        footprintBytes: UInt64,
        idleSeconds: TimeInterval,
        frozenRecord: FrozenRecord?,
        resumeCooldownUntil: Date?,
        context: FreezeEvaluationContext
    ) -> AppEvaluationOutcome {
        if let frozenRecord {
            return AppEvaluationOutcome(
                status: .frozen(since: frozenRecord.frozenAt, pidCount: frozenRecord.identities.count),
                shouldAutoFreeze: false,
                protectionReasons: []
            )
        }

        if descriptor.isFrontmost {
            return AppEvaluationOutcome(
                status: .active,
                shouldAutoFreeze: false,
                protectionReasons: [.frontmost]
            )
        }

        let rule = context.settings.rule(for: descriptor.bundleIdentifier)
        var reasons: [ProtectionReason] = []
        let pidSet = Set(pids)

        if context.settings.protectAudioApps {
            let hasOutputBundle = descriptor.bundleIdentifier.map {
                context.audioSnapshot.outputBundleIDs.contains($0)
            } ?? false
            let hasInputBundle = descriptor.bundleIdentifier.map {
                context.audioSnapshot.inputBundleIDs.contains($0)
            } ?? false

            if !pidSet.isDisjoint(with: context.audioSnapshot.outputPIDs) || hasOutputBundle {
                reasons.append(.playingAudio)
            }
            if !pidSet.isDisjoint(with: context.audioSnapshot.inputPIDs) || hasInputBundle {
                reasons.append(.usingMicrophone)
            }
        }

        if context.settings.protectSleepAssertions && !pidSet.isDisjoint(with: context.sleepAssertionPIDs) {
            reasons.append(.preventingSleep)
        }

        if context.settings.protectDevAndSystemTools &&
            ProcessScanner.isBuiltInSafelistedApp(
                bundleID: descriptor.bundleIdentifier,
                bundlePath: descriptor.bundlePath,
                name: descriptor.name
            ) {
            reasons.append(.builtInSafelist)
        }

        if rule == .protected {
            reasons.append(.userWhitelist)
        }

        if let wakeCooldownUntil = context.wakeCooldownUntil, context.now < wakeCooldownUntil {
            reasons.append(.cooldownAfterWake)
        } else if let resumeCooldownUntil, context.now < resumeCooldownUntil {
            reasons.append(.cooldownAfterWake)
        }

        if let launchDate = descriptor.launchDate,
           context.now.timeIntervalSince(launchDate) < launchGraceSeconds {
            reasons.append(.recentlyLaunched)
        }

        if !reasons.isEmpty {
            return AppEvaluationOutcome(
                status: .protected(reasons: reasons),
                shouldAutoFreeze: false,
                protectionReasons: reasons
            )
        }

        if !descriptor.isRegularApp {
            return AppEvaluationOutcome(
                status: .manualOnly,
                shouldAutoFreeze: false,
                protectionReasons: []
            )
        }

        guard context.settings.isAutoFreezeEnabled else {
            return AppEvaluationOutcome(
                status: .manualOnly,
                shouldAutoFreeze: false,
                protectionReasons: []
            )
        }

        let minBytes = UInt64(max(0, context.settings.minMemoryThresholdMB) * 1_048_576.0)
        if rule != .fast && footprintBytes < minBytes {
            return AppEvaluationOutcome(
                status: .belowThreshold,
                shouldAutoFreeze: false,
                protectionReasons: []
            )
        }

        let timeout = effectiveIdleTimeoutSeconds(
            settings: context.settings,
            pressure: context.memoryPressure,
            powerSource: context.powerSource,
            rule: rule
        )
        let remaining = timeout - idleSeconds
        if remaining <= 0 {
            return AppEvaluationOutcome(
                status: .countingDown(remainingSeconds: 0, totalSeconds: timeout),
                shouldAutoFreeze: true,
                protectionReasons: []
            )
        }

        return AppEvaluationOutcome(
            status: .countingDown(remainingSeconds: remaining, totalSeconds: timeout),
            shouldAutoFreeze: false,
            protectionReasons: []
        )
    }
}
