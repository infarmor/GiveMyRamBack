import Foundation

public struct ReleaseInfo: Sendable, Equatable, Codable {
    public let version: String
    public let url: URL

    public init(version: String, url: URL) {
        self.version = version
        self.url = url
    }
}

public enum VersionComparator {
    /// Numeric components of a version string: "v2.10.1-beta" → [2, 10, 1].
    public static func components(_ version: String) -> [Int] {
        var v = version.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
        let core = v.split(whereSeparator: { $0 == "-" || $0 == "+" || $0 == " " }).first.map(String.init) ?? v
        return core.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate)
        let b = components(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// Asks the GitHub Releases API once a day whether a newer version exists.
/// Sends no user data: only a generic `GiveMyRamBack/<version>` User-Agent.
@MainActor
public final class UpdateChecker: ObservableObject {
    public static let repository = "infarmor/GiveMyRamBack"
    public static let releasesPage = URL(string: "https://github.com/infarmor/GiveMyRamBack/releases/latest")!
    private static let lastCheckKey = "dev.givemyramback.update.lastCheck"
    private static let dismissedKey = "dev.givemyramback.update.dismissedVersion"
    private static let checkInterval: TimeInterval = 24 * 3600

    @Published public private(set) var available: ReleaseInfo?
    @Published public private(set) var isChecking = false
    @Published public private(set) var lastCheck: Date?
    @Published public private(set) var lastError: String?

    public let currentVersion: String
    private var timer: Timer?
    private let session: URLSession

    public init(currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                session: URLSession = .shared) {
        self.currentVersion = currentVersion
        self.session = session
        self.lastCheck = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
    }

    /// Release the banner should show (not dismissed by the user).
    public var visibleUpdate: ReleaseInfo? {
        guard let available else { return nil }
        let dismissed = UserDefaults.standard.string(forKey: Self.dismissedKey)
        return available.version == dismissed ? nil : available
    }

    public func dismiss() {
        guard let available else { return }
        UserDefaults.standard.set(available.version, forKey: Self.dismissedKey)
        objectWillChange.send()
    }

    /// Periodic checks while `isEnabled()` returns true: shortly after launch, then hourly
    /// wake-ups that only hit the network if the last check is older than a day.
    public func start(isEnabled: @escaping @MainActor () -> Bool) {
        timer?.invalidate()
        let tick: @MainActor () -> Void = { [weak self] in
            guard let self, isEnabled() else { return }
            let due = self.lastCheck.map { Date().timeIntervalSince($0) >= Self.checkInterval } ?? true
            if due {
                Task { await self.checkNow() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            MainActor.assumeIsolated { tick() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        timer?.tolerance = 600
    }

    public func checkNow() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GiveMyRamBack/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let release = try Self.parseLatestRelease(data)
            lastError = nil
            lastCheck = Date()
            UserDefaults.standard.set(lastCheck, forKey: Self.lastCheckKey)
            if let release, VersionComparator.isNewer(release.version, than: currentVersion) {
                available = release
                Log.engine.notice("Update available: \(release.version, privacy: .public)")
            } else {
                available = nil
                Log.engine.info("Up to date (\(self.currentVersion, privacy: .public))")
            }
        } catch {
            lastError = String(localized: "Не удалось проверить обновления")
            Log.engine.error("Update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Parses the `releases/latest` payload; drafts and pre-releases are ignored.
    nonisolated public static func parseLatestRelease(_ data: Data) throws -> ReleaseInfo? {
        struct Payload: Decodable {
            let tag_name: String
            let html_url: URL
            let draft: Bool?
            let prerelease: Bool?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        if payload.draft == true || payload.prerelease == true { return nil }
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        return ReleaseInfo(version: version, url: payload.html_url)
    }
}
