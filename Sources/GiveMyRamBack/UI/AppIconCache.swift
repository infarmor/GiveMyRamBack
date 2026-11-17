import AppKit

@MainActor
final class AppIconCache {
    static let shared = AppIconCache()

    private var cache: [String: NSImage] = [:]
    private let fallbackIcon: NSImage

    private init() {
        fallbackIcon = NSImage(
            systemSymbolName: "app.fill",
            accessibilityDescription: nil
        ) ?? NSWorkspace.shared.icon(forFile: "/Applications")
    }

    func icon(for appBundlePath: String?, name: String) -> NSImage {
        let key = appBundlePath ?? "name:\(name)"
        if let cached = cache[key] {
            return cached
        }
        let image: NSImage
        if let appBundlePath, !appBundlePath.isEmpty {
            image = NSWorkspace.shared.icon(forFile: appBundlePath)
        } else {
            image = fallbackIcon
        }
        image.size = NSSize(width: 32, height: 32)
        cache[key] = image
        return image
    }
}
