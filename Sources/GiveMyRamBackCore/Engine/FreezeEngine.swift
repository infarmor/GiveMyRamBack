import AppKit
import CoreGraphics
import Foundation

@MainActor
public final class FreezeEngine: ObservableObject {
    @Published public private(set) var memoryStats = SystemMemoryStats()
    @Published public private(set) var memoryHistory: [MemoryHistoryPoint] = []
    @Published public private(set) var apps: [TrackedApp] = []
    @Published public private(set) var services: [TrackedService] = []
    @Published public private(set) var events: [ActivityEvent] = []
    @Published public private(set) var frozenCount: Int = 0
    @Published public private(set) var totalFrozenFootprintBytes: UInt64 = 0
    @Published public private(set) var totalReclaimedDRAMBytes: UInt64 = 0

    @Published public var settings: EngineSettings {
        didSet {
            guard settings != oldValue else { return }
            saveSettings(settings)
            if let lastRawSnapshot {
                applySnapshot(lastRawSnapshot, advanceIdleClock: false)
            }
        }
    }

    private struct RawSystemSnapshot: Sendable {
        let timestamp: Date
        let memory: SystemMemoryStats
        let scan: ProcessScanResult
        let audio: AudioActivitySnapshot
        let sleepAssertionPIDs: Set<Int32>
        let runningApps: [RunningAppDescriptor]
    }

    private let metricsCollector = SystemMetricsCollector()
    private let processScanner = ProcessScanner()
    public let processController: ProcessController

    private var samplingTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var frontmostObservation: NSKeyValueObservation?
    private var mouseMonitor: Any?

    private var lastRawSnapshot: RawSystemSnapshot?
    private var lastSampleTickDate: Date?
    private var idleSecondsByKey: [String: TimeInterval] = [:]
    private var serviceIdleSecondsByKey: [String: TimeInterval] = [:]
    private var resumeCooldowns: [String: Date] = [:]
    private var footprintHistoryByKey: [String: [(date: Date, bytes: UInt64)]] = [:]
    private var isSystemAsleep = false
    private var wakeCooldownUntil: Date?
    private var isStarted = false

    private static let maxAwakeStepSeconds: TimeInterval = 10.0
    private static let settingsDefaultsKey = "dev.givemyramback.settings.v2"
    private static let legacyCryoSettingsKey = "dev.cryoram.settings.v1"

    public init(processController: ProcessController = ProcessController()) {
        self.processController = processController
        self.settings = Self.loadSettings()
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true

        let recovered = processController.recoverFromPreviousRun()
        for appName in recovered {
            appendEvent(
                kind: .recovered,
                title: appName,
                detail: "Возобновлено после предыдущего запуска"
            )
        }

        for runningApp in NSWorkspace.shared.runningApplications {
            let key = appKey(for: runningApp)
            idleSecondsByKey[key] = 0
        }
        lastSampleTickDate = Date()

        installWorkspaceObservers()
        installMouseWakeMonitor()
        startSamplingLoop()
    }

    public func stopAndResumeAll(reason: String = "выход из приложения") {
        samplingTask?.cancel()
        samplingTask = nil

        frontmostObservation?.invalidate()
        frontmostObservation = nil

        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }

