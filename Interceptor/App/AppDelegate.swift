import AppKit
import Foundation

/// AppKit delegate managing:
/// - Multi-window Dock visibility lifecycle: closes to Menu Bar (`.accessory`) only when both
///   the Main and Events windows are closed, and restores Dock presence (`.regular`) when reopened.
/// - Deterministic Core Audio teardown on app termination.
/// - Clean top macOS menu bar by pruning unused `Edit`, `Format`, and `View` top-level menus.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: AppViewModel?

    /// Closure registered by SwiftUI (`openWindow(id: "main")`) to reopen the primary window.
    var openMainWindowAction: (() -> Void)?

    /// Closure registered by SwiftUI (`openWindow(id: "events")`) to reopen the diagnostic Events window.
    var openEventsWindowAction: (() -> Void)?

    var activeEventsWindow: NSWindow? {
        eventsWindow
    }

    private weak var mainWindow: NSWindow?
    private var mainWindowObservers: [NSObjectProtocol] = []
    private weak var eventsWindow: NSWindow?
    private var eventsWindowObservers: [NSObjectProtocol] = []
    private var mainMenuObserver: NSObjectProtocol?
    private var pendingAccessoryTransition = false

    private static let prunedMenuTitles: Set<String> = ["Edit", "Format", "View"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        pruneUnusedTopLevelMenus()
        installMainMenuObserver()
        DispatchQueue.main.async { [weak self] in
            self?.pruneUnusedTopLevelMenus()
            self?.installMainMenuObserver()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        pruneUnusedTopLevelMenus()
        viewModel?.refreshLaunchAtLoginStatus()
        syncMainWindowVisibility()
        syncEventsWindowVisibility()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing all windows keeps Interceptor alive in the Menu Bar so active audio bridges stay uninterrupted.
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reopening Interceptor from /Applications, Spotlight, or a pinned Dock icon restores the main window
        // when no visible window is already on screen.
        if !flag {
            showMainWindow(openSettings: false)
            return false
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeObservers(&mainWindowObservers)
        removeObservers(&eventsWindowObservers)
        if let observer = mainMenuObserver {
            NotificationCenter.default.removeObserver(observer)
            mainMenuObserver = nil
        }
        viewModel?.shutdown()
    }

    // MARK: - Window & Dock Visibility

    /// Registers the primary SwiftUI window so we observe ONLY its lifecycle events
    /// (close, miniaturize, occlusion) and completely suspend UI meter polling when hidden.
    func registerMainWindow(_ window: NSWindow) {
        pendingAccessoryTransition = false
        if mainWindow !== window {
            removeObservers(&mainWindowObservers)
            mainWindow = window

            let nc = NotificationCenter.default
            mainWindowObservers = [
                nc.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.handleMainWindowWillClose()
                    }
                },
                nc.addObserver(forName: NSWindow.willMiniaturizeNotification, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.viewModel?.setMainWindowVisible(false)
                    }
                },
                nc.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.syncMainWindowVisibility()
                    }
                },
                nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.syncMainWindowVisibility()
                    }
                }
            ]
        }

        ensureRegularActivationPolicy()
        syncMainWindowVisibility()
    }

    /// Registers the dedicated diagnostic Events window so we observe its lifecycle events
    /// and sync `eventLog.isEventsWindowVisible` plus multi-window Dock visibility.
    func registerEventsWindow(_ window: NSWindow) {
        pendingAccessoryTransition = false
        if eventsWindow !== window {
            removeObservers(&eventsWindowObservers)
            eventsWindow = window

            let nc = NotificationCenter.default
            eventsWindowObservers = [
                nc.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.handleEventsWindowWillClose()
                    }
                },
                nc.addObserver(forName: NSWindow.willMiniaturizeNotification, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.viewModel?.engine.eventLog.isEventsWindowVisible = false
                    }
                },
                nc.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.syncEventsWindowVisibility()
                    }
                },
                nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.syncEventsWindowVisibility()
                    }
                },
                nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.syncEventsWindowVisibility()
                    }
                }
            ]
        }

        ensureRegularActivationPolicy()
        syncEventsWindowVisibility()
    }

    /// Restores Dock presence, opens or focuses the main window, and optionally presents the Settings sheet.
    func showMainWindow(openSettings: Bool = false) {
        pendingAccessoryTransition = false
        ensureRegularActivationPolicy()

        if let openMainWindowAction {
            openMainWindowAction()
        }

        if let window = mainWindow {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }

        NSApp.activate()
        pruneUnusedTopLevelMenus()
        viewModel?.setMainWindowVisible(true)

        if openSettings {
            viewModel?.isSettingsPresented = true
        }

        // Follow up on the next runloop turn after `.accessory -> .regular` transition to ensure key focus.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pruneUnusedTopLevelMenus()
            if let window = self.mainWindow {
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate()
            self.syncMainWindowVisibility()
            if openSettings {
                self.viewModel?.isSettingsPresented = true
            }
        }
    }

    /// Restores Dock presence if needed and opens or focuses the dedicated Events diagnostic window (`⌘E`).
    func showEventsWindow() {
        pendingAccessoryTransition = false
        ensureRegularActivationPolicy()

        if let openEventsWindowAction {
            openEventsWindowAction()
        }

        if let window = eventsWindow {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }

        NSApp.activate()
        pruneUnusedTopLevelMenus()
        viewModel?.engine.eventLog.isEventsWindowVisible = true

        // Follow up on the next runloop turn after `.accessory -> .regular` or first-open to ensure key focus.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pruneUnusedTopLevelMenus()
            if let window = self.eventsWindow {
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate()
            self.syncEventsWindowVisibility()
        }
    }

    private func ensureRegularActivationPolicy() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            pruneUnusedTopLevelMenus()
        }
    }

    private func syncMainWindowVisibility() {
        guard let window = mainWindow else {
            viewModel?.setMainWindowVisible(false)
            return
        }
        let visibleOnScreen = window.isVisible &&
            !window.isMiniaturized &&
            window.occlusionState.contains(.visible)
        viewModel?.setMainWindowVisible(visibleOnScreen)
    }

    private func syncEventsWindowVisibility() {
        guard let window = eventsWindow else {
            viewModel?.engine.eventLog.isEventsWindowVisible = false
            return
        }
        let visibleOnScreen = window.isVisible &&
            !window.isMiniaturized &&
            (window.occlusionState.contains(.visible) || window.isKeyWindow)
        viewModel?.engine.eventLog.isEventsWindowVisible = visibleOnScreen
    }

    private func handleMainWindowWillClose() {
        viewModel?.setMainWindowVisible(false)
        viewModel?.isSettingsPresented = false
        viewModel?.isBridgeInfoPresented = false
        scheduleAccessoryPolicyTransitionIfNoWindowsVisible()
    }

    private func handleEventsWindowWillClose() {
        viewModel?.engine.eventLog.isEventsWindowVisible = false
        scheduleAccessoryPolicyTransitionIfNoWindowsVisible()
    }

    private func scheduleAccessoryPolicyTransitionIfNoWindowsVisible() {
        pendingAccessoryTransition = true

        // Switch to accessory policy on the next runloop tick only if neither Main nor Events remains
        // visible or miniaturized, so closing one window keeps an open or minimized other window in the Dock.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingAccessoryTransition else { return }
            self.pendingAccessoryTransition = false
            let mainWindowOpen = self.mainWindow.map { $0.isVisible || $0.isMiniaturized } ?? false
            let eventsWindowOpen = self.eventsWindow.map { $0.isVisible || $0.isMiniaturized } ?? false
            if !mainWindowOpen && !eventsWindowOpen && NSApp.activationPolicy() != .accessory {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    private func removeObservers(_ observers: inout [NSObjectProtocol]) {
        let nc = NotificationCenter.default
        for observer in observers {
            nc.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func installMainMenuObserver() {
        guard mainMenuObserver == nil, let mainMenu = NSApp.mainMenu else { return }
        mainMenuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didAddItemNotification,
            object: mainMenu,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pruneUnusedTopLevelMenus()
            }
        }
    }

    private func pruneUnusedTopLevelMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for index in mainMenu.items.indices.reversed() where index > 0 {
            let item = mainMenu.items[index]
            let isEmptySubmenu = item.submenu?.items.isEmpty == true
            if Self.prunedMenuTitles.contains(item.title) || isEmptySubmenu {
                mainMenu.removeItem(at: index)
            }
        }
    }
}
