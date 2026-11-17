import AppKit
import Combine
import Darwin
import GiveMyRamBackCore
import SwiftUI

@main
@MainActor
final class GiveMyRamBackMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

private final class SingleInstanceLock {
    private var fd: Int32 = -1

    func acquire() -> Bool {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("GiveMyRamBack", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let lockURL = dir.appendingPathComponent("app.lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK,
            0o644
        )
        if descriptor >= 0 {
            self.fd = descriptor
            return true
        }
        if errno == EWOULDBLOCK || errno == EAGAIN {
            return false
        }
        return true
    }

    deinit {
        if fd >= 0 {
            Darwin.close(fd)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let openUINotificationName = Notification.Name("dev.givemyramback.openUI")

    private let instanceLock = SingleInstanceLock()
    private var ownsInstanceLock = false

    private let engine = FreezeEngine()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var detachedWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    private var signalSources: [DispatchSourceSignal] = []
    private var distributedObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if !instanceLock.acquire() {
            DistributedNotificationCenter.default().postNotificationName(
                Self.openUINotificationName,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            NSApp.terminate(nil)
            return
        }

        ownsInstanceLock = true

        setupStatusItem()
        setupPopover()
        bindStatusBarUpdates()
        installSignalHandlers()
        installOpenUIObserver()

        engine.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
            self.distributedObserver = nil
        }
        guard ownsInstanceLock else { return }
        engine.stopAndResumeAll(reason: "завершение работы")
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) == detachedWindow {
            detachedWindow = nil
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let img = NSImage(systemSymbolName: "memorychip", accessibilityDescription: "Give my ram back") {
                img.isTemplate = true
                button.image = img
            }
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    private func setupPopover() {
        let rootView = makeRootView(isDetached: false)
        let hostingController = NSHostingController(rootView: rootView)
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.contentSize = NSSize(width: 460, height: 620)
        pop.contentViewController = hostingController
        popover = pop
    }

    private func makeRootView(isDetached: Bool) -> PopoverRootView {
        PopoverRootView(
            engine: engine,
            isDetached: isDetached,
            onToggleDetach: { [weak self] in
                self?.toggleDetachedWindow()
            },
            onQuit: { [weak self] in
                self?.quitSafely()
            }
        )
    }

    private func bindStatusBarUpdates() {
        Publishers.CombineLatest4(
            engine.$frozenCount,
            engine.$totalFrozenFootprintBytes,
            engine.$totalReclaimedDRAMBytes,
            Publishers.CombineLatest(engine.$memoryStats, engine.$settings)
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] frozenCount, frozenFootprint, reclaimedDRAM, statsAndSettings in
            let (stats, settings) = statsAndSettings
            self?.updateStatusItemAppearance(
                frozenCount: frozenCount,
                frozenFootprintBytes: frozenFootprint,
                reclaimedDRAMBytes: reclaimedDRAM,
                pressure: stats.pressure,
                mode: settings.menuBarDisplayMode
            )
        }
        .store(in: &cancellables)
    }

    private func updateStatusItemAppearance(
        frozenCount: Int,
        frozenFootprintBytes: UInt64,
        reclaimedDRAMBytes: UInt64,
        pressure: MemoryPressureLevel,
        mode: MenuBarDisplayMode
    ) {
        guard let button = statusItem?.button else { return }

        let symbolName = frozenCount > 0 ? "snowflake.circle.fill" : "memorychip"
        let config = NSImage.SymbolConfiguration(hierarchicalColor: .labelColor)

        if let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Give my ram back") {
            let configured = baseImage.withSymbolConfiguration(config) ?? baseImage
            configured.isTemplate = true
            button.image = configured
        }

        switch mode {
        case .iconOnly:
            button.title = ""
        case .frozenCount:
            button.title = frozenCount > 0 ? " \(frozenCount)" : ""
        case .frozenAndRAM:
            if frozenCount > 0 {
                let ramBytes = reclaimedDRAMBytes >= 20 * 1_048_576 ? reclaimedDRAMBytes : frozenFootprintBytes
                button.title = " \(frozenCount) · \(ByteFormatter.formatCompact(ramBytes))"
            } else {
                button.title = ""
            }
        }
    }

    private func installOpenUIObserver() {
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.openUINotificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let detachedWindow = self.detachedWindow {
                    NSApp.activate(ignoringOtherApps: true)
                    detachedWindow.makeKeyAndOrderFront(nil)
                } else if let button = self.statusItem?.button, let popover = self.popover, !popover.isShown {
                    self.togglePopover(button)
                }
            }
        }
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            openUI(anchor: sender)
            return
        }

        if event.type == .rightMouseUp {
            popover?.performClose(nil)
            showContextMenu(anchor: sender)
        } else {
            openUI(anchor: sender)
        }
    }

    private func openUI(anchor: NSStatusBarButton) {
        if let detachedWindow {
            NSApp.activate(ignoringOtherApps: true)
            detachedWindow.makeKeyAndOrderFront(nil)
            return
        }
        togglePopover(anchor)
    }

    private func togglePopover(_ anchor: NSStatusBarButton) {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func toggleDetachedWindow() {
        if let window = detachedWindow {
            window.close()
            detachedWindow = nil
            if let button = statusItem?.button {
                togglePopover(button)
            }
            return
        }

        popover?.performClose(nil)

        let hosting = NSHostingController(
            rootView: makeRootView(isDetached: true)
                .background(.ultraThinMaterial)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "Give my ram back"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 470, height: 630))
        window.minSize = NSSize(width: 440, height: 560)
        window.center()
        window.delegate = self

        detachedWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func showContextMenu(anchor: NSStatusBarButton) {
        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Открыть Give my ram back", action: #selector(openFromMenu), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let freezeBgItem = NSMenuItem(title: "Вернуть RAM сейчас", action: #selector(freezeAllFromMenu), keyEquivalent: "")
        freezeBgItem.target = self
        freezeBgItem.isEnabled = engine.apps.contains { $0.isEligibleForBatchFreezeNow }
        menu.addItem(freezeBgItem)

        let resumeAllItem = NSMenuItem(title: "Разморозить всё", action: #selector(resumeAllFromMenu), keyEquivalent: "")
        resumeAllItem.target = self
        resumeAllItem.isEnabled = engine.frozenCount > 0
        menu.addItem(resumeAllItem)

        menu.addItem(.separator())

        let detachTitle = detachedWindow != nil ? "Вернуть в строку меню" : "Закрепить отдельным окном"
        let detachItem = NSMenuItem(title: detachTitle, action: #selector(toggleDetachFromMenu), keyEquivalent: "")
        detachItem.target = self
        menu.addItem(detachItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Разморозить всё и выйти", action: #selector(quitFromMenu), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    @objc private func openFromMenu() {
        guard let button = statusItem?.button else { return }
        openUI(anchor: button)
    }

    @objc private func freezeAllFromMenu() {
        engine.freezeAllEligibleBackground()
    }

    @objc private func resumeAllFromMenu() {
        engine.resumeAll(reason: "контекстное меню")
    }

    @objc private func toggleDetachFromMenu() {
        toggleDetachedWindow()
    }

    @objc private func quitFromMenu() {
        quitSafely()
    }

    private func quitSafely() {
        engine.stopAndResumeAll(reason: "выход из приложения")
        NSApp.terminate(nil)
    }

    private func installSignalHandlers() {
        let signals: [Int32] = [SIGTERM, SIGINT, SIGHUP]
        for sig in signals {
            Darwin.signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.engine.prepareForTermination()
                    NSApp.terminate(nil)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