        resumeAll(reason: reason)
        isStarted = false
    }

    public func prepareForTermination() {
        let resumed = processController.resumeAll()
        if !resumed.isEmpty {
            syncFrozenCounters()
        }
    }

    // MARK: - User Actions

    public func freezeApp(_ app: TrackedApp, reason: String = "вручную") {
        let samples = lastRawSnapshot?.scan.samplesByPID ?? [:]
        let identities = app.pids.compactMap { samples[$0]?.identity }
        guard !identities.isEmpty else { return }

        if let record = processController.freeze(
            appKey: app.id,
            appName: app.name,
            mainPID: app.mainPID,
            identities: identities,
            footprintBytes: app.footprintBytes,
            residentBytes: app.residentBytes
        ) {
            appendEvent(
                kind: .frozen,
                title: app.name,
                detail: "Заморожено (\(ByteFormatter.format(record.footprintAtFreezeBytes)), \(reason))"
            )
            syncFrozenCounters()
            if let lastRawSnapshot {
                applySnapshot(lastRawSnapshot, advanceIdleClock: false)
            }
        }
    }

    @discardableResult
    public func freezeAllEligibleBackground() -> Int {
        let candidates = apps.filter { $0.isEligibleForBatchFreezeNow }
        guard !candidates.isEmpty else { return 0 }

        let samples = lastRawSnapshot?.scan.samplesByPID ?? [:]
        var frozenTotal = 0
        var frozenBytes: UInt64 = 0

        for app in candidates {
            let identities = app.pids.compactMap { samples[$0]?.identity }
            guard !identities.isEmpty else { continue }
            if let record = processController.freeze(
                appKey: app.id,
                appName: app.name,
                mainPID: app.mainPID,
                identities: identities,
                footprintBytes: app.footprintBytes,
                residentBytes: app.residentBytes
            ) {
                frozenTotal += 1
                frozenBytes += record.footprintAtFreezeBytes
            }
        }

        if frozenTotal > 0 {
            appendEvent(
                kind: .frozen,
                title: "Give my ram back",
                detail: "На паузу поставлено приложений: \(frozenTotal) (~\(ByteFormatter.format(frozenBytes)))"
            )
            syncFrozenCounters()
            if let lastRawSnapshot {
                applySnapshot(lastRawSnapshot, advanceIdleClock: false)
            }
        }
        return frozenTotal
    }

    public func resumeApp(_ app: TrackedApp, reason: String = "вручную") {
        resumeByKey(app.id, fallbackName: app.name, reason: reason, refreshSnapshot: true)
    }

    public func relaunchApp(_ app: TrackedApp) {
        guard let bundlePath = app.bundlePath, !bundlePath.isEmpty else { return }
        if app.isFrozen {
            _ = processController.resume(appKey: app.id)
            syncFrozenCounters()
        }

        let targetPID = app.mainPID
        let appName = app.name
        let bundleURL = URL(fileURLWithPath: bundlePath)

        guard let running = NSRunningApplication(processIdentifier: targetPID) else { return }
        guard running.terminate() else {
            appendEvent(
                kind: .skipped,
                title: appName,
                detail: "Не удалось запросить завершение приложения"
            )
            return
        }

        appendEvent(
            kind: .relaunched,
            title: appName,
            detail: "Мягкий перезапуск для сброса памяти"
        )

        Task { @MainActor [weak self] in
            var terminated = false
            for _ in 0..<30 {
                if let current = NSRunningApplication(processIdentifier: targetPID), !current.isTerminated {
                    try? await Task.sleep(for: .milliseconds(150))
                } else {
                    terminated = true
                    break
                }
            }

            guard terminated else {
                self?.appendEvent(
                    kind: .skipped,
                    title: appName,
                    detail: "Перезапуск отменён: приложение ожидает подтверждения"
                )
                return
            }

            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in }
        }
    }

    public func freezeService(_ service: TrackedService, reason: String = "вручную") {
        let samples = lastRawSnapshot?.scan.samplesByPID ?? [:]
        let identities = service.pids.compactMap { samples[$0]?.identity }
        guard !identities.isEmpty else { return }

        if let record = processController.freeze(
            appKey: service.serviceKey,
            appName: service.name,
            mainPID: service.mainPID,
            identities: identities,
            footprintBytes: service.footprintBytes,
            residentBytes: service.residentBytes
        ) {
            appendEvent(
                kind: .frozen,
                title: service.name,
                detail: "Сервис на паузе (\(ByteFormatter.format(record.footprintAtFreezeBytes)), \(reason))"
            )
            syncFrozenCounters()
            if let lastRawSnapshot {
                applySnapshot(lastRawSnapshot, advanceIdleClock: false)
            }
        }
    }

    public func resumeService(_ service: TrackedService, reason: String = "вручную") {
        resumeByKey(service.serviceKey, fallbackName: service.name, reason: reason, refreshSnapshot: true)
        serviceIdleSecondsByKey[service.serviceKey] = 0
    }

    public func resumeAll(reason: String = "пользователем") {
        let records = processController.resumeAll()
        let now = Date()
        for record in records {
            idleSecondsByKey[record.appKey] = 0
            serviceIdleSecondsByKey[record.appKey] = 0
            resumeCooldowns[record.appKey] = now.addingTimeInterval(FreezePolicy.resumeCooldownSeconds)
            appendEvent(
                kind: .resumed,
                title: record.appName,
                detail: "Возобновлено (\(reason))"
            )
        }
        syncFrozenCounters()
        if let lastRawSnapshot {
            applySnapshot(lastRawSnapshot, advanceIdleClock: false)
        }
    }

    public func setRule(_ rule: AppFreezeRule, for bundleID: String, appName: String? = nil) {
        if rule == .automatic {
            settings.appRules.removeValue(forKey: bundleID)
            settings.appRuleDisplayNames.removeValue(forKey: bundleID)
        } else {
            settings.appRules[bundleID] = rule
            if let appName, !appName.isEmpty {
                settings.appRuleDisplayNames[bundleID] = appName
            }
            if rule == .protected,
               let frozenApp = apps.first(where: { $0.bundleIdentifier == bundleID && $0.isFrozen }) {
                resumeApp(frozenApp, reason: "правило «Защита»")
            }
        }
    }

    public func toggleServiceAutoFreeze(serviceKey: String) {
        if settings.autoFreezeServiceKeys.contains(serviceKey) {
            settings.autoFreezeServiceKeys.remove(serviceKey)
        } else {
            settings.autoFreezeServiceKeys.insert(serviceKey)
            serviceIdleSecondsByKey[serviceKey] = 0
        }
    }

    public func clearEvents() {
        events.removeAll()
    }

    // MARK: - Observers & Sampling

    private func installWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter

        frontmostObservation = NSWorkspace.shared.observe(\.frontmostApplication, options: [.new]) { [weak self] workspace, _ in
            let frontmost = workspace.frontmostApplication
            Task { @MainActor [weak self] in
                guard let self, let frontmost else { return }
                self.handleAppWakeEvent(runningApp: frontmost, reason: "переход фокуса")
            }
        }

        let activateObs = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let runningApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let runningApp else { return }
                self.handleAppWakeEvent(runningApp: runningApp, reason: "активация окна")
            }
        }

        let launchObs = nc.addObserver(
            forName: NSWorkspace.willLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let runningApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let runningApp else { return }
                self.handleAppWakeEvent(runningApp: runningApp, reason: "открытие приложения")
            }
        }

        let unhideObs = nc.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let runningApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let runningApp else { return }
                self.handleAppWakeEvent(runningApp: runningApp, reason: "показ окна")
            }
        }

        let termObs = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let runningApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let runningApp else { return }
                let key = self.appKey(for: runningApp)
                self.processController.pruneExitedRecord(appKey: key)
                self.idleSecondsByKey.removeValue(forKey: key)
                self.resumeCooldowns.removeValue(forKey: key)
                self.footprintHistoryByKey.removeValue(forKey: key)
                self.syncFrozenCounters()
            }
        }

        let sleepObs = nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isSystemAsleep = true
            }
        }

        let wakeObs = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                self.isSystemAsleep = false
                self.lastSampleTickDate = now
                self.wakeCooldownUntil = now.addingTimeInterval(FreezePolicy.systemWakeGraceSeconds)
            }
        }

        let powerOffObs = nc.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.prepareForTermination()
            }
        }

        workspaceObservers = [activateObs, launchObs, unhideObs, termObs, sleepObs, wakeObs, powerOffObs]
    }

    private func installMouseWakeMonitor() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.wakeFrozenWindowUnderCursorIfNeeded()
            }
        }
    }

    private func wakeFrozenWindowUnderCursorIfNeeded() {
        guard processController.frozenCount() > 0 else { return }
        guard let primaryHeight = NSScreen.screens.first?.frame.height, primaryHeight > 0 else { return }

        let cocoaPoint = NSEvent.mouseLocation
        let cgPoint = CGPoint(x: cocoaPoint.x, y: primaryHeight - cocoaPoint.y)

        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return
        }

        let selfPID = getpid()
        for windowInfo in infoList {
            if let alpha = (windowInfo[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
               alpha <= 0.01 {
                continue
            }
            guard let boundsDict = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.contains(cgPoint),
                  let ownerPID = (windowInfo[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID != selfPID else {
                continue
            }

            if let frozenKey = processController.frozenKey(forPID: ownerPID) {
                resumeByKey(frozenKey, fallbackName: nil, reason: "клик по окну", refreshSnapshot: true)
                break
            }

            // Only stop scanning if a standard layer-0 app window actually owns this screen point;
            // non-zero layers can be translucent overlays/shadows that don't block underlying windows.
            let layer = (windowInfo[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            if layer == 0 {
                break
            }
        }
    }

    private func handleAppWakeEvent(runningApp: NSRunningApplication, reason: String) {
        let key = appKey(for: runningApp)
        idleSecondsByKey[key] = 0

        if processController.frozenRecord(forKey: key) != nil {
            resumeByKey(key, fallbackName: runningApp.localizedName, reason: reason, refreshSnapshot: true)
        } else if let byPIDKey = processController.frozenKey(forPID: runningApp.processIdentifier) {
            resumeByKey(byPIDKey, fallbackName: runningApp.localizedName, reason: reason, refreshSnapshot: true)
        }
    }

    private func startSamplingLoop() {
        samplingTask?.cancel()
        let metrics = metricsCollector
        let scanner = processScanner

        samplingTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let memory = metrics.readMemoryStats()
                let scan = scanner.scanUserProcesses()
                let audio = metrics.readAudioActivity()
                let sleepPIDs = metrics.readSleepAssertionPIDs()

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let descriptors = self.captureRunningAppDescriptors()
                    let snapshot = RawSystemSnapshot(
                        timestamp: Date(),
                        memory: memory,
                        scan: scan,
                        audio: audio,
                        sleepAssertionPIDs: sleepPIDs,
                        runningApps: descriptors
                    )
                    self.lastRawSnapshot = snapshot
                    self.applySnapshot(snapshot, advanceIdleClock: true)
                }

                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func captureRunningAppDescriptors() -> [RunningAppDescriptor] {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app in
            let pid = app.processIdentifier
            guard pid > 0, pid != getpid() else { return nil }
            let key = appKey(for: app)
            return RunningAppDescriptor(
                key: key,
                mainPID: pid,
                name: app.localizedName ?? app.bundleIdentifier ?? "PID \(pid)",
                bundleIdentifier: app.bundleIdentifier,
                bundlePath: app.bundleURL?.path,
                isRegularApp: app.activationPolicy == .regular,
                isFrontmost: pid == frontmostPID || app.isActive,
                isHidden: app.isHidden,
                launchDate: app.launchDate
            )
        }
    }

    private func applySnapshot(_ snapshot: RawSystemSnapshot, advanceIdleClock: Bool) {
        self.memoryStats = snapshot.memory

        // Compute clamped awake elapsed delta (immune to Mac sleep & system clock jumps)
        let awakeDelta: TimeInterval
        if advanceIdleClock {
            if isSystemAsleep {
                awakeDelta = 0
            } else if let prev = lastSampleTickDate {
                awakeDelta = min(Self.maxAwakeStepSeconds, max(0, snapshot.timestamp.timeIntervalSince(prev)))
            } else {
                awakeDelta = 0
            }
            lastSampleTickDate = snapshot.timestamp
        } else {
            awakeDelta = 0
        }

        // Prune exited frozen records across both apps and services using exact (pid, startTime) identity
        for record in processController.allFrozenRecords() {
            let anyAliveWithSameIdentity = record.identities.contains { identity in
                guard let sample = snapshot.scan.samplesByPID[identity.pid] else { return false }
                return sample.startTimeSec == identity.startTimeSec &&
                       sample.startTimeUsec == identity.startTimeUsec
            }
            if !anyAliveWithSameIdentity {
                processController.pruneExitedRecord(appKey: record.appKey)
            }
        }

        // Safety net: if a frozen app became frontmost, resume without recursive applySnapshot
        for desc in snapshot.runningApps where desc.isFrontmost {
            idleSecondsByKey[desc.key] = 0
            if processController.frozenRecord(forKey: desc.key) != nil {
                resumeByKey(desc.key, fallbackName: desc.name, reason: "переход фокуса", refreshSnapshot: false)
            }
        }

        let grouping = ProcessScanner.groupProcesses(
            samplesByPID: snapshot.scan.samplesByPID,
            cpuPercentByPID: snapshot.scan.cpuPercentByPID,
            apps: snapshot.runningApps,
            protectedAncestors: snapshot.scan.protectedAncestors,
            currentPID: getpid()
        )

        let evalContext = FreezeEvaluationContext(
            settings: settings,
            memoryPressure: snapshot.memory.pressure,
            powerSource: snapshot.memory.powerSource,
            audioSnapshot: snapshot.audio,
            sleepAssertionPIDs: snapshot.sleepAssertionPIDs,
            now: snapshot.timestamp,
            wakeCooldownUntil: wakeCooldownUntil
        )

        var nextApps: [TrackedApp] = []
        nextApps.reserveCapacity(snapshot.runningApps.count)
        var seenAppKeys = Set<String>()
        var totalReclaimedDRAM: UInt64 = 0

        for desc in snapshot.runningApps {
            let pids = grouping.appPIDsByKey[desc.key] ?? []
            guard !pids.isEmpty else { continue }
            seenAppKeys.insert(desc.key)

            let footprint = pids.reduce(UInt64(0)) {
                $0 + (snapshot.scan.samplesByPID[$1]?.footprintBytes ?? 0)
            }
            let resident = pids.reduce(UInt64(0)) {
                $0 + (snapshot.scan.samplesByPID[$1]?.residentBytes ?? 0)
            }
            let cpu = pids.reduce(0.0) {
                $0 + (snapshot.scan.cpuPercentByPID[$1] ?? 0)
            }

            let recentGrowth = updateAndComputeGrowth(
                key: desc.key,
                now: snapshot.timestamp,
                footprintBytes: footprint,
                isFrontmost: desc.isFrontmost
            )

            let frozenRecord = processController.frozenRecord(forKey: desc.key)
            if desc.isFrontmost {
                idleSecondsByKey[desc.key] = 0
            } else if frozenRecord == nil {
                idleSecondsByKey[desc.key] = (idleSecondsByKey[desc.key] ?? 0) + awakeDelta
            }

            let idleSeconds = idleSecondsByKey[desc.key] ?? 0
            let outcome = FreezePolicy.evaluateApp(
                descriptor: desc,
                pids: pids,
                footprintBytes: footprint,
                idleSeconds: idleSeconds,
                frozenRecord: frozenRecord,
                resumeCooldownUntil: resumeCooldowns[desc.key],
                context: evalContext
            )

            var finalStatus = outcome.status
            var isFrozen = frozenRecord != nil
            var activeRecord = frozenRecord

            if outcome.shouldAutoFreeze && !isFrozen {
                let identities = pids.compactMap { snapshot.scan.samplesByPID[$0]?.identity }
                if let newRecord = processController.freeze(
                    appKey: desc.key,
                    appName: desc.name,
                    mainPID: desc.mainPID,
                    identities: identities,
                    footprintBytes: footprint,
                    residentBytes: resident,
                    now: snapshot.timestamp
                ) {
                    isFrozen = true
                    activeRecord = newRecord
                    finalStatus = .frozen(since: newRecord.frozenAt, pidCount: newRecord.identities.count)
                    appendEvent(
                        kind: .frozen,
                        title: desc.name,
                        detail: "Неактивно \(ByteFormatter.formatDuration(idleSeconds)) · \(ByteFormatter.format(footprint))"
                    )
                }
            }

            let reclaimedDRAM: UInt64
            if let rec = activeRecord, rec.residentAtFreezeBytes > resident {
                reclaimedDRAM = rec.residentAtFreezeBytes - resident
            } else {
                reclaimedDRAM = 0
            }
            totalReclaimedDRAM += reclaimedDRAM

            let rule = settings.rule(for: desc.bundleIdentifier)

            nextApps.append(
                TrackedApp(
                    id: desc.key,
                    bundleIdentifier: desc.bundleIdentifier,
                    name: desc.name,
                    bundlePath: desc.bundlePath,
                    mainPID: desc.mainPID,
                    pids: pids,
                    footprintBytes: footprint,
                    residentBytes: resident,
                    reclaimedDRAMBytes: reclaimedDRAM,
                    recentGrowthBytes: recentGrowth,
                    cpuPercent: cpu,
                    isFrozen: isFrozen,
                    status: finalStatus,
                    rule: rule,
                    idleSeconds: idleSeconds
                )
            )
        }

        // Build services list
        let minServiceThreshold: UInt64 = 30 * 1_048_576
        var nextServices: [TrackedService] = []
        var seenServiceKeys = Set<String>()

        for candidate in grouping.standaloneServices {
            let frozenRecord = processController.frozenRecord(forKey: candidate.serviceKey)
            let isOptedIn = settings.autoFreezeServiceKeys.contains(candidate.serviceKey)
            if candidate.footprintBytes < minServiceThreshold && frozenRecord == nil && !isOptedIn {
                continue
            }
            seenServiceKeys.insert(candidate.serviceKey)

            let pidSet = Set(candidate.pids)
            var protection: ProtectionReason?
            if settings.protectAudioApps && (!pidSet.isDisjoint(with: snapshot.audio.outputPIDs) || !pidSet.isDisjoint(with: snapshot.audio.inputPIDs)) {
                protection = !pidSet.isDisjoint(with: snapshot.audio.inputPIDs) ? .usingMicrophone : .playingAudio
            } else if settings.protectSleepAssertions && !pidSet.isDisjoint(with: snapshot.sleepAssertionPIDs) {
                protection = .preventingSleep
            }

            var activeRecord = frozenRecord
            var isFrozen = frozenRecord != nil

            if !isFrozen && isOptedIn && protection == nil {
                serviceIdleSecondsByKey[candidate.serviceKey] = (serviceIdleSecondsByKey[candidate.serviceKey] ?? 0) + awakeDelta
            } else if protection != nil {
                serviceIdleSecondsByKey[candidate.serviceKey] = 0
            }

            if isOptedIn && !isFrozen && settings.isAutoFreezeEnabled && protection == nil {
                let inWakeGrace = wakeCooldownUntil.map { snapshot.timestamp < $0 } ?? false
                let inResumeCooldown = resumeCooldowns[candidate.serviceKey].map { snapshot.timestamp < $0 } ?? false
                if !inWakeGrace && !inResumeCooldown {
                    let serviceIdle = serviceIdleSecondsByKey[candidate.serviceKey] ?? 0
                    let timeout = FreezePolicy.effectiveIdleTimeoutSeconds(
                        settings: settings,
                        pressure: snapshot.memory.pressure,
                        powerSource: snapshot.memory.powerSource
                    )
                    if serviceIdle >= timeout {
                        let identities = candidate.pids.compactMap { snapshot.scan.samplesByPID[$0]?.identity }
                        if let rec = processController.freeze(
                            appKey: candidate.serviceKey,
                            appName: candidate.name,
                            mainPID: candidate.mainPID,
                            identities: identities,
                            footprintBytes: candidate.footprintBytes,
                            residentBytes: candidate.residentBytes,
                            now: snapshot.timestamp
                        ) {
                            isFrozen = true
                            activeRecord = rec
                            appendEvent(
                                kind: .frozen,
                                title: candidate.name,
                                detail: "Автопауза сервиса (\(ByteFormatter.format(rec.footprintAtFreezeBytes)))"
                            )
                        }
                    }
                }
            }

            let reclaimedServiceDRAM: UInt64
            if let rec = activeRecord, rec.residentAtFreezeBytes > candidate.residentBytes {
                reclaimedServiceDRAM = rec.residentAtFreezeBytes - candidate.residentBytes
            } else {
                reclaimedServiceDRAM = 0
            }
            totalReclaimedDRAM += reclaimedServiceDRAM

            nextServices.append(
                TrackedService(
                    serviceKey: candidate.serviceKey,
                    mainPID: candidate.mainPID,
                    pids: candidate.pids,
                    name: candidate.name,
                    executablePath: candidate.executablePath,
                    footprintBytes: candidate.footprintBytes,
                    residentBytes: candidate.residentBytes,
                    reclaimedDRAMBytes: reclaimedServiceDRAM,
                    cpuPercent: candidate.cpuPercent,
                    isFrozen: isFrozen,
                    isProtected: protection != nil,
                    protectionReason: protection,
                    isAutoFreezeEnabled: isOptedIn
                )
            )
        }

        // Clean stale dictionary keys for terminated apps/services and expired cooldowns
        idleSecondsByKey = idleSecondsByKey.filter { seenAppKeys.contains($0.key) }
        footprintHistoryByKey = footprintHistoryByKey.filter { seenAppKeys.contains($0.key) }
        serviceIdleSecondsByKey = serviceIdleSecondsByKey.filter { seenServiceKeys.contains($0.key) }
        resumeCooldowns = resumeCooldowns.filter { $0.value > snapshot.timestamp }

        self.apps = nextApps.sorted {
            if $0.footprintBytes != $1.footprintBytes {
                return $0.footprintBytes > $1.footprintBytes
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        self.services = nextServices
        self.totalReclaimedDRAMBytes = totalReclaimedDRAM
        syncFrozenCounters()

        if advanceIdleClock {
            memoryHistory.append(
                MemoryHistoryPoint(
                    timestamp: snapshot.timestamp,
                    usedRatio: snapshot.memory.usedRatio,
                    compressedRatio: snapshot.memory.compressedRatio,
                    reclaimedDRAMBytes: totalReclaimedDRAM
                )
            )
            if memoryHistory.count > 60 {
                memoryHistory.removeFirst(memoryHistory.count - 60)
            }
        }
    }

    private func updateAndComputeGrowth(
        key: String,
        now: Date,
        footprintBytes: UInt64,
        isFrontmost: Bool
    ) -> Int64 {
        if isFrontmost {
            footprintHistoryByKey[key] = [(now, footprintBytes)]
            return 0
        }

        var samples = footprintHistoryByKey[key] ?? []
        samples.append((now, footprintBytes))
        let cutoff = now.addingTimeInterval(-120)
        samples.removeAll { $0.date < cutoff }
        footprintHistoryByKey[key] = samples

        guard let oldest = samples.first, now.timeIntervalSince(oldest.date) >= 20 else {
            return 0
        }
        return Int64(footprintBytes) - Int64(oldest.bytes)
    }

    private func resumeByKey(_ key: String, fallbackName: String?, reason: String, refreshSnapshot: Bool) {
        guard let record = processController.resume(appKey: key) else { return }
        let now = Date()
        idleSecondsByKey[key] = 0
        serviceIdleSecondsByKey[key] = 0
        resumeCooldowns[key] = now.addingTimeInterval(FreezePolicy.resumeCooldownSeconds)

        let title = fallbackName ?? record.appName
        appendEvent(
            kind: .resumed,
            title: title,
            detail: "Возобновлено (\(reason))"
        )
        syncFrozenCounters()

        if refreshSnapshot, let lastRawSnapshot {
            applySnapshot(lastRawSnapshot, advanceIdleClock: false)
        }
    }

    private func syncFrozenCounters() {
        let records = processController.allFrozenRecords()
        frozenCount = records.count
        totalFrozenFootprintBytes = records.reduce(0) { $0 + $1.footprintAtFreezeBytes }
    }

    private func appendEvent(kind: ActivityEvent.Kind, title: String, detail: String) {
        events.insert(ActivityEvent(kind: kind, title: title, detail: detail), at: 0)
        if events.count > 60 {
            events.removeLast(events.count - 60)
        }
    }

    private func appKey(for app: NSRunningApplication) -> String {
        if let bundleID = app.bundleIdentifier, !bundleID.isEmpty {
            return "app:\(bundleID):\(app.processIdentifier)"
        }
        return "pid:\(app.processIdentifier)"
    }

    private struct LegacyCryoSettings: Codable {
        var isAutoFreezeEnabled: Bool
        var idleTimeoutMinutes: Double
        var minMemoryThresholdMB: Double
        var aggressivePressureMode: Bool
        var protectAudioApps: Bool
        var protectSleepAssertions: Bool
        var protectDevAndSystemTools: Bool
        var showFrozenCountInMenuBar: Bool
        var whitelistedBundleIDs: Set<String>
        var pinnedAutoFreezeBundleIDs: Set<String>
        var autoFreezeServiceKeys: Set<String>
    }

    private static func loadSettings() -> EngineSettings {
        if let data = UserDefaults.standard.data(forKey: settingsDefaultsKey),
           let decoded = try? JSONDecoder().decode(EngineSettings.self, from: data) {
            return decoded
        }

        if let legacyData = UserDefaults.standard.data(forKey: legacyCryoSettingsKey),
           let legacy = try? JSONDecoder().decode(LegacyCryoSettings.self, from: legacyData) {
            var migratedRules: [String: AppFreezeRule] = [:]
            for bundleID in legacy.whitelistedBundleIDs {
                migratedRules[bundleID] = .protected
            }
            for bundleID in legacy.pinnedAutoFreezeBundleIDs {
                migratedRules[bundleID] = .fast
            }
            return EngineSettings(
                isAutoFreezeEnabled: legacy.isAutoFreezeEnabled,
                idleTimeoutMinutes: legacy.idleTimeoutMinutes,
                minMemoryThresholdMB: legacy.minMemoryThresholdMB,
                aggressivePressureMode: legacy.aggressivePressureMode,
                protectAudioApps: legacy.protectAudioApps,
                protectSleepAssertions: legacy.protectSleepAssertions,
                protectDevAndSystemTools: legacy.protectDevAndSystemTools,
                menuBarDisplayMode: legacy.showFrozenCountInMenuBar ? .frozenAndRAM : .iconOnly,
                appRules: migratedRules,
                autoFreezeServiceKeys: legacy.autoFreezeServiceKeys
            )
        }

        return EngineSettings()
    }

    private func saveSettings(_ settings: EngineSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsDefaultsKey)
        }
    }
}
