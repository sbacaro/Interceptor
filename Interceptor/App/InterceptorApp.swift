import InterceptorEngine
import SwiftUI

@main
struct InterceptorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var viewModel = AppViewModel()

    var body: some Scene {
        Window("Interceptor", id: "main") {
            MainWindowView(viewModel: viewModel, appDelegate: appDelegate)
                .tint(Color("AccentColor"))
                .onAppear {
                    appDelegate.viewModel = viewModel
                }
        }
        .defaultSize(width: 840, height: 500)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            InterceptorCommands(viewModel: viewModel, appDelegate: appDelegate)
        }

        MenuBarExtra {
            MenuBarPopoverView(viewModel: viewModel, appDelegate: appDelegate)
                .tint(Color("AccentColor"))
        } label: {
            Label {
                Text("Interceptor")
            } icon: {
                Image(systemName: menuBarSymbolName)
            }
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbolName: String {
        if viewModel.engine.anyBridgeRunning {
            return "waveform.badge.checkmark"
        }
        let hasIssue = viewModel.engine.telemetryByBridgeID.values.contains {
            switch $0.state {
            case .permissionRequired, .error: true
            default: false
            }
        }
        if hasIssue {
            return "exclamationmark.triangle"
        }
        if viewModel.engine.anyBridgeActiveOrPending {
            return "waveform.badge.exclamationmark"
        }
        return "waveform"
    }
}

/// Native macOS menu bar commands — routes `⌘,` to the in-window Settings sheet and removes unused `Edit` and `View` menus.
struct InterceptorCommands: Commands {
    @Bindable var viewModel: AppViewModel
    let appDelegate: AppDelegate

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                appDelegate.viewModel = viewModel
                appDelegate.showMainWindow(openSettings: true)
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Check for Updates…") {
                appDelegate.viewModel = viewModel
                appDelegate.showMainWindow(openSettings: true)
                viewModel.checkForUpdates()
            }
        }

        CommandGroup(replacing: .undoRedo) {}
        CommandGroup(replacing: .pasteboard) {}
        CommandGroup(replacing: .textEditing) {}
        CommandGroup(replacing: .textFormatting) {}
        CommandGroup(replacing: .sidebar) {}
        CommandGroup(replacing: .toolbar) {}

        CommandGroup(after: .newItem) {
            Button("New Virtual Bridge") {
                viewModel.addBridge()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("Add Channel") {
                viewModel.addChannelToSelectedBridge()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(viewModel.selectedBridge == nil)

            Divider()

            Button("Refresh Audio Interfaces") {
                viewModel.refreshDevices()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }

        CommandMenu("Bridge") {
            let isSelectedActive = viewModel.selectedBridge.map { viewModel.engine.isBridgeActiveOrPending($0.id) } ?? false
            let canStartSelected = viewModel.selectedBridge.map { viewModel.engine.canStartBridge($0.id) } ?? false

            Button(isSelectedActive ? "Stop Bridge" : "Start Bridge") {
                viewModel.toggleSelectedBridge()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!canStartSelected && !isSelectedActive)

            Button("Stop All Bridges") {
                viewModel.stopAllBridges()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(!viewModel.engine.anyBridgeActiveOrPending)

            Divider()

            Button(viewModel.isBridgeInfoPresented ? "Hide Bridge Info" : "Show Bridge Info") {
                viewModel.isBridgeInfoPresented.toggle()
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(viewModel.selectedBridge == nil)
        }
    }
}
