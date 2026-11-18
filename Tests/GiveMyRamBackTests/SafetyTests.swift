import CoreGraphics
import Darwin
import Foundation
import Testing
@testable import GiveMyRamBackCore

private let mb: UInt64 = 1_048_576

private func descriptor(
    key: String = "app:com.example.App:900",
    pid: Int32 = 900,
    bundleID: String = "com.example.App",
    regular: Bool = true,
    now: Date
) -> RunningAppDescriptor {
    RunningAppDescriptor(
        key: key,
        mainPID: pid,
        name: "Example",
        bundleIdentifier: bundleID,
        bundlePath: "/Applications/Example.app",
        isRegularApp: regular,
        isFrontmost: false,
        isHidden: false,
        launchDate: now.addingTimeInterval(-3600)
    )
}

private func context(
    _ settings: EngineSettings = EngineSettings(),
    now: Date,
    visible: Set<Int32> = [],
    clipboardOwner: String? = nil
) -> FreezeEvaluationContext {
    FreezeEvaluationContext(
        settings: settings,
        memoryPressure: .normal,
        powerSource: .ac,
        audioSnapshot: AudioActivitySnapshot(),
        sleepAssertionPIDs: [],
        now: now,
        wakeCooldownUntil: nil,
        visibleWindowPIDs: visible,
        clipboardOwnerKey: clipboardOwner
    )
}

private func trackedApp(from outcome: AppEvaluationOutcome, desc: RunningAppDescriptor, rule: AppFreezeRule = .automatic) -> TrackedApp {
    TrackedApp(
        id: desc.key, bundleIdentifier: desc.bundleIdentifier, name: desc.name, bundlePath: desc.bundlePath,
        mainPID: desc.mainPID, pids: [desc.mainPID], footprintBytes: 0, cpuPercent: 0,
        isFrozen: false, status: outcome.status, rule: rule, idleSeconds: 0, isRegularApp: desc.isRegularApp
    )
}

private func evaluate(_ desc: RunningAppDescriptor, bytes: UInt64, idle: TimeInterval = 0, _ ctx: FreezeEvaluationContext) -> AppEvaluationOutcome {
    FreezePolicy.evaluateApp(
        descriptor: desc, pids: [desc.mainPID], footprintBytes: bytes, idleSeconds: idle,
        frozenRecord: nil, resumeCooldownUntil: nil, context: ctx
    )
}

@Suite("Safety fixes")
struct SafetyTests {
    // MARK: 1. Batch freeze eligibility

    @Test("Batch freeze skips menu-bar agents and small apps, honours «Быстро» opt-in")
    func batchEligibility() {
        let now = Date()
        let agent = descriptor(regular: false, now: now)

        // Small accessory app: below threshold, never batch-frozen.
        let small = evaluate(agent, bytes: 40 * mb, context(now: now))
        #expect(small.status == .belowThreshold)
        #expect(!trackedApp(from: small, desc: agent).isEligibleForBatchFreezeNow)

        // Large accessory app: manual only, still not part of batch freeze.
        let large = evaluate(agent, bytes: 600 * mb, context(now: now))
        #expect(large.status == .manualOnly)
        #expect(!trackedApp(from: large, desc: agent).isEligibleForBatchFreezeNow)

        // Explicit «Быстро» rule opts it in.
        var fast = EngineSettings()
        fast.appRules[agent.bundleIdentifier!] = .fast
        let fastOutcome = evaluate(agent, bytes: 600 * mb, context(fast, now: now))
        #expect(trackedApp(from: fastOutcome, desc: agent, rule: .fast).isEligibleForBatchFreezeNow)

        // Auto-freeze off: tiny regular apps are below threshold, big ones are batch candidates.
        let off = EngineSettings(isAutoFreezeEnabled: false)
        let regular = descriptor(now: now)
        let tiny = evaluate(regular, bytes: 20 * mb, context(off, now: now))
        #expect(tiny.status == .belowThreshold)
        #expect(!trackedApp(from: tiny, desc: regular).isEligibleForBatchFreezeNow)
        let heavy = evaluate(regular, bytes: 900 * mb, context(off, now: now))
        #expect(heavy.status == .manualOnly)
        #expect(trackedApp(from: heavy, desc: regular).isEligibleForBatchFreezeNow)
    }

    // MARK: 5 & 8. Visible windows and clipboard owner

