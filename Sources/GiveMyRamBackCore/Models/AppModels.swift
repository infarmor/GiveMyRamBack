import Foundation

public enum MemoryPressureLevel: String, Codable, Sendable, CaseIterable {
    case normal
    case warning
    case critical

    public var displayTitle: String {
        switch self {
        case .normal: return String(localized: "Норма")
        case .warning: return String(localized: "Нагрузка")
        case .critical: return String(localized: "Критично")
        }
    }
}

public enum PowerSourceKind: String, Codable, Sendable {
    case ac
    case battery
    case unknown

    public var displayTitle: String {
        switch self {
        case .ac: return String(localized: "Сеть")
        case .battery: return String(localized: "Батарея")
        case .unknown: return String(localized: "Питание")
        }
    }
}

public struct SystemMemoryStats: Sendable, Equatable {
    public let totalPhysicalBytes: UInt64
    public let appMemoryBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let cachedFilesBytes: UInt64
    public let freeBytes: UInt64
    public let swapUsedBytes: UInt64
    public let swapTotalBytes: UInt64
    public let pressure: MemoryPressureLevel
    public let powerSource: PowerSourceKind

    public var usedBytes: UInt64 {
        appMemoryBytes + wiredBytes + compressedBytes
    }

    public var usedRatio: Double {
        guard totalPhysicalBytes > 0 else { return 0 }
        return min(1.0, Double(usedBytes) / Double(totalPhysicalBytes))
    }

    public var compressedRatio: Double {
        guard totalPhysicalBytes > 0 else { return 0 }
        return min(1.0, Double(compressedBytes) / Double(totalPhysicalBytes))
    }

    public init(
        totalPhysicalBytes: UInt64 = 0,
        appMemoryBytes: UInt64 = 0,
        wiredBytes: UInt64 = 0,
        compressedBytes: UInt64 = 0,
        cachedFilesBytes: UInt64 = 0,
        freeBytes: UInt64 = 0,
        swapUsedBytes: UInt64 = 0,
        swapTotalBytes: UInt64 = 0,
        pressure: MemoryPressureLevel = .normal,
        powerSource: PowerSourceKind = .unknown
    ) {
        self.totalPhysicalBytes = totalPhysicalBytes
        self.appMemoryBytes = appMemoryBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedFilesBytes = cachedFilesBytes
        self.freeBytes = freeBytes
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.pressure = pressure
        self.powerSource = powerSource
    }
}

public struct MemoryHistoryPoint: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let usedRatio: Double
    public let compressedRatio: Double
    public let reclaimedDRAMBytes: UInt64

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        usedRatio: Double,
        compressedRatio: Double,
        reclaimedDRAMBytes: UInt64
    ) {
        self.id = id
        self.timestamp = timestamp
        self.usedRatio = usedRatio
        self.compressedRatio = compressedRatio
        self.reclaimedDRAMBytes = reclaimedDRAMBytes
    }
}

public struct ProcessIdentity: Codable, Hashable, Sendable {
    public let pid: Int32
    public let startTimeSec: UInt64
    public let startTimeUsec: UInt64
    public let name: String

    public init(pid: Int32, startTimeSec: UInt64, startTimeUsec: UInt64, name: String) {
        self.pid = pid
        self.startTimeSec = startTimeSec
        self.startTimeUsec = startTimeUsec
        self.name = name
    }
}

public struct ProcessSample: Sendable, Identifiable, Equatable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let ppid: Int32
    public let uid: UInt32
    public let startTimeSec: UInt64
    public let startTimeUsec: UInt64
    public let name: String
    public let executablePath: String
    public let footprintBytes: UInt64
    public let residentBytes: UInt64
    public let cpuTicks: UInt64
    public let isStopped: Bool

    public var identity: ProcessIdentity {
        ProcessIdentity(
            pid: pid,
            startTimeSec: startTimeSec,
            startTimeUsec: startTimeUsec,
            name: name
        )
    }

    public init(
        pid: Int32,
        ppid: Int32,
        uid: UInt32,
        startTimeSec: UInt64,
        startTimeUsec: UInt64,
        name: String,
        executablePath: String,
        footprintBytes: UInt64,
        residentBytes: UInt64 = 0,
        cpuTicks: UInt64,
        isStopped: Bool
    ) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.startTimeSec = startTimeSec
        self.startTimeUsec = startTimeUsec
        self.name = name
        self.executablePath = executablePath
        self.footprintBytes = footprintBytes
        self.residentBytes = residentBytes
        self.cpuTicks = cpuTicks
        self.isStopped = isStopped
    }
}

