import Foundation

/// One calendar day of activity.
public struct DayStats: Codable, Sendable, Equatable, Identifiable {
    /// Local calendar day, `yyyy-MM-dd`.
    public let day: String
    public var freezes: Int = 0
    /// Integral of reclaimed RAM over awake time (byte·seconds).
    public var reclaimedByteSeconds: Double = 0
    /// Awake time during which at least one app was paused.
    public var pausedSeconds: Double = 0
    public var peakReclaimedBytes: UInt64 = 0

    public var id: String { day }

    public init(day: String) {
        self.day = day
    }

    /// Average RAM given back while something was paused.
    public var averageReclaimedBytes: UInt64 {
        guard pausedSeconds > 0 else { return 0 }
        return UInt64(reclaimedByteSeconds / pausedSeconds)
    }
}

/// Rolling per-day statistics (last 30 days), persisted as JSON.
public struct UsageStats: Codable, Sendable, Equatable {
    public static let keptDays = 30
    public private(set) var days: [DayStats] = []

    public init() {}

    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public func today(now: Date = Date()) -> DayStats {
        let key = Self.dayKey(for: now)
        return days.last(where: { $0.day == key }) ?? DayStats(day: key)
    }

    /// Totals for the last `count` days including today.
    public func recent(_ count: Int, now: Date = Date()) -> (freezes: Int, pausedSeconds: Double, peakBytes: UInt64) {
        let calendar = Calendar.current
        let keys: Set<String> = Set((0..<count).compactMap {
            calendar.date(byAdding: .day, value: -$0, to: now).map { Self.dayKey(for: $0) }
        })
        let selected = days.filter { keys.contains($0.day) }
        return (
            selected.reduce(0) { $0 + $1.freezes },
            selected.reduce(0) { $0 + $1.pausedSeconds },
            selected.map(\.peakReclaimedBytes).max() ?? 0
        )
    }

    public mutating func recordFreezes(_ count: Int, now: Date = Date()) {
        guard count > 0 else { return }
        mutateToday(now) { $0.freezes += count }
    }

    /// Called every sampling tick with the awake time since the previous one.
    public mutating func accumulate(now: Date, awakeDelta: TimeInterval, reclaimedBytes: UInt64, frozenCount: Int) {
        guard awakeDelta > 0 else { return }
        mutateToday(now) { day in
            if frozenCount > 0 {
                day.pausedSeconds += awakeDelta
                day.reclaimedByteSeconds += Double(reclaimedBytes) * awakeDelta
            }
            day.peakReclaimedBytes = max(day.peakReclaimedBytes, reclaimedBytes)
        }
    }

    private mutating func mutateToday(_ now: Date, _ body: (inout DayStats) -> Void) {
        let key = Self.dayKey(for: now)
        if let idx = days.lastIndex(where: { $0.day == key }) {
            body(&days[idx])
        } else {
            var day = DayStats(day: key)
            body(&day)
            days.append(day)
            if days.count > Self.keptDays {
                days.removeFirst(days.count - Self.keptDays)
            }
        }
    }
}

/// Small JSON persistence helper; writes happen off the main thread and are coalesced.
public final class JSONFileStore<Value: Codable & Sendable>: @unchecked Sendable {
    public let url: URL
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: Value?
    private var isScheduled = false
    private let delay: TimeInterval

    public init(filename: String, directory: URL? = nil, delay: TimeInterval = 1.5) {
        let dir = directory ?? Self.defaultDirectory()
        self.url = dir.appendingPathComponent(filename)
        self.queue = DispatchQueue(label: "dev.givemyramback.store.\(filename)", qos: .utility)
        self.delay = delay
    }

    public static func defaultDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("GiveMyRamBack", isDirectory: true)
    }

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            Log.engine.error("Could not read \(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Schedules a write; several calls within `delay` collapse into one.
    public func save(_ value: Value) {
        lock.lock()
        pending = value
        let shouldSchedule = !isScheduled
        isScheduled = true
        lock.unlock()
        guard shouldSchedule else { return }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.flushPending() }
    }

    /// Writes synchronously (used on quit).
    public func saveNow(_ value: Value) {
        lock.lock()
        pending = nil
        isScheduled = false
        lock.unlock()
        queue.sync { write(value) }
    }

    private func flushPending() {
        lock.lock()
        let value = pending
        pending = nil
        isScheduled = false
        lock.unlock()
        if let value { write(value) }
    }

    private func write(_ value: Value) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch {
            Log.engine.error("Could not write \(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
