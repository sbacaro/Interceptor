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
    private var mainWindowCloseObserver: NSObjectProtocol?

    private static let prunedMenuTitles: Set<String> = ["Edit", "Format", "View"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        pruneUnusedTopLevelMenus()
        DispatchQueue.main.async { [weak self] in
            self?.pruneUnusedTopLevelMenus()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        pruneUnusedTopLevelMenus()
        viewModel?.refreshLaunchAtLoginStatus()
    }

    func applicationDidUpdate(_ notification: Notification) {
        pruneUnusedTopLevelMenus()
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
        if let observer = mainWindowCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            mainWindowCloseObserver = nil
        }
        viewModel?.shutdown()
    }

    // MARK: - Window & Dock Visibility

    /// Registers the primary SwiftUI window so we observe ONLY its close event (ignoring MenuBarExtra panels).
    func registerMainWindow(_ window: NSWindow) {
        if mainWindow !== window {
            if let observer = mainWindowCloseObserver {
                NotificationCenter.default.removeObserver(observer)
                mainWindowCloseObserver = nil
            }
            mainWindow = window
            mainWindowCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleMainWindowWillClose()
                }
            }
        }

        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            pruneUnusedTopLevelMenus()
        }
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
            if openSettings {
                self.viewModel?.isSettingsPresented = true
            }
        }
    }

    private func handleMainWindowWillClose() {
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

    private func pruneUnusedTopLevelMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for item in mainMenu.items.reversed() {
            if Self.prunedMenuTitles.contains(item.title) {
                mainMenu.removeItem(item)
            }
        }
    }
}
