import Foundation
import Testing
@testable import GiveMyRamBackCore

private final class MockSignaler: ProcessSignaling, @unchecked Sendable {
    private let lock = NSLock()
    var stopOrder: [Int32] = []
    var continueOrder: [Int32] = []
    var stoppedPIDs: Set<Int32> = []

    func sendStop(to identity: ProcessIdentity) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        stopOrder.append(identity.pid)
        stoppedPIDs.insert(identity.pid)
        return true
    }

    func sendContinue(to identity: ProcessIdentity) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        continueOrder.append(identity.pid)
        stoppedPIDs.remove(identity.pid)
        return true
    }

    func isCurrentlyStopped(identity: ProcessIdentity) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stoppedPIDs.contains(identity.pid)
    }
}

@Suite("GiveMyRamBackCore Tests")
struct GiveMyRamBackTests {
    @Test("ProcessScanner groups subtree and bundle helpers while excluding system processes and ancestors")
    func processGrouping() {
        let chromeMain = ProcessSample(
            pid: 100, ppid: 1, uid: 501, startTimeSec: 1000, startTimeUsec: 1,
            name: "Google Chrome",
            executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            footprintBytes: 300_000_000, residentBytes: 250_000_000, cpuTicks: 10, isStopped: false
        )
        let chromeChild = ProcessSample(
            pid: 101, ppid: 100, uid: 501, startTimeSec: 1001, startTimeUsec: 1,
            name: "Google Chrome Helper (Renderer)",
            executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper",
            footprintBytes: 600_000_000, residentBytes: 500_000_000, cpuTicks: 20, isStopped: false
        )
        let chromeXPC = ProcessSample(
            pid: 102, ppid: 1, uid: 501, startTimeSec: 1002, startTimeUsec: 1,
            name: "Google Chrome Helper (GPU)",
            executablePath: "/Applications/Google Chrome.app/Contents/MacOS/GPUHelper",
            footprintBytes: 200_000_000, residentBytes: 180_000_000, cpuTicks: 5, isStopped: false
        )
        let nodeParent = ProcessSample(
            pid: 200, ppid: 1, uid: 501, startTimeSec: 1003, startTimeUsec: 1,
            name: "node",
            executablePath: "/opt/homebrew/bin/node",
            footprintBytes: 150_000_000, residentBytes: 120_000_000, cpuTicks: 5, isStopped: false
        )
        let nodeWorker = ProcessSample(
            pid: 201, ppid: 200, uid: 501, startTimeSec: 1004, startTimeUsec: 1,
            name: "node-worker",
            executablePath: "/opt/homebrew/bin/node",
            footprintBytes: 100_000_000, residentBytes: 80_000_000, cpuTicks: 5, isStopped: false
        )
        let systemDaemon = ProcessSample(
            pid: 300, ppid: 1, uid: 501, startTimeSec: 1005, startTimeUsec: 1,
            name: "WebContent",
            executablePath: "/System/Library/Frameworks/WebKit.framework/WebContent",
            footprintBytes: 500_000_000, residentBytes: 400_000_000, cpuTicks: 5, isStopped: false
        )
        let ancestorTerminal = ProcessSample(
            pid: 50, ppid: 1, uid: 501, startTimeSec: 999, startTimeUsec: 1,
            name: "zsh",
            executablePath: "/bin/zsh",
            footprintBytes: 20_000_000, residentBytes: 15_000_000, cpuTicks: 1, isStopped: false
        )

        let samples = Dictionary(
            uniqueKeysWithValues: [
                chromeMain, chromeChild, chromeXPC, nodeParent, nodeWorker, systemDaemon, ancestorTerminal
            ].map { ($0.pid, $0) }
        )

        let chromeApp = RunningAppDescriptor(
            key: "app:com.google.Chrome:100",
            mainPID: 100,
            name: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            bundlePath: "/Applications/Google Chrome.app",
            isRegularApp: true,
            isFrontmost: false,
            isHidden: false,
            launchDate: Date().addingTimeInterval(-3600)
        )

        let grouped = ProcessScanner.groupProcesses(
            samplesByPID: samples,
            cpuPercentByPID: [:],
            apps: [chromeApp],
            protectedAncestors: [50, 999],
            currentPID: 999
        )

        let chromePIDs = grouped.appPIDsByKey[chromeApp.key] ?? []
        #expect(chromePIDs == [101, 102, 100])
        #expect(grouped.standaloneServices.count == 1)
        #expect(grouped.standaloneServices.first?.name == "node")
        #expect(grouped.standaloneServices.first?.pids == [201, 200])
        #expect(grouped.standaloneServices.first?.footprintBytes == 250_000_000)
        #expect(grouped.standaloneServices.first?.residentBytes == 200_000_000)
    }