public struct RunningAppDescriptor: Sendable, Equatable {
    public let key: String
    public let mainPID: Int32
    public let name: String
    public let bundleIdentifier: String?
    public let bundlePath: String?
    public let isRegularApp: Bool
    public let isFrontmost: Bool
    public let isHidden: Bool
    public let launchDate: Date?

    public init(
        key: String,
        mainPID: Int32,
        name: String,
        bundleIdentifier: String?,
        bundlePath: String?,
        isRegularApp: Bool,
        isFrontmost: Bool,
        isHidden: Bool,
        launchDate: Date?
    ) {
        self.key = key
        self.mainPID = mainPID
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.isRegularApp = isRegularApp
        self.isFrontmost = isFrontmost
        self.isHidden = isHidden
        self.launchDate = launchDate
    }
}

public enum AppFreezeRule: String, Codable, Sendable, CaseIterable {
    case automatic
    case fast
    case protected

    public var displayTitle: String {
        switch self {
        case .automatic: return String(localized: "Авто")
        case .fast: return String(localized: "Быстро")
        case .protected: return String(localized: "Защита")
        }
    }
}

public enum MenuBarDisplayMode: String, Codable, Sendable, CaseIterable {
    case iconOnly
    case frozenCount
    case frozenAndRAM

    public var displayTitle: String {
        switch self {
        case .iconOnly: return String(localized: "Только иконка")
        case .frozenCount: return String(localized: "Иконка + счётчик")
        case .frozenAndRAM: return String(localized: "Счётчик + RAM")
        }
    }
}

public enum ProtectionReason: String, Hashable, Sendable, Codable {
    case frontmost
    case playingAudio
    case usingMicrophone
    case preventingSleep
    case builtInSafelist
    case userWhitelist
    case cooldownAfterWake
    case recentlyLaunched
    case visibleOnScreen
    case clipboardOwner

    public var shortLabel: String {
        switch self {
        case .frontmost: return String(localized: "Активно")
        case .playingAudio: return String(localized: "Аудио")
        case .usingMicrophone: return String(localized: "Микрофон")
        case .preventingSleep: return String(localized: "Видео / Задача")
        case .builtInSafelist: return String(localized: "Система / Dev")
        case .userWhitelist: return String(localized: "Белый список")
        case .cooldownAfterWake: return String(localized: "Пауза после пробуждения")
        case .recentlyLaunched: return String(localized: "Недавно запущено")
        case .visibleOnScreen: return String(localized: "Окно на экране")
        case .clipboardOwner: return String(localized: "Буфер обмена")
        }
    }
}

public enum TrackedAppStatus: Equatable, Sendable {
    case active
    case frozen(since: Date, pidCount: Int)
    case protected(reasons: [ProtectionReason])
    case countingDown(remainingSeconds: TimeInterval, totalSeconds: TimeInterval)
    case belowThreshold
    case manualOnly
    /// Idle long enough, but «only under memory pressure» mode waits for RAM to run low.
    case waitingForPressure
}

public struct TrackedApp: Identifiable, Sendable, Equatable {
    public let id: String
    public let bundleIdentifier: String?
    public let name: String
    public let bundlePath: String?
    public let mainPID: Int32
    public let pids: [Int32]
    public let footprintBytes: UInt64
    public let residentBytes: UInt64
    public let reclaimedDRAMBytes: UInt64
    public let recentGrowthBytes: Int64
    public let cpuPercent: Double
    public let isFrozen: Bool
    public let status: TrackedAppStatus
    public let rule: AppFreezeRule
    public let idleSeconds: TimeInterval
    /// `false` for menu-bar agents / accessory apps (no Dock icon). They never become frontmost,
    /// so nothing would wake them after a batch freeze.
    public let isRegularApp: Bool
    /// Average CPU while in the background (what freezing would save).
    public let backgroundCPUPercent: Double
    /// Why the app was frozen (for the «Почему?» explanation), if it is frozen.
    public let frozenReason: String?