    @Test("Visible window and clipboard owner protect an otherwise freezable app")
    func visibleAndClipboardProtection() {
        let now = Date()
        let app = descriptor(now: now)

        let baseline = evaluate(app, bytes: 900 * mb, idle: 3600, context(now: now))
        #expect(baseline.shouldAutoFreeze)

        let visible = evaluate(app, bytes: 900 * mb, idle: 3600, context(now: now, visible: [app.mainPID]))
        #expect(!visible.shouldAutoFreeze)
        #expect(visible.protectionReasons == [.visibleOnScreen])

        var visibleOff = EngineSettings()
        visibleOff.keepVisibleWindowsAwake = false
        #expect(evaluate(app, bytes: 900 * mb, idle: 3600, context(visibleOff, now: now, visible: [app.mainPID])).shouldAutoFreeze)

        let clip = evaluate(app, bytes: 900 * mb, idle: 3600, context(now: now, clipboardOwner: app.key))
        #expect(!clip.shouldAutoFreeze)
        #expect(clip.protectionReasons == [.clipboardOwner])
        #expect(!trackedApp(from: clip, desc: app).isEligibleForBatchFreezeNow)

        let otherOwner = evaluate(app, bytes: 900 * mb, idle: 3600, context(now: now, clipboardOwner: "app:other:1"))
        #expect(otherOwner.shouldAutoFreeze)
    }

    @Test("Visible-window detection accounts for occlusion")
    func visibleWindowOcclusion() {
        let front = OnScreenWindow(ownerPID: 1, ownerName: "Editor", layer: 0, alpha: 1,
                                   bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let coveredBehind = OnScreenWindow(ownerPID: 2, ownerName: "Browser", layer: 0, alpha: 1,
                                           bounds: CGRect(x: 100, y: 100, width: 600, height: 400))
        let sideBySide = OnScreenWindow(ownerPID: 3, ownerName: "Dashboard", layer: 0, alpha: 1,
                                        bounds: CGRect(x: 1000, y: 0, width: 900, height: 800))
        let peeking = OnScreenWindow(ownerPID: 4, ownerName: "Mail", layer: 0, alpha: 1,
                                     bounds: CGRect(x: 900, y: 0, width: 400, height: 800)) // mostly behind 1 and 3
        let tiny = OnScreenWindow(ownerPID: 5, ownerName: "Widget", layer: 0, alpha: 1,
                                  bounds: CGRect(x: 2000, y: 0, width: 80, height: 60))
        let menuBar = OnScreenWindow(ownerPID: 6, ownerName: "Window Server", layer: 24, alpha: 1,
                                     bounds: CGRect(x: 0, y: 0, width: 3000, height: 24))

        let visible = WindowInspector.visibleWindowPIDs(
            windows: [menuBar, front, sideBySide, coveredBehind, peeking, tiny],
            selfPID: 999
        )
        #expect(visible == [1, 3])
    }

    // MARK: 2. Click hit-testing

    @Test("Clicks on the Dock or banners never wake the frozen window behind them")
    func clickHitTest() {
        let frozenPID: Int32 = 42
        let dockPID: Int32 = 7
        let bannerPID: Int32 = 8
        let frozenWindow = OnScreenWindow(ownerPID: frozenPID, ownerName: "Chrome", layer: 0, alpha: 1,
                                          bounds: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let dock = OnScreenWindow(ownerPID: dockPID, ownerName: "Dock", layer: 20, alpha: 1,
                                  bounds: CGRect(x: 300, y: 820, width: 800, height: 80))
        let banner = OnScreenWindow(ownerPID: bannerPID, ownerName: "Notification Center", layer: 23, alpha: 1,
                                    bounds: CGRect(x: 1100, y: 40, width: 330, height: 90))
        let hud = OnScreenWindow(ownerPID: 9, ownerName: "SomeHUD", layer: 3, alpha: 1,
                                 bounds: CGRect(x: 600, y: 400, width: 200, height: 100))
        let editor = OnScreenWindow(ownerPID: 10, ownerName: "Editor", layer: 0, alpha: 1,
                                    bounds: CGRect(x: 0, y: 0, width: 500, height: 500))
        let windows = [banner, dock, hud, editor, frozenWindow]

        func hit(_ p: CGPoint) -> ClickHitResult {
            WindowInspector.hitTest(
                point: p, windows: windows, selfPID: 999,
                isFrozen: { $0 == frozenPID },
                shellKind: { w in
                    w.ownerPID == dockPID ? .dock : (w.ownerPID == bannerPID ? .other : nil)
                }
            )
        }

        #expect(hit(CGPoint(x: 700, y: 860)) == .dock(pid: dockPID))
        #expect(hit(CGPoint(x: 1200, y: 80)) == .none)
        #expect(hit(CGPoint(x: 700, y: 450)) == .frozenWindow(pid: frozenPID))   // through third-party HUD
        #expect(hit(CGPoint(x: 200, y: 200)) == .none)                           // editor is in front
        #expect(hit(CGPoint(x: 1000, y: 300)) == .frozenWindow(pid: frozenPID))
    }

    // MARK: 3. Crash safety

    @Test("Freeze record is on disk before the first SIGSTOP is sent")
    func writeAheadPersistence() throws {
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gmrb-wal-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: stateURL) }

        final class Probe: ProcessSignaling, @unchecked Sendable {
            let url: URL
            var sawRecordBeforeStop: [Bool] = []
            init(url: URL) { self.url = url }
            func sendStop(to identity: ProcessIdentity) -> Bool {
                let records = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([FrozenRecord].self, from: $0) } ?? []
                sawRecordBeforeStop.append(records.contains { $0.appKey == "app:test" && $0.identities.contains(identity) })
                return true
            }
            func sendContinue(to identity: ProcessIdentity) -> Bool { true }
            func isCurrentlyStopped(identity: ProcessIdentity) -> Bool { false }
        }