    @Test("FreezePolicy enforces protections, fast rules, battery saver, and aggressive pressure scaling")
    func freezePolicyRules() {
        let now = Date()
        let baseSettings = EngineSettings(
            isAutoFreezeEnabled: true,
            idleTimeoutMinutes: 10,
            fastModeMinutes: 2,
            minMemoryThresholdMB: 250,
            aggressivePressureMode: true,
            batterySaverMode: true,
            protectAudioApps: true,
            protectSleepAssertions: true,
            protectDevAndSystemTools: true
        )

        let slack = RunningAppDescriptor(
            key: "app:com.tinyspeck.slackmacgap:500",
            mainPID: 500,
            name: "Slack",
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            bundlePath: "/Applications/Slack.app",
            isRegularApp: true,
            isFrontmost: false,
            isHidden: false,
            launchDate: now.addingTimeInterval(-600)
        )

        // 1. Audio protection via helper PID 501
        let audioCtx = FreezeEvaluationContext(
            settings: baseSettings,
            memoryPressure: .normal,
            powerSource: .ac,
            audioSnapshot: AudioActivitySnapshot(outputPIDs: [501], inputPIDs: []),
            sleepAssertionPIDs: [],
            now: now,
            wakeCooldownUntil: nil
        )
        let audioOutcome = FreezePolicy.evaluateApp(
            descriptor: slack,
            pids: [501, 500],
            footprintBytes: 800 * 1_048_576,
            idleSeconds: 900,
            frozenRecord: nil,
            resumeCooldownUntil: nil,
            context: audioCtx
        )
        #expect(!audioOutcome.shouldAutoFreeze)
        #expect(audioOutcome.protectionReasons == [.playingAudio])

        // 2. Audio protection via CoreAudio bundle ID
        let bundleAudioCtx = FreezeEvaluationContext(
            settings: baseSettings,
            memoryPressure: .normal,
            powerSource: .ac,
            audioSnapshot: AudioActivitySnapshot(inputBundleIDs: ["com.tinyspeck.slackmacgap"]),
            sleepAssertionPIDs: [],
            now: now,
            wakeCooldownUntil: nil
        )
        let bundleAudioOutcome = FreezePolicy.evaluateApp(
            descriptor: slack,
            pids: [500],
            footprintBytes: 800 * 1_048_576,
            idleSeconds: 900,
            frozenRecord: nil,
            resumeCooldownUntil: nil,
            context: bundleAudioCtx
        )
        #expect(!bundleAudioOutcome.shouldAutoFreeze)
        #expect(bundleAudioOutcome.protectionReasons == [.usingMicrophone])

        // 3. Sleep assertion protection
        let sleepCtx = FreezeEvaluationContext(
            settings: baseSettings,
            memoryPressure: .normal,
            powerSource: .ac,
            audioSnapshot: AudioActivitySnapshot(),
            sleepAssertionPIDs: [500],
            now: now,
            wakeCooldownUntil: nil
        )
        let sleepOutcome = FreezePolicy.evaluateApp(
            descriptor: slack,
            pids: [500],
            footprintBytes: 800 * 1_048_576,
            idleSeconds: 900,
            frozenRecord: nil,
            resumeCooldownUntil: nil,
            context: sleepCtx
        )
        #expect(!sleepOutcome.shouldAutoFreeze)
        #expect(sleepOutcome.protectionReasons == [.preventingSleep])

        // 4. Below threshold in .automatic vs bypassing threshold in .fast rule
        let cleanCtx = FreezeEvaluationContext(
            settings: baseSettings,
            memoryPressure: .normal,
            powerSource: .ac,
            audioSnapshot: AudioActivitySnapshot(),
            sleepAssertionPIDs: [],
            now: now,
            wakeCooldownUntil: nil
        )
        let lightOutcome = FreezePolicy.evaluateApp(
            descriptor: slack,
            pids: [500],
            footprintBytes: 120 * 1_048_576,
            idleSeconds: 900,
            frozenRecord: nil,
            resumeCooldownUntil: nil,
            context: cleanCtx
        )
        #expect(!lightOutcome.shouldAutoFreeze)
        #expect(lightOutcome.status == .belowThreshold)

        var fastSettings = baseSettings
        fastSettings.appRules["com.tinyspeck.slackmacgap"] = .fast
        let fastCtx = FreezeEvaluationContext(
            settings: fastSettings,
            memoryPressure: .normal,
            powerSource: .ac,
            audioSnapshot: AudioActivitySnapshot(),
            sleepAssertionPIDs: [],
            now: now,
            wakeCooldownUntil: nil
        )
        let fastOutcome = FreezePolicy.evaluateApp(
            descriptor: slack,
            pids: [500],
            footprintBytes: 120 * 1_048_576,
            idleSeconds: 130,
            frozenRecord: nil,
            resumeCooldownUntil: nil,
            context: fastCtx
        )
        #expect(fastOutcome.shouldAutoFreeze)

        // 5. Battery saver halves timeout (10m * 0.5 = 300s)
        let batteryCtx = FreezeEvaluationContext(
            settings: baseSettings,
            memoryPressure: .normal,
            powerSource: .battery,
            audioSnapshot: AudioActivitySnapshot(),
            sleepAssertionPIDs: [],
            now: now,
            wakeCooldownUntil: nil
        )
        let batteryOutcome = FreezePolicy.evaluateApp(
            descriptor: slack,
            pids: [500],
            footprintBytes: 600 * 1_048_576,
            idleSeconds: 310,
            frozenRecord: nil,
            resumeCooldownUntil: nil,
            context: batteryCtx
        )
        #expect(batteryOutcome.shouldAutoFreeze)

        // 6. Aggressive pressure scaling: 10 min * 0.25 = 150s in critical pressure
        let criticalCtx = FreezeEvaluationContext(
            settings: baseSettings,
            memoryPressure: .critical,
            powerSource: .ac,
            audioSnapshot: AudioActivitySnapshot(),
            sleepAssertionPIDs: [],
            now: now,
            wakeCooldownUntil: nil
        )
        let criticalOutcome = FreezePolicy.evaluateApp(
            descriptor: slack,
            pids: [500],
            footprintBytes: 600 * 1_048_576,
            idleSeconds: 160,
            frozenRecord: nil,
            resumeCooldownUntil: nil,
            context: criticalCtx
        )
        #expect(criticalOutcome.shouldAutoFreeze)

        // 7. Built-in Terminal safelist
        let terminal = RunningAppDescriptor(
            key: "app:com.apple.Terminal:700",
            mainPID: 700,
            name: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            bundlePath: "/System/Applications/Utilities/Terminal.app",
            isRegularApp: true,
            isFrontmost: false,
            isHidden: false,
            launchDate: now.addingTimeInterval(-600)
        )
        let terminalOutcome = FreezePolicy.evaluateApp(
            descriptor: terminal,
            pids: [700],
            footprintBytes: 600 * 1_048_576,
            idleSeconds: 9999,
            frozenRecord: nil,
            resumeCooldownUntil: nil,
            context: criticalCtx
        )
        #expect(!terminalOutcome.shouldAutoFreeze)
        #expect(terminalOutcome.protectionReasons == [.builtInSafelist])
    }