    public var processCount: Int { pids.count }
    public var isWhitelisted: Bool { rule == .protected }
    public var isFastRule: Bool { rule == .fast }
    public var isMemoryGrowing: Bool { recentGrowthBytes >= 80 * 1_048_576 && !isFrozen }

    public var isEligibleForBatchFreezeNow: Bool {
        guard !isFrozen else { return false }
        switch status {
        case .countingDown, .waitingForPressure:
            return true
        case .manualOnly:
            // Accessory/menu-bar agents (Rectangle, AltTab, clipboard managers…) only when the user
            // explicitly opted them in with the «Быстро» rule.
            return isRegularApp || rule == .fast
        case .belowThreshold:
            return rule == .fast
        case .active, .frozen, .protected:
            return false
        }
    }

    public init(
        id: String,
        bundleIdentifier: String?,
        name: String,
        bundlePath: String?,
        mainPID: Int32,
        pids: [Int32],
        footprintBytes: UInt64,
        residentBytes: UInt64 = 0,
        reclaimedDRAMBytes: UInt64 = 0,
        recentGrowthBytes: Int64 = 0,
        cpuPercent: Double,
        isFrozen: Bool,
        status: TrackedAppStatus,
        rule: AppFreezeRule = .automatic,
        idleSeconds: TimeInterval,
        isRegularApp: Bool = true,
        backgroundCPUPercent: Double = 0,
        frozenReason: String? = nil
    ) {
        self.isRegularApp = isRegularApp
        self.backgroundCPUPercent = backgroundCPUPercent
        self.frozenReason = frozenReason
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.bundlePath = bundlePath
        self.mainPID = mainPID
        self.pids = pids
        self.footprintBytes = footprintBytes
        self.residentBytes = residentBytes
        self.reclaimedDRAMBytes = reclaimedDRAMBytes
        self.recentGrowthBytes = recentGrowthBytes
        self.cpuPercent = cpuPercent
        self.isFrozen = isFrozen
        self.status = status
        self.rule = rule
        self.idleSeconds = idleSeconds
    }
}

public struct TrackedService: Identifiable, Sendable, Equatable {
    public var id: String { serviceKey }
    public let serviceKey: String
    public let mainPID: Int32
    public let pids: [Int32]
    public let name: String
    public let executablePath: String
    public let footprintBytes: UInt64
    public let residentBytes: UInt64
    public let reclaimedDRAMBytes: UInt64
    public let cpuPercent: Double
    public let isFrozen: Bool
    public let isProtected: Bool
    public let protectionReason: ProtectionReason?
    public let isAutoFreezeEnabled: Bool

    public init(
        serviceKey: String,
        mainPID: Int32,
        pids: [Int32],
        name: String,
        executablePath: String,
        footprintBytes: UInt64,
        residentBytes: UInt64 = 0,
        reclaimedDRAMBytes: UInt64 = 0,
        cpuPercent: Double,
        isFrozen: Bool,
        isProtected: Bool,
        protectionReason: ProtectionReason?,
        isAutoFreezeEnabled: Bool
    ) {
        self.serviceKey = serviceKey
        self.mainPID = mainPID
        self.pids = pids
        self.name = name
        self.executablePath = executablePath
        self.footprintBytes = footprintBytes
        self.residentBytes = residentBytes
        self.reclaimedDRAMBytes = reclaimedDRAMBytes
        self.cpuPercent = cpuPercent
        self.isFrozen = isFrozen
        self.isProtected = isProtected
        self.protectionReason = protectionReason
        self.isAutoFreezeEnabled = isAutoFreezeEnabled
    }
}

public struct FrozenRecord: Codable, Sendable, Equatable {
    public let appKey: String
    public let appName: String
    public let mainPID: Int32
    public let identities: [ProcessIdentity]
    public let frozenAt: Date
    public let footprintAtFreezeBytes: UInt64
    public let residentAtFreezeBytes: UInt64
    /// Why it was frozen (for «Почему?»). Optional and decoded leniently: an unreadable cause
    /// must never stop crash recovery from resuming the processes.
    public let cause: FreezeReason?