        let probe = Probe(url: stateURL)
        let controller = ProcessController(signaler: probe, stateFileURL: stateURL)
        let ids = [
            ProcessIdentity(pid: 11, startTimeSec: 1, startTimeUsec: 1, name: "helper"),
            ProcessIdentity(pid: 10, startTimeSec: 1, startTimeUsec: 2, name: "main")
        ]
        let record = controller.freeze(appKey: "app:test", appName: "Test", mainPID: 10, identities: ids, footprintBytes: 1)
        #expect(record != nil)
        #expect(probe.sawRecordBeforeStop == [true, true])
    }

    @Test("Failed freeze rolls the write-ahead record back")
    func writeAheadRollback() {
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gmrb-wal-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: stateURL) }

        struct Refuse: ProcessSignaling {
            func sendStop(to identity: ProcessIdentity) -> Bool { false }
            func sendContinue(to identity: ProcessIdentity) -> Bool { true }
            func isCurrentlyStopped(identity: ProcessIdentity) -> Bool { false }
        }
        let controller = ProcessController(signaler: Refuse(), stateFileURL: stateURL)
        let id = ProcessIdentity(pid: 10, startTimeSec: 1, startTimeUsec: 2, name: "main")
        #expect(controller.freeze(appKey: "app:x", appName: "X", mainPID: 10, identities: [id], footprintBytes: 1) == nil)
        #expect(controller.frozenCount() == 0)
        #expect(!FileManager.default.fileExists(atPath: stateURL.path))
    }

    @Test("Watchdog wait returns when the watched process exits, including already-dead PIDs")
    func watchdogWaitsForExit() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["0.3"]
        try child.run()

        let start = Date()
        CrashGuard.waitForExit(of: child.processIdentifier)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed >= 0.2 && elapsed < 5)

        child.waitUntilExit()
        let again = Date()
        CrashGuard.waitForExit(of: child.processIdentifier)
        #expect(Date().timeIntervalSince(again) < 1)
    }

    // MARK: Settings migration

    @Test("Settings saved by an older build keep the user's rules and get new defaults")
    func tolerantSettingsDecoding() throws {
        let legacyJSON = """
        {"isAutoFreezeEnabled":false,"idleTimeoutMinutes":25,"fastModeMinutes":3,"minMemoryThresholdMB":400,
         "aggressivePressureMode":false,"batterySaverMode":true,"protectAudioApps":true,"protectSleepAssertions":true,
         "protectDevAndSystemTools":true,"menuBarDisplayMode":"frozenCount",
         "appRules":{"com.tinyspeck.slackmacgap":"protected"},"appRuleDisplayNames":{"com.tinyspeck.slackmacgap":"Slack"},
         "autoFreezeServiceKeys":["svc:/opt/x"]}
        """
        let decoded = try JSONDecoder().decode(EngineSettings.self, from: Data(legacyJSON.utf8))
        #expect(decoded.isAutoFreezeEnabled == false)
        #expect(decoded.idleTimeoutMinutes == 25)
        #expect(decoded.appRules["com.tinyspeck.slackmacgap"] == .protected)
        #expect(decoded.menuBarDisplayMode == .frozenCount)
        #expect(decoded.keepVisibleWindowsAwake == true)
        #expect(decoded.protectClipboardOwner == true)

        let roundTrip = try JSONDecoder().decode(EngineSettings.self, from: JSONEncoder().encode(decoded))
        #expect(roundTrip == decoded)
    }
}