    @Test("ProcessController freezes helpers before main, resumes main before helpers, and recovers persisted state")
    func processControllerOrderAndRecovery() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gmrb-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let stateURL = tempDir.appendingPathComponent("frozen_state.json")

        let signaler = MockSignaler()
        let controller = ProcessController(signaler: signaler, stateFileURL: stateURL)

        let mainID = ProcessIdentity(pid: 10, startTimeSec: 100, startTimeUsec: 1, name: "App")
        let helper1 = ProcessIdentity(pid: 11, startTimeSec: 101, startTimeUsec: 1, name: "Helper1")
        let helper2 = ProcessIdentity(pid: 12, startTimeSec: 102, startTimeUsec: 1, name: "Helper2")

        let record = controller.freeze(
            appKey: "app:test:10",
            appName: "TestApp",
            mainPID: 10,
            identities: [mainID, helper1, helper2],
            footprintBytes: 500_000_000,
            residentBytes: 420_000_000
        )
        #expect(record != nil)
        #expect(record?.residentAtFreezeBytes == 420_000_000)
        #expect(signaler.stopOrder == [11, 12, 10])
        #expect(FileManager.default.fileExists(atPath: stateURL.path))

        let recoveredController = ProcessController(signaler: signaler, stateFileURL: stateURL)
        let recoveredNames = recoveredController.recoverFromPreviousRun()
        #expect(recoveredNames == ["TestApp"])
        #expect(signaler.continueOrder == [10, 12, 11])
        #expect(!FileManager.default.fileExists(atPath: stateURL.path))
    }

    @Test("Live system metrics, process scan, and real SIGSTOP/SIGCONT on ephemeral subprocess")
    func liveSystemIntegrationSmokeTest() throws {
        let metrics = SystemMetricsCollector()
        let memStats = metrics.readMemoryStats()
        #expect(memStats.totalPhysicalBytes > 0)
        #expect(memStats.usedBytes > 0)

        let scanner = ProcessScanner()
        let scan = scanner.scanUserProcesses()
        let selfPID = getpid()
        #expect(scan.samplesByPID[selfPID] != nil)
        #expect((scan.samplesByPID[selfPID]?.startTimeSec ?? 0) > 0)
        #expect((scan.samplesByPID[selfPID]?.residentBytes ?? 0) > 0)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["5"]
        try proc.run()
        defer {
            if proc.isRunning {
                Darwin.kill(proc.processIdentifier, SIGCONT)
                proc.terminate()
                proc.waitUntilExit()
            }
        }

        let childPID = proc.processIdentifier
        let bsd = try #require(ProcessScanner.readBSDInfo(pid: childPID))
        let identity = ProcessIdentity(
            pid: childPID,
            startTimeSec: bsd.pbi_start_tvsec,
            startTimeUsec: bsd.pbi_start_tvusec,
            name: "sleep"
        )

        let tempState = FileManager.default.temporaryDirectory
            .appendingPathComponent("gmrb-live-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempState) }

        let controller = ProcessController(signaler: LiveProcessSignaler(), stateFileURL: tempState)
        let frozen = controller.freeze(
            appKey: "test:sleep:\(childPID)",
            appName: "sleep",
            mainPID: childPID,
            identities: [identity],
            footprintBytes: 1_048_576,
            residentBytes: 524_288
        )
        #expect(frozen != nil)
        #expect(LiveProcessSignaler().isCurrentlyStopped(identity: identity))

        let resumed = controller.resumeAll()
        #expect(resumed.count == 1)
        #expect(!LiveProcessSignaler().isCurrentlyStopped(identity: identity))

        // Verify mismatched start time prevents signaling an unrelated reused PID
        let mismatchedIdentity = ProcessIdentity(
            pid: childPID,
            startTimeSec: bsd.pbi_start_tvsec + 999,
            startTimeUsec: bsd.pbi_start_tvusec,
            name: "sleep"
        )
        #expect(!LiveProcessSignaler().sendStop(to: mismatchedIdentity))
        #expect(!LiveProcessSignaler().sendContinue(to: mismatchedIdentity))
        #expect(!LiveProcessSignaler().isCurrentlyStopped(identity: mismatchedIdentity))
    }

    @Test("Two instances of the same bundle never duplicate or steal each other's helpers")
    func duplicateBundleInstancesDoNotOverlapHelpers() {
        let app1 = ProcessSample(
            pid: 1000, ppid: 1, uid: 501, startTimeSec: 1, startTimeUsec: 1,
            name: "Editor", executablePath: "/Applications/Editor.app/Contents/MacOS/Editor",
            footprintBytes: 200_000_000, cpuTicks: 1, isStopped: false
        )
        let helper1 = ProcessSample(
            pid: 1001, ppid: 1000, uid: 501, startTimeSec: 2, startTimeUsec: 1,
            name: "Helper1", executablePath: "/Applications/Editor.app/Contents/MacOS/Helper",
            footprintBytes: 300_000_000, cpuTicks: 1, isStopped: false
        )
        let app2 = ProcessSample(
            pid: 2000, ppid: 1, uid: 501, startTimeSec: 3, startTimeUsec: 1,
            name: "Editor", executablePath: "/Applications/Editor.app/Contents/MacOS/Editor",
            footprintBytes: 200_000_000, cpuTicks: 1, isStopped: false
        )
        let helper2 = ProcessSample(
            pid: 2001, ppid: 2000, uid: 501, startTimeSec: 4, startTimeUsec: 1,
            name: "Helper2", executablePath: "/Applications/Editor.app/Contents/MacOS/Helper",
            footprintBytes: 300_000_000, cpuTicks: 1, isStopped: false
        )

        let samples = Dictionary(
            uniqueKeysWithValues: [app1, helper1, app2, helper2].map { ($0.pid, $0) }
        )

        let desc1 = RunningAppDescriptor(
            key: "app:dev.editor:1000", mainPID: 1000, name: "Editor",
            bundleIdentifier: "dev.editor", bundlePath: "/Applications/Editor.app",
            isRegularApp: true, isFrontmost: false, isHidden: false, launchDate: nil
        )
        let desc2 = RunningAppDescriptor(
            key: "app:dev.editor:2000", mainPID: 2000, name: "Editor",
            bundleIdentifier: "dev.editor", bundlePath: "/Applications/Editor.app",
            isRegularApp: true, isFrontmost: true, isHidden: false, launchDate: nil
        )

        let grouped = ProcessScanner.groupProcesses(
            samplesByPID: samples,
            cpuPercentByPID: [:],
            apps: [desc1, desc2],
            protectedAncestors: [],
            currentPID: 9999
        )

        #expect(grouped.appPIDsByKey[desc1.key] == [1001, 1000])
        #expect(grouped.appPIDsByKey[desc2.key] == [2001, 2000])
    }

    @Test("Exclusive file lock prevents concurrent open and releases on close")
    func exclusiveLockBehavior() {
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gmrb-lock-\(UUID().uuidString).lock")
        defer { try? FileManager.default.removeItem(at: lockURL) }

        let fd1 = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK, 0o644)
        #expect(fd1 >= 0)

        let fd2 = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK, 0o644)
        #expect(fd2 < 0)
        #expect(errno == EWOULDBLOCK || errno == EAGAIN)

        Darwin.close(fd1)

        let fd3 = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK, 0o644)
        #expect(fd3 >= 0)
        Darwin.close(fd3)
    }
}
