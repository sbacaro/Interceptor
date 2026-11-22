import AppKit
import Foundation

/// AppKit delegate ensuring deterministic Core Audio teardown on termination,
/// respecting Menu Bar keep-alive, and keeping the top macOS menu bar clean
/// by pruning unused `Edit`, `Format`, and `View` top-level menus even if SwiftUI re-inserts them.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: AppViewModel?

    private static let prunedMenuTitles: Set<String> = ["Edit", "Format", "View"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        pruneUnusedTopLevelMenus()
        DispatchQueue.main.async { [weak self] in
            self?.pruneUnusedTopLevelMenus()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        pruneUnusedTopLevelMenus()
    }

    func applicationDidUpdate(_ notification: Notification) {
        pruneUnusedTopLevelMenus()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        guard let vm = viewModel else { return false }
        return !vm.keepRunningInMenuBar
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel?.shutdown()
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
