import AppKit
import Combine
import GiveMyRamBackCore
import SwiftUI

/// Dims every on-screen window of a frozen app and labels it «На паузе», so a paused window is
/// not mistaken for a hung one. Overlays ignore the mouse: the click goes to the frozen window
/// underneath, where the engine's click monitor wakes the app.
@MainActor
final class FrozenOverlayController {
    private let engine: FreezeEngine
    private var panels: [CGWindowID: NSPanel] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var spaceObserver: NSObjectProtocol?

    private static let minWindowSize = CGSize(width: 140, height: 90)

    init(engine: FreezeEngine) {
        self.engine = engine

        engine.stateDidChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)

        engine.$settings
            .map(\.showFrozenOverlay)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func removeAll() {
        for panel in panels.values {
            panel.orderOut(nil)
        }
        panels.removeAll()
    }

    func refresh() {
        guard engine.settings.showFrozenOverlay else {
            removeAll()
            return
        }
        let frozenPIDs = Set(engine.processController.allFrozenRecords().flatMap { $0.identities.map(\.pid) })
        guard !frozenPIDs.isEmpty,
              let primaryHeight = NSScreen.screens.first?.frame.height else {
            removeAll()
            return
        }

        var keep = Set<CGWindowID>()
        for window in WindowInspector.readOnScreenWindows() {
            guard window.layer == 0,
                  window.windowID != 0,
                  window.alpha > 0.01,
                  frozenPIDs.contains(window.ownerPID),
                  window.bounds.width >= Self.minWindowSize.width,
                  window.bounds.height >= Self.minWindowSize.height else {
                continue
            }
            keep.insert(window.windowID)

            // CG coordinates are top-left based; Cocoa's are bottom-left of the primary display.
            let frame = NSRect(
                x: window.bounds.minX,
                y: primaryHeight - window.bounds.maxY,
                width: window.bounds.width,
                height: window.bounds.height
            )
            let panel = panels[window.windowID] ?? makePanel()
            panels[window.windowID] = panel
            if panel.frame != frame {
                panel.setFrame(frame, display: true)
            }
            // Sit directly above the frozen window, not above everything: windows that cover the
            // frozen one keep covering the overlay too.
            panel.order(.above, relativeTo: Int(window.windowID))
        }

        for (id, panel) in panels where !keep.contains(id) {
            panel.orderOut(nil)
            panels.removeValue(forKey: id)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .normal
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.ignoresCycle, .transient]
        panel.contentView = NSHostingView(rootView: FrozenOverlayView())
        return panel
    }
}

private struct FrozenOverlayView: View {
    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.22))

            HStack(spacing: 6) {
                Image(systemName: "snowflake")
                    .font(.system(size: 11, weight: .semibold))
                Text("На паузе · кликните, чтобы разбудить")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
            .padding(.top, 38)
        }
        .allowsHitTesting(false)
    }
}
