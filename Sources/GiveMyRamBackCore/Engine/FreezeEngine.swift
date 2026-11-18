import AppKit
import Combine
import CoreGraphics
import Foundation

/// Lets the sampling loop sleep for an interval but wake up early on demand
/// (e.g. when the popover opens), without racing two scans against each other.
final class SampleWaker: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var pending = false
    private var generation: UInt64 = 0

    func wait(seconds: Double) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if pending {
                pending = false
                lock.unlock()
                c.resume()
                return
            }
            generation &+= 1
            let gen = generation
            continuation = c
            lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.resume(ifGeneration: gen)
            }
        }
    }

    func wake() {
        lock.lock()
        if let c = continuation {
            continuation = nil
            lock.unlock()
            c.resume()
        } else {
            pending = true
            lock.unlock()
        }
    }

    private func resume(ifGeneration gen: UInt64) {
        lock.lock()
        guard gen == generation, let c = continuation else {
            lock.unlock()
            return
        }
        continuation = nil
        lock.unlock()
        c.resume()
    }
}

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
            Log.engine.info("Settings changed")
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
        let visibleWindowPIDs: Set<Int32>
        let runningApps: [RunningAppDescriptor]
    }

    /// Fresh state used by all engine logic. The `@Published` mirrors above are only refreshed
    /// while the UI is on screen, so a closed popover doesn't re-render SwiftUI every tick.
    public private(set) var currentApps: [TrackedApp] = []
    public private(set) var currentServices: [TrackedService] = []
    private var historyStorage: [MemoryHistoryPoint] = []

    /// Per-day statistics (freezes, RAM given back). Published while the UI is visible.
    @Published public private(set) var stats = UsageStats()
    private var statsStorage = UsageStats()
    private var lastStatsSave = Date()
    private let statsStore = JSONFileStore<UsageStats>(filename: "stats.json")
    private let eventStore = JSONFileStore<[ActivityEvent]>(filename: "events.json")
    private static let maxStoredEvents = 300
    private var memoryStatsStorage = SystemMemoryStats()
    public private(set) var isUIVisible = false
    /// Fires after every evaluation and after manual freeze/resume (drives window overlays).
    public let stateDidChange = PassthroughSubject<Void, Never>()

    public var hasBatchCandidates: Bool {
        currentApps.contains { $0.isEligibleForBatchFreezeNow }
    }

    private static let visibleSamplingInterval: Double = 2
    private static let hiddenSamplingInterval: Double = 5
    private let sampleWaker = SampleWaker()
    private let samplingIntervalBox = SamplingIntervalBox()

    private var lastPasteboardChangeCount = NSPasteboard.general.changeCount
    private var clipboardOwnerKey: String?
    private var lastFrontmostAppKey: String?

    private let metricsCollector = SystemMetricsCollector()
    private let processScanner = ProcessScanner()
    public let processController: ProcessController

    private var samplingTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var frontmostObservation: NSKeyValueObservation?
    private var mouseMonitor: Any?

    private var lastRawSnapshot: RawSystemSnapshot?
    private var lastSampleTickDate: Date?
    private var tracking = TrackingState()
    private var resumeCooldowns: [String: Date] = [:]
    private var isSystemAsleep = false
    private var wakeCooldownUntil: Date?
    private var isStarted = false

    private static let maxAwakeStepSeconds: TimeInterval = 12.0
    private static let settingsDefaultsKey = "dev.givemyramback.settings.v2"
    private static let legacyCryoSettingsKey = "dev.cryoram.settings.v1"

    public init(processController: ProcessController = ProcessController()) {
        self.processController = processController
        self.settings = Self.loadSettings()
        if let savedEvents = eventStore.load() {
            self.events = Array(savedEvents.prefix(Self.maxStoredEvents))
        }
        if let savedStats = statsStore.load() {
            self.statsStorage = savedStats
            self.stats = savedStats
        }
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true

        let recovered = processController.recoverFromPreviousRun()
        for appName in recovered {
            appendEvent(
                kind: .recovered,
                title: appName,
                text: .recovered
            )
        }

        for runningApp in NSWorkspace.shared.runningApplications {
            let key = appKey(for: runningApp)
            tracking.appIdleSeconds[key] = 0
        }
        lastSampleTickDate = Date()
        lastFrontmostAppKey = NSWorkspace.shared.frontmostApplication.map { appKey(for: $0) }
        samplingIntervalBox.set(isUIVisible ? Self.visibleSamplingInterval : Self.hiddenSamplingInterval)

        installWorkspaceObservers()
        installMouseWakeMonitor()
        startSamplingLoop()
    }

    public func stopAndResumeAll(reason: FreezeReason = .appQuit) {
        samplingTask?.cancel()
        samplingTask = nil
        sampleWaker.wake()

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
        statsStore.saveNow(statsStorage)
        eventStore.saveNow(events)
        isStarted = false
    }

    public func prepareForTermination() {
        let resumed = processController.resumeAll()
        if !resumed.isEmpty {
            syncFrozenCounters()
        }
    }

    /// Called by the app when the popover / detached window appears or disappears.
    public func setUIVisible(_ visible: Bool) {
        guard visible != isUIVisible else { return }
        isUIVisible = visible
        Log.engine.debug("UI visible: \(visible, privacy: .public)")
        samplingIntervalBox.set(visible ? Self.visibleSamplingInterval : Self.hiddenSamplingInterval)
        if visible {
            publishUIState()
            sampleWaker.wake()
        }
    }

    private func publishUIState() {
        if apps != currentApps { apps = currentApps }
        if services != currentServices { services = currentServices }
        if memoryHistory != historyStorage { memoryHistory = historyStorage }
        if memoryStats != memoryStatsStorage { memoryStats = memoryStatsStorage }
        if stats != statsStorage { stats = statsStorage }
    }

    private func noteFreezes(_ count: Int) {
        statsStorage.recordFreezes(count)
        statsStore.save(statsStorage)
        if stats != statsStorage { stats = statsStorage }
    }

    // MARK: - User Actions

    public func freezeApp(_ app: TrackedApp, reason: FreezeReason = .manual) {
        let samples = lastRawSnapshot?.scan.samplesByPID ?? [:]
        let identities = app.pids.compactMap { samples[$0]?.identity }
        guard !identities.isEmpty else { return }

        if let record = processController.freeze(
            appKey: app.id,
            appName: app.name,
            mainPID: app.mainPID,
            identities: identities,
            footprintBytes: app.footprintBytes,
            residentBytes: app.residentBytes,
            cause: reason
        ) {
            noteFreezes(1)
            appendEvent(kind: .frozen, title: app.name, text: .frozen(bytes: record.footprintAtFreezeBytes, reason: reason))
            syncFrozenCounters()
            if let lastRawSnapshot {
                applySnapshot(lastRawSnapshot, advanceIdleClock: false)
            }
        }
    }

    @discardableResult
    public func freezeAllEligibleBackground() -> Int {
        let candidates = currentApps.filter { $0.isEligibleForBatchFreezeNow }
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
                residentBytes: app.residentBytes,
                cause: .batchButton
            ) {
                frozenTotal += 1
                frozenBytes += record.footprintAtFreezeBytes
            }
        }

        if frozenTotal > 0 {
            noteFreezes(frozenTotal)
            appendEvent(
                kind: .frozen,
                title: "Give my ram back",
                text: .frozenBatch(count: frozenTotal, bytes: frozenBytes)
            )
            syncFrozenCounters()
            if let lastRawSnapshot {
                applySnapshot(lastRawSnapshot, advanceIdleClock: false)
            }
        }
        return frozenTotal
    }

    public func resumeApp(_ app: TrackedApp, reason: FreezeReason = .manual) {
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
                text: .relaunchQuitFailed
            )
            return
        }

        appendEvent(
            kind: .relaunched,
            title: appName,
            text: .relaunched
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
                    text: .relaunchCancelled
                )
                return
            }

            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in }
        }
    }

    public func freezeService(_ service: TrackedService, reason: FreezeReason = .manual) {
        let samples = lastRawSnapshot?.scan.samplesByPID ?? [:]
        let identities = service.pids.compactMap { samples[$0]?.identity }
        guard !identities.isEmpty else { return }

        if let record = processController.freeze(
            appKey: service.serviceKey,
            appName: service.name,
            mainPID: service.mainPID,
            identities: identities,
            footprintBytes: service.footprintBytes,
            residentBytes: service.residentBytes,
            cause: reason
        ) {
            noteFreezes(1)
            appendEvent(kind: .frozen, title: service.name, text: .serviceFrozen(bytes: record.footprintAtFreezeBytes, reason: reason))
            syncFrozenCounters()
            if let lastRawSnapshot {
                applySnapshot(lastRawSnapshot, advanceIdleClock: false)
            }
        }
    }

    public func resumeService(_ service: TrackedService, reason: FreezeReason = .manual) {
        resumeByKey(service.serviceKey, fallbackName: service.name, reason: reason, refreshSnapshot: true)
        tracking.serviceIdleSeconds[service.serviceKey] = 0
    }

    public func resumeAll(reason: FreezeReason = .byUser) {
        let records = processController.resumeAll()
        let now = Date()
        for record in records {
            tracking.resetIdle(record.appKey)
            resumeCooldowns[record.appKey] = now.addingTimeInterval(FreezePolicy.resumeCooldownSeconds)
            appendEvent(
                kind: .resumed,
                title: record.appName,
                text: .resumed(reason: reason)
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
               let frozenApp = currentApps.first(where: { $0.bundleIdentifier == bundleID && $0.isFrozen }) {
                resumeApp(frozenApp, reason: .protectedRule)
            }
        }
    }

    public func toggleServiceAutoFreeze(serviceKey: String) {
        if settings.autoFreezeServiceKeys.contains(serviceKey) {
            settings.autoFreezeServiceKeys.remove(serviceKey)
        } else {
            settings.autoFreezeServiceKeys.insert(serviceKey)
            tracking.serviceIdleSeconds[serviceKey] = 0
        }
    }

    public func clearEvents() {
        events.removeAll()
        eventStore.save(events)
    }

    // MARK: - Observers & Sampling

    private func installWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter

        frontmostObservation = NSWorkspace.shared.observe(\.frontmostApplication, options: [.new]) { [weak self] workspace, _ in
            let frontmost = workspace.frontmostApplication
            Task { @MainActor [weak self] in
                guard let self, let frontmost else { return }
                self.noteFrontmostChange(to: frontmost)
                self.handleAppWakeEvent(runningApp: frontmost, reason: .focusChange)
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
                self.noteFrontmostChange(to: runningApp)
                self.handleAppWakeEvent(runningApp: runningApp, reason: .windowActivated)
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
                self.handleAppWakeEvent(runningApp: runningApp, reason: .appOpened)
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
                self.handleAppWakeEvent(runningApp: runningApp, reason: .windowShown)
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
                self.tracking.forget(key)
                self.resumeCooldowns.removeValue(forKey: key)
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
        let windows = WindowInspector.readOnScreenWindows()

        let result = WindowInspector.hitTest(
            point: cgPoint,
            windows: windows,
            selfPID: getpid(),
            isFrozen: { [processController] pid in processController.frozenKey(forPID: pid) != nil },
            shellKind: { window in
                if WindowInspector.shellOwnerNames.contains(window.ownerName) { return .other }
                guard let bundleID = NSRunningApplication(processIdentifier: window.ownerPID)?.bundleIdentifier,
                      WindowInspector.shellBundleIDs.contains(bundleID) else {
                    return nil
                }
                return bundleID == "com.apple.dock" ? .dock : .other
            }
        )

        switch result {
        case .frozenWindow(let pid):
            if let frozenKey = processController.frozenKey(forPID: pid) {
                resumeByKey(frozenKey, fallbackName: nil, reason: .windowClick, refreshSnapshot: true)
            }
        case .dock(let dockPID):
            // A stopped app cannot answer the Dock's activation request, so the click on its
            // icon would otherwise do nothing. Needs Accessibility permission. The AX round-trip
            // to the Dock can take up to its timeout, so it runs off the main thread.
            guard WindowInspector.isAccessibilityTrusted else {
                Log.ui.debug("Dock click ignored: no Accessibility permission")
                return
            }
            let point = cgPoint
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let bundlePath = WindowInspector.dockItemBundlePath(dockPID: dockPID, point: point) else { return }
                await self?.resumeFrozenApps(atBundlePath: bundlePath)
            }
        case .none:
            break
        }
    }

    private func resumeFrozenApps(atBundlePath bundlePath: String) {
        let normalized = URL(fileURLWithPath: bundlePath).standardizedFileURL.path
        for app in currentApps where app.isFrozen {
            guard let appPath = app.bundlePath,
                  URL(fileURLWithPath: appPath).standardizedFileURL.path == normalized else { continue }
            resumeByKey(app.id, fallbackName: app.name, reason: .dockIconClick, refreshSnapshot: true)
        }
    }

    /// Attributes pasteboard writes to the app that was frontmost when they happened.
    private func notePasteboardChange(attributeTo key: String?) {
        let count = NSPasteboard.general.changeCount
        guard count != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = count
        if clipboardOwnerKey != key {
            Log.engine.info("Clipboard owner → \(key ?? "none", privacy: .public)")
        }
        clipboardOwnerKey = key
    }

    private func noteFrontmostChange(to runningApp: NSRunningApplication) {
        let key = appKey(for: runningApp)
        guard key != lastFrontmostAppKey else { return }
        // Anything copied since the last check was copied in the app we are leaving.
        notePasteboardChange(attributeTo: lastFrontmostAppKey)
        lastFrontmostAppKey = key
    }

    private func handleAppWakeEvent(runningApp: NSRunningApplication, reason: FreezeReason) {
        let key = appKey(for: runningApp)
        tracking.appIdleSeconds[key] = 0

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
        let waker = sampleWaker
        let intervalBox = samplingIntervalBox
        let selfPID = getpid()

        samplingTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                // Cooperative threads change between iterations; make sure this one can still
                // run the crash handler on a stack overflow.
                CrashGuard.ensureAltStackForCurrentThread()
                let memory = metrics.readMemoryStats()
                let scan = scanner.scanUserProcesses()
                let audio = metrics.readAudioActivity()
                let sleepPIDs = metrics.readSleepAssertionPIDs()
                let visiblePIDs = WindowInspector.visibleWindowPIDs(
                    windows: WindowInspector.readOnScreenWindows(),
                    selfPID: selfPID
                )

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let descriptors = self.captureRunningAppDescriptors()
                    let snapshot = RawSystemSnapshot(
                        timestamp: Date(),
                        memory: memory,
                        scan: scan,
                        audio: audio,
                        sleepAssertionPIDs: sleepPIDs,
                        visibleWindowPIDs: visiblePIDs,
                        runningApps: descriptors
                    )
                    self.lastRawSnapshot = snapshot
                    self.applySnapshot(snapshot, advanceIdleClock: true)
                }

                if Task.isCancelled { break }
                await waker.wait(seconds: intervalBox.get())
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
        let previousPressure = memoryStatsStorage.pressure
        memoryStatsStorage = snapshot.memory
        if isUIVisible || memoryStats.pressure != snapshot.memory.pressure {
            memoryStats = snapshot.memory
        }
        if advanceIdleClock && previousPressure != snapshot.memory.pressure {
            Log.engine.notice("Memory pressure \(previousPressure.rawValue, privacy: .public) → \(snapshot.memory.pressure.rawValue, privacy: .public)")
        }

        let awakeDelta: TimeInterval
        if advanceIdleClock {
            let frontKey = snapshot.runningApps.first(where: \.isFrontmost)?.key
            notePasteboardChange(attributeTo: frontKey)
            awakeDelta = SnapshotEvaluator.awakeDelta(
                now: snapshot.timestamp,
                previous: lastSampleTickDate,
                isAsleep: isSystemAsleep,
                maxStep: Self.maxAwakeStepSeconds
            )
            lastSampleTickDate = snapshot.timestamp
        } else {
            awakeDelta = 0
        }

        for key in SnapshotEvaluator.exitedRecordKeys(
            records: processController.allFrozenRecords(),
            samplesByPID: snapshot.scan.samplesByPID
        ) {
            Log.process.info("Dropping frozen record \(key, privacy: .public): processes exited")
            processController.pruneExitedRecord(appKey: key)
        }

        // Safety net: if a frozen app became frontmost, resume without recursive applySnapshot
        for desc in snapshot.runningApps where desc.isFrontmost {
            tracking.appIdleSeconds[desc.key] = 0
            if processController.frozenRecord(forKey: desc.key) != nil {
                resumeByKey(desc.key, fallbackName: desc.name, reason: .focusChange, refreshSnapshot: false)
            }
        }

        let grouping = ProcessScanner.groupProcesses(
            samplesByPID: snapshot.scan.samplesByPID,
            cpuPercentByPID: snapshot.scan.cpuPercentByPID,
            apps: snapshot.runningApps,
            protectedAncestors: snapshot.scan.protectedAncestors,
            currentPID: getpid()
        )

        let frozenRecords = Dictionary(
            processController.allFrozenRecords().map { ($0.appKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let input = SnapshotInput(
            now: snapshot.timestamp,
            awakeDelta: awakeDelta,
            settings: settings,
            memoryPressure: snapshot.memory.pressure,
            powerSource: snapshot.memory.powerSource,
            samplesByPID: snapshot.scan.samplesByPID,
            cpuPercentByPID: snapshot.scan.cpuPercentByPID,
            runningApps: snapshot.runningApps,
            grouping: grouping,
            audio: snapshot.audio,
            sleepAssertionPIDs: snapshot.sleepAssertionPIDs,
            visibleWindowPIDs: snapshot.visibleWindowPIDs,
            frozenRecords: frozenRecords,
            resumeCooldowns: resumeCooldowns,
            wakeCooldownUntil: wakeCooldownUntil,
            clipboardOwnerKey: clipboardOwnerKey
        )
        let (appDecisions, serviceDecisions) = SnapshotEvaluator.evaluate(input, state: &tracking)

        var nextApps: [TrackedApp] = []
        nextApps.reserveCapacity(appDecisions.count)
        var totalReclaimedDRAM: UInt64 = 0

        for decision in appDecisions {
            let desc = decision.descriptor
            var record = decision.frozenRecord
            var status = decision.outcome.status

            if decision.outcome.shouldAutoFreeze, record == nil {
                let isCPUHog = settings.freezeOnlyUnderPressure && snapshot.memory.pressure == .normal &&
                    decision.backgroundCPUPercent >= FreezePolicy.cpuHogThresholdPercent
                let reason = FreezeReason.idle(
                    seconds: decision.idleSeconds,
                    backgroundCPUPercent: isCPUHog ? Int(decision.backgroundCPUPercent.rounded()) : nil,
                    pressure: snapshot.memory.pressure == .normal ? nil : snapshot.memory.pressure
                )
                if let newRecord = processController.freeze(
                    appKey: desc.key,
                    appName: desc.name,
                    mainPID: desc.mainPID,
                    identities: decision.identities,
                    footprintBytes: decision.footprintBytes,
                    residentBytes: decision.residentBytes,
                    now: snapshot.timestamp,
                    cause: reason
                ) {
                    record = newRecord
                    status = .frozen(since: newRecord.frozenAt, pidCount: newRecord.identities.count)
                    noteFreezes(1)
                    appendEvent(kind: .frozen, title: desc.name, text: .frozenAuto(bytes: decision.footprintBytes, reason: reason))
                }
            }

            let app = SnapshotEvaluator.makeTrackedApp(
                decision,
                frozenRecord: record,
                status: status,
                rule: settings.rule(for: desc.bundleIdentifier)
            )
            totalReclaimedDRAM += app.reclaimedDRAMBytes
            nextApps.append(app)
        }

        var nextServices: [TrackedService] = []
        for decision in serviceDecisions {
            let candidate = decision.candidate
            var record = decision.frozenRecord
            if decision.shouldAutoFreeze, record == nil,
               let newRecord = processController.freeze(
                   appKey: candidate.serviceKey,
                   appName: candidate.name,
                   mainPID: candidate.mainPID,
                   identities: decision.identities,
                   footprintBytes: candidate.footprintBytes,
                   residentBytes: candidate.residentBytes,
                   now: snapshot.timestamp,
                   cause: .serviceAuto
               ) {
                record = newRecord
                noteFreezes(1)
                appendEvent(
                    kind: .frozen,
                    title: candidate.name,
                    text: .serviceAuto(bytes: newRecord.footprintAtFreezeBytes)
                )
            }
            let service = SnapshotEvaluator.makeTrackedService(decision, frozenRecord: record)
            totalReclaimedDRAM += service.reclaimedDRAMBytes
            nextServices.append(service)
        }

        if let owner = clipboardOwnerKey, !appDecisions.contains(where: { $0.descriptor.key == owner }) {
            clipboardOwnerKey = nil
        }
        resumeCooldowns = resumeCooldowns.filter { $0.value > snapshot.timestamp }

        currentApps = nextApps.sorted {
            if $0.footprintBytes != $1.footprintBytes {
                return $0.footprintBytes > $1.footprintBytes
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        currentServices = nextServices
        if totalReclaimedDRAMBytes != totalReclaimedDRAM {
            totalReclaimedDRAMBytes = totalReclaimedDRAM
        }
        syncFrozenCounters()

        if advanceIdleClock {
            statsStorage.accumulate(
                now: snapshot.timestamp,
                awakeDelta: awakeDelta,
                reclaimedBytes: totalReclaimedDRAM,
                frozenCount: frozenCount
            )
            if snapshot.timestamp.timeIntervalSince(lastStatsSave) >= 60 {
                lastStatsSave = snapshot.timestamp
                statsStore.save(statsStorage)
            }
            historyStorage.append(
                MemoryHistoryPoint(
                    timestamp: snapshot.timestamp,
                    usedRatio: snapshot.memory.usedRatio,
                    compressedRatio: snapshot.memory.compressedRatio,
                    reclaimedDRAMBytes: totalReclaimedDRAM
                )
            )
            if historyStorage.count > 60 {
                historyStorage.removeFirst(historyStorage.count - 60)
            }
        }

        if isUIVisible {
            publishUIState()
        }
        stateDidChange.send()
    }

    private func resumeByKey(_ key: String, fallbackName: String?, reason: FreezeReason, refreshSnapshot: Bool) {
        guard let record = processController.resume(appKey: key) else { return }
        let now = Date()
        tracking.resetIdle(key)
        resumeCooldowns[key] = now.addingTimeInterval(FreezePolicy.resumeCooldownSeconds)

        let title = fallbackName ?? record.appName
        appendEvent(
            kind: .resumed,
            title: title,
            text: .resumed(reason: reason)
        )
        syncFrozenCounters()

        if refreshSnapshot, let lastRawSnapshot {
            applySnapshot(lastRawSnapshot, advanceIdleClock: false)
        }
    }

    private func syncFrozenCounters() {
        let records = processController.allFrozenRecords()
        let count = records.count
        let bytes = records.reduce(UInt64(0)) { $0 + $1.footprintAtFreezeBytes }
        if frozenCount != count {
            frozenCount = count
            stateDidChange.send()
        }
        if totalFrozenFootprintBytes != bytes { totalFrozenFootprintBytes = bytes }
    }

    private func appendEvent(kind: ActivityEvent.Kind, title: String, text: EventText) {
        let detail = text.localized
        switch kind {
        case .frozen, .resumed, .recovered:
            Log.freeze.notice("\(kind.rawValue, privacy: .public) «\(title, privacy: .public)»: \(detail, privacy: .public)")
        case .relaunched, .skipped:
            Log.engine.info("\(kind.rawValue, privacy: .public) «\(title, privacy: .public)»: \(detail, privacy: .public)")
        }
        events.insert(ActivityEvent(kind: kind, title: title, text: text), at: 0)
        if events.count > Self.maxStoredEvents {
            events.removeLast(events.count - Self.maxStoredEvents)
        }
        eventStore.save(events)
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

/// Thread-safe holder for the current sampling interval, read by the detached sampling task.
final class SamplingIntervalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 5

    func get() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Double) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}
