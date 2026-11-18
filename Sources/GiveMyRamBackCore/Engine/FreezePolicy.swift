import Foundation

public struct FreezeEvaluationContext: Sendable {
    public let settings: EngineSettings
    public let memoryPressure: MemoryPressureLevel
    public let powerSource: PowerSourceKind
    public let audioSnapshot: AudioActivitySnapshot
    public let sleepAssertionPIDs: Set<Int32>
    public let now: Date
    public let wakeCooldownUntil: Date?
    /// PIDs that own a meaningfully visible (not fully covered) normal window on any display.
    public let visibleWindowPIDs: Set<Int32>
    /// App key of the app that most recently wrote to the general pasteboard.
    public let clipboardOwnerKey: String?

    public init(
        settings: EngineSettings,
        memoryPressure: MemoryPressureLevel,
        powerSource: PowerSourceKind = .ac,
        audioSnapshot: AudioActivitySnapshot,
        sleepAssertionPIDs: Set<Int32>,
        now: Date,
        wakeCooldownUntil: Date?,
        visibleWindowPIDs: Set<Int32> = [],
        clipboardOwnerKey: String? = nil
    ) {
        self.visibleWindowPIDs = visibleWindowPIDs
        self.clipboardOwnerKey = clipboardOwnerKey
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
    /// In «only under memory pressure» mode, background apps averaging at least this much CPU
    /// are still frozen under normal pressure: there freezing saves battery, not RAM.
    public static let cpuHogThresholdPercent: Double = 5

    /// Whether the pressure-only mode currently holds back an idle-timeout freeze.
    static func isHeldUntilPressure(
        settings: EngineSettings,
        pressure: MemoryPressureLevel,
        rule: AppFreezeRule,
        backgroundCPUPercent: Double
    ) -> Bool {
        settings.freezeOnlyUnderPressure &&
            pressure == .normal &&
            rule != .fast &&
            backgroundCPUPercent < cpuHogThresholdPercent
    }

    /// Protection that applies to a standalone background service.
    public static func serviceProtection(pids: [Int32], context: FreezeEvaluationContext) -> ProtectionReason? {
        let pidSet = Set(pids)
        let settings = context.settings
        let audio = context.audioSnapshot
        if settings.protectAudioApps && !pidSet.isDisjoint(with: audio.inputPIDs) {
            return .usingMicrophone
        }
        if settings.protectAudioApps && !pidSet.isDisjoint(with: audio.outputPIDs) {
            return .playingAudio
        }
        if settings.protectSleepAssertions && !pidSet.isDisjoint(with: context.sleepAssertionPIDs) {
            return .preventingSleep
        }
        return nil
    }

    /// Auto-freeze decision for a service the user opted in (protection already checked).
    public static func shouldAutoFreezeService(
        idleSeconds: TimeInterval,
        resumeCooldownUntil: Date?,
        backgroundCPUPercent: Double,
        context: FreezeEvaluationContext
    ) -> Bool {
        guard context.settings.isAutoFreezeEnabled else { return false }
        if let wake = context.wakeCooldownUntil, context.now < wake { return false }
        if let cooldown = resumeCooldownUntil, context.now < cooldown { return false }
        let timeout = effectiveIdleTimeoutSeconds(
            settings: context.settings,
            pressure: context.memoryPressure,
            powerSource: context.powerSource
        )
        guard idleSeconds >= timeout else { return false }
        return !isHeldUntilPressure(
            settings: context.settings,
            pressure: context.memoryPressure,
            rule: .automatic,
            backgroundCPUPercent: backgroundCPUPercent
        )
    }

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
        context: FreezeEvaluationContext,
        backgroundCPUPercent: Double = 0
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

        if context.settings.keepVisibleWindowsAwake && !pidSet.isDisjoint(with: context.visibleWindowPIDs) {
            reasons.append(.visibleOnScreen)
        }

        if context.settings.protectClipboardOwner, let owner = context.clipboardOwnerKey, owner == descriptor.key {
            reasons.append(.clipboardOwner)
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

        // The memory threshold applies before any "manual only" outcome, otherwise batch freeze
        // ("Вернуть RAM сейчас") would pause tiny apps whenever auto-freeze is off.
        let minBytes = UInt64(max(0, context.settings.minMemoryThresholdMB) * 1_048_576.0)
        if rule != .fast && footprintBytes < minBytes {
            return AppEvaluationOutcome(
                status: .belowThreshold,
                shouldAutoFreeze: false,
                protectionReasons: []
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

        let timeout = effectiveIdleTimeoutSeconds(
            settings: context.settings,
            pressure: context.memoryPressure,
            powerSource: context.powerSource,
            rule: rule
        )
        let remaining = timeout - idleSeconds
        if remaining <= 0 {
            if isHeldUntilPressure(
                settings: context.settings,
                pressure: context.memoryPressure,
                rule: rule,
                backgroundCPUPercent: backgroundCPUPercent
            ) {
                return AppEvaluationOutcome(
                    status: .waitingForPressure,
                    shouldAutoFreeze: false,
                    protectionReasons: []
                )
            }
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
