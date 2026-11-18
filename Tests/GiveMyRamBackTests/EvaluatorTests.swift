import CoreGraphics
import Foundation
import Testing
@testable import GiveMyRamBackCore

private let mb: UInt64 = 1_048_576

private struct World {
    var now = Date(timeIntervalSince1970: 1_000_000)
    var settings = EngineSettings()
    var pressure: MemoryPressureLevel = .normal
    var cpu: [Int32: Double] = [:]
    var frontmost = false
    var visible: Set<Int32> = []
    var frozen: [String: FrozenRecord] = [:]
    var optedServices: Set<String> = []

    let appKey = "app:com.example.Big:100"

    func input(delta: TimeInterval) -> SnapshotInput {
        let app = RunningAppDescriptor(
            key: appKey, mainPID: 100, name: "Big", bundleIdentifier: "com.example.Big",
            bundlePath: "/Applications/Big.app", isRegularApp: true, isFrontmost: frontmost,
            isHidden: false, launchDate: now.addingTimeInterval(-3600)
        )
        let samples: [Int32: ProcessSample] = [
            100: ProcessSample(pid: 100, ppid: 1, uid: 501, startTimeSec: 1, startTimeUsec: 1, name: "Big",
                               executablePath: "/Applications/Big.app/Contents/MacOS/Big",
                               footprintBytes: 900 * mb, residentBytes: 700 * mb, cpuTicks: 0, isStopped: false),
            200: ProcessSample(pid: 200, ppid: 1, uid: 501, startTimeSec: 2, startTimeUsec: 1, name: "syncd",
                               executablePath: "/opt/tools/syncd",
                               footprintBytes: 300 * mb, residentBytes: 250 * mb, cpuTicks: 0, isStopped: false)
        ]
        let service = GroupedServiceCandidate(
            serviceKey: "svc:/opt/tools/syncd", mainPID: 200, pids: [200], name: "syncd",
            executablePath: "/opt/tools/syncd", footprintBytes: 300 * mb, residentBytes: 250 * mb,
            cpuPercent: cpu[200] ?? 0, isStopped: false
        )
        var s = settings
        s.autoFreezeServiceKeys = optedServices
        return SnapshotInput(
            now: now, awakeDelta: delta, settings: s, memoryPressure: pressure, powerSource: .ac,
            samplesByPID: samples, cpuPercentByPID: cpu, runningApps: [app],
            grouping: ProcessGroupingResult(appPIDsByKey: [appKey: [100]], standaloneServices: [service]),
            visibleWindowPIDs: visible, frozenRecords: frozen
        )
    }

    /// Advances the clock in `step`-second ticks for `total` seconds; returns the last result.
    mutating func run(_ total: TimeInterval, step: TimeInterval = 5, state: inout TrackingState) -> (apps: [AppDecision], services: [ServiceDecision]) {
        var last = SnapshotEvaluator.evaluate(input(delta: 0), state: &state)
        var elapsed: TimeInterval = 0
        while elapsed < total {
            now = now.addingTimeInterval(step)
            elapsed += step
            last = SnapshotEvaluator.evaluate(input(delta: step), state: &state)
        }
        return last
    }
}

@Suite("Snapshot evaluator & pressure-only mode")
struct EvaluatorTests {
    @Test("Idle clock accumulates in the background, resets when frontmost or visible")
    func idleClock() {
        var world = World()
        var state = TrackingState()
        var result = world.run(120, state: &state)
        #expect(result.apps.first?.idleSeconds == 120)

        world.visible = [100]
        result = world.run(5, state: &state)
        #expect(result.apps.first?.idleSeconds == 0)

        world.visible = []
        result = world.run(30, state: &state)
        #expect(result.apps.first?.idleSeconds == 30)

        world.frontmost = true
        result = world.run(5, state: &state)
        #expect(result.apps.first?.idleSeconds == 0)
    }

    @Test("Default mode freezes after the timeout; pressure-only waits for pressure")
    func pressureOnlyMode() {
        var world = World()
        var state = TrackingState()
        let defaultResult = world.run(10 * 60 + 5, state: &state)
        #expect(defaultResult.apps.first?.outcome.shouldAutoFreeze == true)

        world = World()
        world.settings.freezeOnlyUnderPressure = true
        state = TrackingState()
        let waiting = world.run(30 * 60, state: &state)
        #expect(waiting.apps.first?.outcome.shouldAutoFreeze == false)
        #expect(waiting.apps.first?.outcome.status == .waitingForPressure)

        // Batch «Вернуть RAM сейчас» is still allowed: the user explicitly asked for RAM.
        let app = SnapshotEvaluator.makeTrackedApp(waiting.apps[0], frozenRecord: nil,
                                                   status: waiting.apps[0].outcome.status, rule: .automatic)
        #expect(app.isEligibleForBatchFreezeNow)

        world.pressure = .warning
        let underPressure = world.run(5, state: &state)
        #expect(underPressure.apps.first?.outcome.shouldAutoFreeze == true)
    }

