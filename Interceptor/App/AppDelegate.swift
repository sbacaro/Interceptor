import AppKit
import Foundation

/// AppKit delegate managing:
/// - Dock visibility lifecycle: closes to Menu Bar (`.accessory`) when the main window closes,
///   and restores Dock presence (`.regular`) when reopened from the Menu Bar or Applications.
/// - Deterministic Core Audio teardown on app termination.
/// - Clean top macOS menu bar by pruning unused `Edit`, `Format`, and `View` top-level menus.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: AppViewModel?

    /// Closure registered by SwiftUI (`openWindow(id: "main")`) to reopen the primary window.
    var openMainWindowAction: (() -> Void)?

    private weak var mainWindow: NSWindow?
    private var mainWindowObservers: [NSObjectProtocol] = []
    private var mainMenuObserver: NSObjectProtocol?

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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the window keeps Interceptor alive in the Menu Bar so active audio bridges stay uninterrupted.
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reopening Interceptor from /Applications, Spotlight, or a pinned Dock icon restores the main window.
        showMainWindow(openSettings: false)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeMainWindowObservers()
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
        if mainWindow !== window {
            removeMainWindowObservers()
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

        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            pruneUnusedTopLevelMenus()
        }
        syncMainWindowVisibility()
    }

    /// Restores Dock presence, opens or focuses the main window, and optionally presents the Settings sheet.
    func showMainWindow(openSettings: Bool = false) {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }

        if let openMainWindowAction {
            openMainWindowAction()
        }

        if let window = mainWindow {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }

        NSApp.activate(ignoringOtherApps: true)
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
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
            self.syncMainWindowVisibility()
            if openSettings {
                self.viewModel?.isSettingsPresented = true
            }
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

    private func handleMainWindowWillClose() {
        viewModel?.setMainWindowVisible(false)
        viewModel?.isSettingsPresented = false
        viewModel?.isBridgeInfoPresented = false

        // Switch to accessory policy on the next runloop tick so the window finishes closing cleanly
        // and disappears from the Dock (unless pinned there by the user).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let mainVisible = self.mainWindow?.isVisible == true
            if !mainVisible && NSApp.activationPolicy() != .accessory {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    private func removeMainWindowObservers() {
        let nc = NotificationCenter.default
        for observer in mainWindowObservers {
            nc.removeObserver(observer)
        }
        mainWindowObservers.removeAll()
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
        for item in mainMenu.items.reversed() {
            if Self.prunedMenuTitles.contains(item.title) {
                mainMenu.removeItem(item)
            }
        }
    }
}
