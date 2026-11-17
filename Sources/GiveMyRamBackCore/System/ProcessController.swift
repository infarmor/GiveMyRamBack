import Darwin
import Foundation

public protocol ProcessSignaling: Sendable {
    func sendStop(to identity: ProcessIdentity) -> Bool
    func sendContinue(to identity: ProcessIdentity) -> Bool
    func isCurrentlyStopped(identity: ProcessIdentity) -> Bool
}

public struct LiveProcessSignaler: ProcessSignaling {
    public init() {}

    public func sendStop(to identity: ProcessIdentity) -> Bool {
        guard matchesRunningProcess(identity) else { return false }
        return Darwin.kill(identity.pid, SIGSTOP) == 0
    }

    public func sendContinue(to identity: ProcessIdentity) -> Bool {
        guard matchesRunningProcess(identity) else { return false }
        return Darwin.kill(identity.pid, SIGCONT) == 0
    }

    public func isCurrentlyStopped(identity: ProcessIdentity) -> Bool {
        guard let bsd = ProcessScanner.readBSDInfo(pid: identity.pid) else { return false }
        guard bsd.pbi_start_tvsec == identity.startTimeSec,
              bsd.pbi_start_tvusec == identity.startTimeUsec else {
            return false
        }
        return bsd.pbi_status == UInt32(SSTOP)
    }

    private func matchesRunningProcess(_ identity: ProcessIdentity) -> Bool {
        guard identity.pid > 1, identity.pid != getpid() else { return false }
        guard let bsd = ProcessScanner.readBSDInfo(pid: identity.pid) else { return false }
        return bsd.pbi_start_tvsec == identity.startTimeSec &&
               bsd.pbi_start_tvusec == identity.startTimeUsec
    }
}

public final class ProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private let signaler: ProcessSignaling
    private let stateFileURL: URL
    private let legacyStateFileURL: URL?
    private var recordsByKey: [String: FrozenRecord] = [:]
    private var keyByPID: [Int32: String] = [:]

    public init(
        signaler: ProcessSignaling = LiveProcessSignaler(),
        stateFileURL: URL? = nil
    ) {
        self.signaler = signaler
        if let stateFileURL {
            self.stateFileURL = stateFileURL
            self.legacyStateFileURL = nil
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.stateFileURL = appSupport
                .appendingPathComponent("GiveMyRamBack", isDirectory: true)
                .appendingPathComponent("frozen_state.json")
            self.legacyStateFileURL = appSupport
                .appendingPathComponent("CryoRAM", isDirectory: true)
                .appendingPathComponent("frozen_state.json")
        }
    }

    public func frozenRecord(forKey key: String) -> FrozenRecord? {
        lock.lock()
        defer { lock.unlock() }
        return recordsByKey[key]
    }

    public func frozenKey(forPID pid: Int32) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return keyByPID[pid]
    }

    public func allFrozenRecords() -> [FrozenRecord] {
        lock.lock()
        defer { lock.unlock() }
        return Array(recordsByKey.values)
    }

    public func frozenCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return recordsByKey.count
    }

    @discardableResult
    public func recoverFromPreviousRun() -> [String] {
        var urlsToCheck: [URL] = [stateFileURL]
        if let legacyStateFileURL {
            urlsToCheck.append(legacyStateFileURL)
        }

        var recoveredNames: [String] = []
        for url in urlsToCheck {
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let staleRecords = try? JSONDecoder().decode([FrozenRecord].self, from: data) else {
                continue
            }

            for record in staleRecords {
                var resumedAny = false
                // Resume main PID first, helpers after (identities are stored helpers-first, main-last)
                for identity in record.identities.reversed() {
                    if signaler.isCurrentlyStopped(identity: identity) {
                        if signaler.sendContinue(to: identity) {
                            resumedAny = true
                        }
                    }
                }
                if resumedAny {
                    recoveredNames.append(record.appName)
                }
            }

            try? FileManager.default.removeItem(at: url)
        }

        persistLockedRecords([])
        return recoveredNames
    }

    @discardableResult
    public func freeze(
        appKey: String,
        appName: String,
        mainPID: Int32,
        identities: [ProcessIdentity],
        footprintBytes: UInt64,
        residentBytes: UInt64 = 0,
        now: Date = Date()
    ) -> FrozenRecord? {
        guard !identities.isEmpty else { return nil }

        // Ensure helpers/children freeze before mainPID
        let ordered = orderMainLast(identities, mainPID: mainPID)
        var frozenIdentities: [ProcessIdentity] = []
        frozenIdentities.reserveCapacity(ordered.count)

        for identity in ordered {
            if signaler.sendStop(to: identity) {
                frozenIdentities.append(identity)
            }
        }

        guard !frozenIdentities.isEmpty else { return nil }

        let record = FrozenRecord(
            appKey: appKey,
            appName: appName,
            mainPID: mainPID,
            identities: frozenIdentities,
            frozenAt: now,
            footprintAtFreezeBytes: footprintBytes,
            residentAtFreezeBytes: residentBytes
        )

        lock.lock()
        recordsByKey[appKey] = record
        for identity in frozenIdentities {
            keyByPID[identity.pid] = appKey
        }
        let snapshot = Array(recordsByKey.values)
        lock.unlock()

        persistLockedRecords(snapshot)
        return record
    }

    @discardableResult
    public func resume(appKey: String) -> FrozenRecord? {
        lock.lock()
        guard let record = recordsByKey.removeValue(forKey: appKey) else {
            lock.unlock()
            return nil
        }
        for identity in record.identities {
            if keyByPID[identity.pid] == appKey {
                keyByPID.removeValue(forKey: identity.pid)
            }
        }
        let snapshot = Array(recordsByKey.values)
        lock.unlock()

        // Resume mainPID first, then helpers
        for identity in record.identities.reversed() {
            _ = signaler.sendContinue(to: identity)
        }

        persistLockedRecords(snapshot)
        return record
    }

    @discardableResult
    public func resumeAll() -> [FrozenRecord] {
        lock.lock()
        let allRecords = Array(recordsByKey.values)
        recordsByKey.removeAll()
        keyByPID.removeAll()
        lock.unlock()

        for record in allRecords {
            for identity in record.identities.reversed() {
                _ = signaler.sendContinue(to: identity)
            }
        }

        persistLockedRecords([])
        return allRecords
    }

    public func pruneExitedRecord(appKey: String) {
        lock.lock()
        guard let record = recordsByKey.removeValue(forKey: appKey) else {
            lock.unlock()
            return
        }
        for identity in record.identities {
            if keyByPID[identity.pid] == appKey {
                keyByPID.removeValue(forKey: identity.pid)
            }
        }
        let snapshot = Array(recordsByKey.values)
        lock.unlock()
        persistLockedRecords(snapshot)
    }

    private func orderMainLast(_ identities: [ProcessIdentity], mainPID: Int32) -> [ProcessIdentity] {
        let others = identities.filter { $0.pid != mainPID }
        let main = identities.filter { $0.pid == mainPID }
        return others + main
    }

    private func persistLockedRecords(_ records: [FrozenRecord]) {
        let dir = stateFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if records.isEmpty {
            try? FileManager.default.removeItem(at: stateFileURL)
            return
        }
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: stateFileURL, options: .atomic)
        }
    }
}