    private enum CodingKeys: String, CodingKey {
        case appKey, appName, mainPID, identities, frozenAt, footprintAtFreezeBytes, residentAtFreezeBytes, cause
    }

    public init(
        appKey: String,
        appName: String,
        mainPID: Int32,
        identities: [ProcessIdentity],
        frozenAt: Date,
        footprintAtFreezeBytes: UInt64,
        residentAtFreezeBytes: UInt64 = 0,
        cause: FreezeReason? = nil
    ) {
        self.appKey = appKey
        self.appName = appName
        self.mainPID = mainPID
        self.identities = identities
        self.frozenAt = frozenAt
        self.footprintAtFreezeBytes = footprintAtFreezeBytes
        self.residentAtFreezeBytes = residentAtFreezeBytes
        self.cause = cause
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appKey = try c.decode(String.self, forKey: .appKey)
        appName = try c.decode(String.self, forKey: .appName)
        mainPID = try c.decode(Int32.self, forKey: .mainPID)
        identities = try c.decode([ProcessIdentity].self, forKey: .identities)
        frozenAt = (try? c.decode(Date.self, forKey: .frozenAt)) ?? Date()
        footprintAtFreezeBytes = (try? c.decode(UInt64.self, forKey: .footprintAtFreezeBytes)) ?? 0
        residentAtFreezeBytes = (try? c.decodeIfPresent(UInt64.self, forKey: .residentAtFreezeBytes)) ?? 0
        cause = try? c.decodeIfPresent(FreezeReason.self, forKey: .cause)
    }
}

public struct ActivityEvent: Identifiable, Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case frozen
        case resumed
        case recovered
        case relaunched
        case skipped
    }

    public let id: UUID
    public let timestamp: Date
    public let kind: Kind
    public let title: String
    public let text: EventText

    /// Rendered in the current interface language.
    public var detail: String { text.localized }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, kind, title, text, detail
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: Kind,
        title: String,
        text: EventText
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.title = title
        self.text = text
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        timestamp = (try? c.decode(Date.self, forKey: .timestamp)) ?? Date()
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .skipped
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        if let structured = try? c.decode(EventText.self, forKey: .text) {
            text = structured
        } else {
            // Logs written by 2.2.0 stored the already-rendered string.
            text = .legacy((try? c.decode(String.self, forKey: .detail)) ?? "")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        try c.encode(text, forKey: .text)
    }
}

public struct EngineSettings: Codable, Equatable, Sendable {
    public var isAutoFreezeEnabled: Bool
    public var idleTimeoutMinutes: Double
    public var fastModeMinutes: Double
    public var minMemoryThresholdMB: Double
    public var aggressivePressureMode: Bool
    public var batterySaverMode: Bool
    public var protectAudioApps: Bool
    public var protectSleepAssertions: Bool
    public var protectDevAndSystemTools: Bool
    public var menuBarDisplayMode: MenuBarDisplayMode
    public var appRules: [String: AppFreezeRule]
    public var appRuleDisplayNames: [String: String]
    public var autoFreezeServiceKeys: Set<String>
    /// Do not count idle time for apps whose window is actually visible on screen
    /// (e.g. a dashboard on a second monitor).
    public var keepVisibleWindowsAwake: Bool
    /// Do not freeze the app that last wrote to the pasteboard: apps may provide clipboard data
    /// lazily, and pasting from a stopped owner hangs the pasting app.
    public var protectClipboardOwner: Bool
    /// Freeze idle apps only when macOS reports memory pressure (or when they burn CPU in the
    /// background). Under normal pressure freezing frees almost no RAM but silences notifications.
    public var freezeOnlyUnderPressure: Bool
    /// ⌃⌥⌘U resumes everything from anywhere.
    public var unfreezeHotkeyEnabled: Bool
    /// Dim frozen windows and label them «На паузе».
    public var showFrozenOverlay: Bool
    /// The user has read the warning about pausing background services.
    public var acknowledgedServiceRisk: Bool
    /// Ask GitHub once a day whether a newer release exists.
    public var checkForUpdates: Bool
    /// The first-run introduction has been shown.
    public var hasCompletedOnboarding: Bool