    @Test("Pressure-only mode still freezes background CPU hogs")
    func cpuHogUnderNormalPressure() {
        var world = World()
        world.settings.freezeOnlyUnderPressure = true
        world.cpu = [100: 25]
        var state = TrackingState()
        let result = world.run(11 * 60, state: &state)
        #expect((result.apps.first?.backgroundCPUPercent ?? 0) > FreezePolicy.cpuHogThresholdPercent)
        #expect(result.apps.first?.outcome.shouldAutoFreeze == true)

        // A short burst does not count: the average decays back below the threshold.
        world.cpu = [100: 0]
        _ = world.run(5 * 60, state: &state)
        #expect((state.backgroundCPU[world.appKey] ?? 0) < FreezePolicy.cpuHogThresholdPercent)
    }

    @Test("Opted-in services follow the same timeout and pressure-only rules")
    func serviceDecisions() {
        var world = World()
        world.optedServices = ["svc:/opt/tools/syncd"]
        var state = TrackingState()
        var result = world.run(10 * 60 + 5, state: &state)
        #expect(result.services.first?.shouldAutoFreeze == true)

        world = World()
        world.optedServices = ["svc:/opt/tools/syncd"]
        world.settings.freezeOnlyUnderPressure = true
        state = TrackingState()
        result = world.run(20 * 60, state: &state)
        #expect(result.services.first?.shouldAutoFreeze == false)

        world.pressure = .critical
        result = world.run(5, state: &state)
        #expect(result.services.first?.shouldAutoFreeze == true)
    }

    @Test("Bookkeeping for vanished apps is dropped")
    func pruning() {
        var world = World()
        var state = TrackingState()
        _ = world.run(60, state: &state)
        #expect(state.appIdleSeconds[world.appKey] != nil)

        let empty = SnapshotInput(
            now: world.now, awakeDelta: 5, settings: EngineSettings(), memoryPressure: .normal, powerSource: .ac,
            samplesByPID: [:], cpuPercentByPID: [:], runningApps: [],
            grouping: ProcessGroupingResult(appPIDsByKey: [:], standaloneServices: [])
        )
        _ = SnapshotEvaluator.evaluate(empty, state: &state)
        #expect(state == TrackingState())
    }

    @Test("Awake delta is clamped and zero while asleep")
    func awakeDelta() {
        let t0 = Date(timeIntervalSince1970: 0)
        #expect(SnapshotEvaluator.awakeDelta(now: t0.addingTimeInterval(5), previous: t0, isAsleep: false, maxStep: 12) == 5)
        #expect(SnapshotEvaluator.awakeDelta(now: t0.addingTimeInterval(3600), previous: t0, isAsleep: false, maxStep: 12) == 12)
        #expect(SnapshotEvaluator.awakeDelta(now: t0.addingTimeInterval(-50), previous: t0, isAsleep: false, maxStep: 12) == 0)
        #expect(SnapshotEvaluator.awakeDelta(now: t0.addingTimeInterval(5), previous: t0, isAsleep: true, maxStep: 12) == 0)
    }

    @Test("Clicks pass through our own overlay windows to the frozen window")
    func overlayPassThrough() {
        let selfPID: Int32 = 999
        let frozen = OnScreenWindow(windowID: 10, ownerPID: 42, ownerName: "Chrome", layer: 0, alpha: 1,
                                    bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let overlay = OnScreenWindow(windowID: 11, ownerPID: selfPID, ownerName: "GiveMyRamBack", layer: 0, alpha: 1,
                                     bounds: frozen.bounds)
        let popover = OnScreenWindow(windowID: 12, ownerPID: selfPID, ownerName: "GiveMyRamBack", layer: 101, alpha: 1,
                                     bounds: CGRect(x: 100, y: 0, width: 300, height: 400))
        let windows = [popover, overlay, frozen]
        func hit(_ p: CGPoint) -> ClickHitResult {
            WindowInspector.hitTest(point: p, windows: windows, selfPID: selfPID,
                                    isFrozen: { $0 == 42 }, shellKind: { _ in nil })
        }
        #expect(hit(CGPoint(x: 600, y: 300)) == .frozenWindow(pid: 42))
        #expect(hit(CGPoint(x: 200, y: 100)) == .none)
    }
}
