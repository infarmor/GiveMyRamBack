import Foundation
import Testing
@testable import GiveMyRamBackCore

@Suite("Updates, statistics and explanations")
struct FeatureTests {
    // MARK: Update checker

    @Test("Version comparison handles prefixes, suffixes and different lengths")
    func versionComparison() {
        #expect(VersionComparator.isNewer("2.2.0", than: "2.1.0"))
        #expect(VersionComparator.isNewer("v2.10", than: "2.9.9"))
        #expect(VersionComparator.isNewer("3", than: "2.99"))
        #expect(!VersionComparator.isNewer("2.1", than: "2.1.0"))
        #expect(!VersionComparator.isNewer("2.1.0", than: "2.1.0"))
        #expect(!VersionComparator.isNewer("2.0.9", than: "2.1"))
        #expect(VersionComparator.isNewer("2.2.0-beta", than: "2.1.5"))
        #expect(VersionComparator.components("v1.2.3+45") == [1, 2, 3])
    }

    @Test("GitHub release payload is parsed; drafts and pre-releases are ignored")
    func releaseParsing() throws {
        let stable = Data("""
        {"tag_name":"v2.2.0","html_url":"https://github.com/infarmor/GiveMyRamBack/releases/tag/v2.2.0","draft":false,"prerelease":false,"assets":[]}
        """.utf8)
        let release = try UpdateChecker.parseLatestRelease(stable)
        #expect(release?.version == "2.2.0")
        #expect(release?.url.absoluteString.hasSuffix("/v2.2.0") == true)

        let pre = Data(#"{"tag_name":"v3.0.0","html_url":"https://example.com","prerelease":true}"#.utf8)
        #expect(try UpdateChecker.parseLatestRelease(pre) == nil)

        #expect(throws: (any Error).self) {
            try UpdateChecker.parseLatestRelease(Data(#"{"message":"Not Found"}"#.utf8))
        }
    }

    // MARK: Statistics

    @Test("Daily statistics accumulate freezes, paused time and average RAM given back")
    func usageStats() throws {
        var stats = UsageStats()
        let calendar = Calendar.current
        let day1 = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 10)))
        let day2 = try #require(calendar.date(byAdding: .day, value: 1, to: day1))

        stats.recordFreezes(2, now: day1)
        // 60 s with 1 GB reclaimed, then 60 s with 3 GB → average 2 GB, peak 3 GB.
        stats.accumulate(now: day1, awakeDelta: 60, reclaimedBytes: 1 << 30, frozenCount: 1)
        stats.accumulate(now: day1, awakeDelta: 60, reclaimedBytes: 3 << 30, frozenCount: 2)
        // Nothing paused: no paused time.
        stats.accumulate(now: day1, awakeDelta: 60, reclaimedBytes: 0, frozenCount: 0)

        let today = stats.today(now: day1)
        #expect(today.freezes == 2)
        #expect(today.pausedSeconds == 120)
        #expect(today.averageReclaimedBytes == 2 << 30)
        #expect(today.peakReclaimedBytes == 3 << 30)

        stats.recordFreezes(5, now: day2)
        #expect(stats.today(now: day2).freezes == 5)
        #expect(stats.recent(7, now: day2).freezes == 7)
        #expect(stats.recent(1, now: day2).freezes == 5)

        let decoded = try JSONDecoder().decode(UsageStats.self, from: JSONEncoder().encode(stats))
        #expect(decoded == stats)
    }

    @Test("Only the last 30 days are kept")
    func statsRetention() throws {
        var stats = UsageStats()
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        for offset in 0..<40 {
            stats.recordFreezes(1, now: start.addingTimeInterval(Double(offset) * 86_400))
        }
        #expect(stats.days.count == UsageStats.keptDays)
    }

    @Test("JSON store round-trips values through disk")
    func jsonStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gmrb-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFileStore<[ActivityEvent]>(filename: "events.json", directory: dir, delay: 0)
        let events = [ActivityEvent(kind: .frozen, title: "Slack", detail: "неактивна 10м 00с")]
        store.saveNow(events)
        #expect(store.load() == events)
    }

    // MARK: Explanations

    private func app(status: TrackedAppStatus, regular: Bool = true, idle: TimeInterval = 0,
                     footprint: UInt64 = 900 << 20, reason: String? = nil, cpu: Double = 0) -> TrackedApp {
        TrackedApp(id: "app:x:1", bundleIdentifier: "x", name: "X", bundlePath: nil, mainPID: 1, pids: [1],
                   footprintBytes: footprint, cpuPercent: 0, isFrozen: { if case .frozen = status { return true }; return false }(),
                   status: status, idleSeconds: idle, isRegularApp: regular, backgroundCPUPercent: cpu, frozenReason: reason)
    }

    @Test("Explanations name the actual cause")
    func explanations() {
        let ctx = FreezeExplainer.Context(settings: EngineSettings(), pressure: .warning, powerSource: .battery,
                                          now: Date(timeIntervalSince1970: 10_000))

        let frozen = FreezeExplainer.explain(app(status: .frozen(since: Date(timeIntervalSince1970: 9_400), pidCount: 3),
                                                 reason: "неактивна 12м 00с"), context: ctx)
        #expect(frozen.contains { $0.contains("неактивна 12м 00с") })
        #expect(frozen.contains { $0.contains("10м 00с") })

        let protected = FreezeExplainer.explain(app(status: .protected(reasons: [.playingAudio, .clipboardOwner])), context: ctx)
        #expect(protected.count == 3)
        #expect(protected[1] == "• " + FreezeExplainer.sentence(for: .playingAudio))

        let counting = FreezeExplainer.explain(app(status: .countingDown(remainingSeconds: 60, totalSeconds: 150), idle: 90),
                                               context: ctx)
        // Battery and memory pressure both shorten the timeout: both are explained.
        #expect(counting.count == 3)

        let agent = FreezeExplainer.explain(app(status: .manualOnly, regular: false), context: ctx)
        #expect(agent.first?.contains("Dock") == true)

        let waiting = FreezeExplainer.explain(app(status: .waitingForPressure, idle: 1200, cpu: 2.4), context: ctx)
        #expect(waiting.contains { $0.contains("2%") })
    }

    @Test("New settings fields default sensibly for older saved settings")
    func settingsDefaults() throws {
        let old = try JSONDecoder().decode(EngineSettings.self, from: Data(#"{"idleTimeoutMinutes":15}"#.utf8))
        #expect(old.checkForUpdates)
        #expect(!old.hasCompletedOnboarding)
        #expect(old.idleTimeoutMinutes == 15)
    }
}