    private enum CodingKeys: String, CodingKey {
        case isAutoFreezeEnabled, idleTimeoutMinutes, fastModeMinutes, minMemoryThresholdMB
        case aggressivePressureMode, batterySaverMode, protectAudioApps, protectSleepAssertions
        case protectDevAndSystemTools, menuBarDisplayMode, appRules, appRuleDisplayNames
        case autoFreezeServiceKeys, keepVisibleWindowsAwake, protectClipboardOwner
        case freezeOnlyUnderPressure, unfreezeHotkeyEnabled, showFrozenOverlay, acknowledgedServiceRisk
        case checkForUpdates, hasCompletedOnboarding
    }

    /// Tolerant decoding: missing keys (settings saved by an older build) fall back to defaults
    /// instead of failing the whole decode and silently wiping the user's rules.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EngineSettings()
        isAutoFreezeEnabled = try c.decodeIfPresent(Bool.self, forKey: .isAutoFreezeEnabled) ?? d.isAutoFreezeEnabled
        idleTimeoutMinutes = try c.decodeIfPresent(Double.self, forKey: .idleTimeoutMinutes) ?? d.idleTimeoutMinutes
        fastModeMinutes = try c.decodeIfPresent(Double.self, forKey: .fastModeMinutes) ?? d.fastModeMinutes
        minMemoryThresholdMB = try c.decodeIfPresent(Double.self, forKey: .minMemoryThresholdMB) ?? d.minMemoryThresholdMB
        aggressivePressureMode = try c.decodeIfPresent(Bool.self, forKey: .aggressivePressureMode) ?? d.aggressivePressureMode
        batterySaverMode = try c.decodeIfPresent(Bool.self, forKey: .batterySaverMode) ?? d.batterySaverMode
        protectAudioApps = try c.decodeIfPresent(Bool.self, forKey: .protectAudioApps) ?? d.protectAudioApps
        protectSleepAssertions = try c.decodeIfPresent(Bool.self, forKey: .protectSleepAssertions) ?? d.protectSleepAssertions
        protectDevAndSystemTools = try c.decodeIfPresent(Bool.self, forKey: .protectDevAndSystemTools) ?? d.protectDevAndSystemTools
        menuBarDisplayMode = (try? c.decodeIfPresent(MenuBarDisplayMode.self, forKey: .menuBarDisplayMode)) ?? d.menuBarDisplayMode
        appRules = (try? c.decodeIfPresent([String: AppFreezeRule].self, forKey: .appRules)) ?? d.appRules
        appRuleDisplayNames = try c.decodeIfPresent([String: String].self, forKey: .appRuleDisplayNames) ?? d.appRuleDisplayNames
        autoFreezeServiceKeys = try c.decodeIfPresent(Set<String>.self, forKey: .autoFreezeServiceKeys) ?? d.autoFreezeServiceKeys
        keepVisibleWindowsAwake = try c.decodeIfPresent(Bool.self, forKey: .keepVisibleWindowsAwake) ?? d.keepVisibleWindowsAwake
        protectClipboardOwner = try c.decodeIfPresent(Bool.self, forKey: .protectClipboardOwner) ?? d.protectClipboardOwner
        freezeOnlyUnderPressure = try c.decodeIfPresent(Bool.self, forKey: .freezeOnlyUnderPressure) ?? d.freezeOnlyUnderPressure
        unfreezeHotkeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .unfreezeHotkeyEnabled) ?? d.unfreezeHotkeyEnabled
        showFrozenOverlay = try c.decodeIfPresent(Bool.self, forKey: .showFrozenOverlay) ?? d.showFrozenOverlay
        acknowledgedServiceRisk = try c.decodeIfPresent(Bool.self, forKey: .acknowledgedServiceRisk) ?? d.acknowledgedServiceRisk
        checkForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? d.checkForUpdates
        // Settings saved by a build without onboarding belong to an existing user: don't show
        // them a first-run flow that would rewrite their rules. Fresh installs use init().
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? true
    }

    public init(
        isAutoFreezeEnabled: Bool = true,
        idleTimeoutMinutes: Double = 10,
        fastModeMinutes: Double = 2,
        minMemoryThresholdMB: Double = 250,
        aggressivePressureMode: Bool = true,
        batterySaverMode: Bool = true,
        protectAudioApps: Bool = true,
        protectSleepAssertions: Bool = true,
        protectDevAndSystemTools: Bool = true,
        menuBarDisplayMode: MenuBarDisplayMode = .frozenAndRAM,
        appRules: [String: AppFreezeRule] = [:],
        appRuleDisplayNames: [String: String] = [:],
        autoFreezeServiceKeys: Set<String> = [],
        keepVisibleWindowsAwake: Bool = true,
        protectClipboardOwner: Bool = true,
        freezeOnlyUnderPressure: Bool = false,
        unfreezeHotkeyEnabled: Bool = true,
        showFrozenOverlay: Bool = true,
        acknowledgedServiceRisk: Bool = false,
        checkForUpdates: Bool = true,
        hasCompletedOnboarding: Bool = false
    ) {
        self.checkForUpdates = checkForUpdates
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.freezeOnlyUnderPressure = freezeOnlyUnderPressure
        self.unfreezeHotkeyEnabled = unfreezeHotkeyEnabled
        self.showFrozenOverlay = showFrozenOverlay
        self.acknowledgedServiceRisk = acknowledgedServiceRisk
        self.keepVisibleWindowsAwake = keepVisibleWindowsAwake
        self.protectClipboardOwner = protectClipboardOwner
        self.isAutoFreezeEnabled = isAutoFreezeEnabled
        self.idleTimeoutMinutes = idleTimeoutMinutes
        self.fastModeMinutes = fastModeMinutes
        self.minMemoryThresholdMB = minMemoryThresholdMB
        self.aggressivePressureMode = aggressivePressureMode
        self.batterySaverMode = batterySaverMode
        self.protectAudioApps = protectAudioApps
        self.protectSleepAssertions = protectSleepAssertions
        self.protectDevAndSystemTools = protectDevAndSystemTools
        self.menuBarDisplayMode = menuBarDisplayMode
        self.appRules = appRules
        self.appRuleDisplayNames = appRuleDisplayNames
        self.autoFreezeServiceKeys = autoFreezeServiceKeys
    }

    public func rule(for bundleID: String?) -> AppFreezeRule {
        guard let bundleID else { return .automatic }
        return appRules[bundleID] ?? .automatic
    }
}

