import AppKit
import Combine
import Darwin
import GiveMyRamBackCore
import SwiftUI

@main
@MainActor
final class GiveMyRamBackMain {
    static func main() {
        // `--watchdog <pid>` mode: no UI, just wait for the app to exit and unfreeze leftovers.
        CrashGuard.runWatchdogIfRequested()

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
            // O_CLOEXEC: the watchdog child must not inherit (and keep holding) the lock.
            O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC,
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
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
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
    private var watchdogProcess: Process?
    private var overlayController: FrozenOverlayController?
    private let hotKey = GlobalHotKey()
    private var occlusionObserver: NSObjectProtocol?

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

        CrashGuard.installCrashHandlers()
        watchdogProcess = CrashGuard.spawnWatchdog()

        setupStatusItem()
        setupPopover()
        bindStatusBarUpdates()
        installSignalHandlers()
        installOpenUIObserver()

        engine.start()

        overlayController = FrozenOverlayController(engine: engine)
        bindHotKey()
    }

    private func bindHotKey() {
        engine.$settings
            .map(\.unfreezeHotkeyEnabled)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.hotKey.register { [weak self] in
                        MainActor.assumeIsolated {
                            self?.engine.resumeAll(reason: "горячая клавиша \(GlobalHotKey.displayString)")
                        }
                    }
                } else {
                    self.hotKey.unregister()
                }
            }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
            self.distributedObserver = nil
        }
        guard ownsInstanceLock else { return }
        overlayController?.removeAll()
        engine.stopAndResumeAll(reason: "завершение работы")
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) == detachedWindow {
            detachedWindow = nil
            if let occlusionObserver {
                NotificationCenter.default.removeObserver(occlusionObserver)
                self.occlusionObserver = nil
            }
            updateUIVisibility()
        }
    }

    func popoverDidShow(_ notification: Notification) {
        updateUIVisibility()
    }

    func popoverDidClose(_ notification: Notification) {
        updateUIVisibility()
    }

    /// Fast sampling and SwiftUI updates only while some UI is actually on screen.
    private func updateUIVisibility() {
        let popoverShown = popover?.isShown ?? false
        let windowShown = detachedWindow.map {
            $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        } ?? false
        engine.setUIVisible(popoverShown || windowShown)
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
        pop.delegate = self
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
            engine.$settings.map(\.menuBarDisplayMode)
        )
        .map { frozenCount, frozenFootprint, reclaimedDRAM, mode in
            Self.statusItemTitle(
                frozenCount: frozenCount,
                frozenFootprintBytes: frozenFootprint,
                reclaimedDRAMBytes: reclaimedDRAM,
                mode: mode
            )
        }
        // Only touch the status item when what it shows actually changes.
        .removeDuplicates { $0 == $1 }
        .receive(on: RunLoop.main)
        .sink { [weak self] appearance in
            self?.applyStatusItemAppearance(symbolName: appearance.symbol, title: appearance.title)
        }
        .store(in: &cancellables)
    }

    private nonisolated static func statusItemTitle(
        frozenCount: Int,
        frozenFootprintBytes: UInt64,
        reclaimedDRAMBytes: UInt64,
        mode: MenuBarDisplayMode
    ) -> (symbol: String, title: String) {
        let symbol = frozenCount > 0 ? "snowflake.circle.fill" : "memorychip"
        switch mode {
        case .iconOnly:
            return (symbol, "")
        case .frozenCount:
            return (symbol, frozenCount > 0 ? " \(frozenCount)" : "")
        case .frozenAndRAM:
            guard frozenCount > 0 else { return (symbol, "") }
            let ramBytes = reclaimedDRAMBytes >= 20 * 1_048_576 ? reclaimedDRAMBytes : frozenFootprintBytes
            return (symbol, " \(frozenCount) · \(ByteFormatter.formatCompact(ramBytes))")
        }
    }

    private func applyStatusItemAppearance(symbolName: String, title: String) {
        guard let button = statusItem?.button else { return }
        let config = NSImage.SymbolConfiguration(hierarchicalColor: .labelColor)
        if let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Give my ram back") {
            let configured = baseImage.withSymbolConfiguration(config) ?? baseImage
            configured.isTemplate = true
            button.image = configured
        }
        button.title = title
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
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateUIVisibility()
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        updateUIVisibility()
    }

    private func showContextMenu(anchor: NSStatusBarButton) {
        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Открыть Give my ram back", action: #selector(openFromMenu), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let freezeBgItem = NSMenuItem(title: "Вернуть RAM сейчас", action: #selector(freezeAllFromMenu), keyEquivalent: "")
        freezeBgItem.target = self
        freezeBgItem.isEnabled = engine.hasBatchCandidates
        menu.addItem(freezeBgItem)

        let resumeAllItem = NSMenuItem(title: "Разморозить всё", action: #selector(resumeAllFromMenu), keyEquivalent: "")
        resumeAllItem.target = self
        if hotKey.isRegistered {
            // Display hint for the global shortcut.
            resumeAllItem.keyEquivalent = "u"
            resumeAllItem.keyEquivalentModifierMask = [.control, .option, .command]
        }
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
