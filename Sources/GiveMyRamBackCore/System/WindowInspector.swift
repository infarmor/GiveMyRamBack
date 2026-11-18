import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// A parsed entry of `CGWindowListCopyWindowInfo`, in front-to-back order.
public struct OnScreenWindow: Sendable, Equatable {
    public let windowID: CGWindowID
    public let ownerPID: Int32
    public let ownerName: String
    public let layer: Int
    public let alpha: Double
    /// Global display coordinates, origin at the top-left of the primary display.
    public let bounds: CGRect

    public init(windowID: CGWindowID = 0, ownerPID: Int32, ownerName: String, layer: Int, alpha: Double, bounds: CGRect) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.layer = layer
        self.alpha = alpha
        self.bounds = bounds
    }

    var isTransparent: Bool { alpha <= 0.01 }
}

public enum ClickHitResult: Equatable, Sendable {
    /// The click landed on a window of this frozen process.
    case frozenWindow(pid: Int32)
    /// The click landed on the Dock; the clicked icon has to be resolved separately.
    case dock(pid: Int32)
    /// The click is consumed by a non-frozen window (or a system overlay): nothing to wake.
    case none
}

public enum WindowInspector {
    /// System processes whose windows sit above normal windows and swallow the click
    /// (Dock, menu bar, notification banners, Control Center…). Windows *behind* them never
    /// receive that click, so they must not be woken.
    public static let shellBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.systemuiserver",
        "com.apple.Spotlight",
        "com.apple.WindowManager",
        "com.apple.screencaptureui"
    ]
    public static let shellOwnerNames: Set<String> = ["Window Server", "WindowServer"]

    public static func readOnScreenWindows() -> [OnScreenWindow] {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return infoList.compactMap { info in
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else {
                return nil
            }
            return OnScreenWindow(
                windowID: (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0,
                ownerPID: pid,
                ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
                layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                bounds: bounds
            )
        }
    }

    /// Decides which process actually received a click at `point`.
    /// - `isFrozen`: whether a PID belongs to a frozen record.
    /// - `shellKind`: classifies system shell owners; returns `.dock` for the Dock, `.other` for
    ///   other shells (menu bar, banners), `nil` for ordinary processes.
    public static func hitTest(
        point: CGPoint,
        windows: [OnScreenWindow],
        selfPID: Int32,
        isFrozen: (Int32) -> Bool,
        shellKind: (OnScreenWindow) -> ShellKind?
    ) -> ClickHitResult {
        for window in windows {
            guard !window.isTransparent, window.bounds.contains(point) else { continue }
            if window.ownerPID == selfPID {
                // Our own normal-level windows are the click-through «На паузе» overlays sitting
                // on top of frozen windows: look through them. Any other window of ours
                // (popover, detached panel, alerts) really receives the click.
                if window.layer == 0 { continue }
                return .none
            }
            if isFrozen(window.ownerPID) {
                return .frozenWindow(pid: window.ownerPID)
            }
            switch shellKind(window) {
            case .dock:
                return .dock(pid: window.ownerPID)
            case .other:
                return .none
            case nil:
                break
            }
            // A normal layer-0 window owns the click. Non-zero layers of third-party apps can be
            // click-through overlays (floating HUDs, shadows), so keep looking underneath them.
            if window.layer == 0 {
                return .none
            }
        }
        return .none
    }

    public enum ShellKind: Sendable {
        case dock
        case other
    }

    /// PIDs owning a normal (layer 0) window of meaningful size with at least
    /// `minVisibleFraction` of its area not covered by windows in front of it.
    public static func visibleWindowPIDs(
        windows: [OnScreenWindow],
        selfPID: Int32,
        minSize: CGSize = CGSize(width: 160, height: 120),
        minVisibleFraction: Double = 0.35,
        gridSteps: Int = 6
    ) -> Set<Int32> {
        var result = Set<Int32>()
        var occluders: [CGRect] = []
        occluders.reserveCapacity(windows.count)

        for window in windows where !window.isTransparent {
            defer { occluders.append(window.bounds) }
            guard window.layer == 0,
                  window.ownerPID != selfPID,
                  !result.contains(window.ownerPID),
                  window.bounds.width >= minSize.width,
                  window.bounds.height >= minSize.height else {
                continue
            }

            var visiblePoints = 0
            let total = gridSteps * gridSteps
            for ix in 0..<gridSteps {
                for iy in 0..<gridSteps {
                    let p = CGPoint(
                        x: window.bounds.minX + window.bounds.width * (Double(ix) + 0.5) / Double(gridSteps),
                        y: window.bounds.minY + window.bounds.height * (Double(iy) + 0.5) / Double(gridSteps)
                    )
                    if !occluders.contains(where: { $0.contains(p) }) {
                        visiblePoints += 1
                    }
                }
            }
            if Double(visiblePoints) / Double(total) >= minVisibleFraction {
                result.insert(window.ownerPID)
            }
        }
        return result
    }

    // MARK: - Dock icon resolution (Accessibility)

    public static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt that sends the user to Privacy & Security → Accessibility.
    @discardableResult
    public static func requestAccessibilityTrust() -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Returns the bundle path of the app icon under `point` in the Dock, if any.
    /// Only the Dock process is queried (never a frozen app — an AX call to a stopped process
    /// would block until the messaging timeout).
    public static func dockItemBundlePath(dockPID: Int32, point: CGPoint) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let dock = AXUIElementCreateApplication(dockPID)
        AXUIElementSetMessagingTimeout(dock, 0.25)

        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(dock, Float(point.x), Float(point.y), &element) == .success,
              let element else {
            return nil
        }

        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard (subrole as? String) == "AXApplicationDockItem" else { return nil }

        var urlValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &urlValue) == .success,
              let urlValue,
              CFGetTypeID(urlValue) == CFURLGetTypeID() else {
            return nil
        }
        let url = (urlValue as! CFURL) as URL
        return url.standardizedFileURL.path
    }
}