public enum ByteFormatter {
    private static var gbUnit: String { String(localized: "ГБ", comment: "gigabytes") }
    private static var mbUnit: String { String(localized: "МБ", comment: "megabytes") }
    private static var kbUnit: String { String(localized: "КБ", comment: "kilobytes") }

    public static func format(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        if gb >= 1.0 {
            return String(format: "%.2f ", gb) + gbUnit
        }
        let mb = Double(bytes) / 1_048_576.0
        if mb >= 1.0 {
            return String(format: "%.0f ", mb) + mbUnit
        }
        let kb = Double(bytes) / 1_024.0
        return String(format: "%.0f ", max(0, kb)) + kbUnit
    }

    public static func formatCompact(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        if gb >= 1.0 {
            return String(format: "%.1f", gb) + gbUnit
        }
        let mb = Double(bytes) / 1_048_576.0
        return String(format: "%.0f", max(1, mb)) + mbUnit
    }

    public static func formatDuration(_ seconds: TimeInterval) -> String {
        let clamped = max(0, Int(seconds.rounded()))
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let secs = clamped % 60
        let h = String(localized: "ч", comment: "hours unit")
        let m = String(localized: "м", comment: "minutes unit")
        let sUnit = String(localized: "с", comment: "seconds unit")
        if hours > 0 {
            return "\(hours)\(h) " + String(format: "%02d", minutes) + m
        }
        if minutes > 0 {
            return "\(minutes)\(m) " + String(format: "%02d", secs) + sUnit
        }
        return "\(secs)\(sUnit)"
    }
}
