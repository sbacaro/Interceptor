import AppKit
import InterceptorEngine
import SwiftUI

/// Primary Apple Audio MIDI Setup-inspired workspace:
/// Leading sidebar of Virtual Devices (Routing Bridges) + clean detail canvas with
/// Source ──▶ Monitor selection and discrete mono Channel Routes with inline studio VU meters.
struct MainWindowView: View {
    @Bindable var viewModel: AppViewModel
    let appDelegate: AppDelegate

    @Environment(\.openWindow) private var openWindow
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            BridgeSidebarView(viewModel: viewModel)
        } detail: {
            if let bridge = viewModel.selectedBridge {
                let telemetry = viewModel.engine.telemetry(for: bridge.id)

                VStack(spacing: 0) {
                    if viewModel.updater.shouldShowInAppBanner {
                        UpdateBannerView(
                            updater: viewModel.updater,
                            onInstall: { update in
                                viewModel.installAvailableUpdate(update)
                            }
                        )
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                    }

                    if shouldShowBanner(for: telemetry.state) {
                        PermissionBannerView(
                            state: telemetry.state,
                            onOpenSystemSettings: { viewModel.openAudioCaptureSettings() },
                            onRetry: { viewModel.engine.startBridge(id: bridge.id) }
                        )
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                    }

                    SignalPathHeaderView(viewModel: viewModel, bridge: bridge)

                    Divider()

                    RoutePatchListView(viewModel: viewModel, bridge: bridge)
                }
                .frame(minWidth: 560, minHeight: 400)
            } else {
                ContentUnavailableView {
                    Label("No Virtual Device Selected", systemImage: "hifispeaker.2")
                } description: {
                    Text("Create a virtual routing device to intercept and monitor discrete audio channels.")
                } actions: {
                    Button("New Virtual Device") {
                        viewModel.addBridge()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(minWidth: 560, minHeight: 400)
            }
        }
        .navigationTitle(viewModel.selectedBridge?.name ?? "Interceptor")
        .navigationSubtitle(windowSubtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                let selectedID = viewModel.selectedBridge?.id
                let isActive = selectedID.map { viewModel.engine.isBridgeActiveOrPending($0) } ?? false
                let canStart = selectedID.map { viewModel.engine.canStartBridge($0) } ?? false

                InterceptionActionButton(
                    isActive: isActive,
                    isDisabled: !canStart && !isActive
                ) {
                    viewModel.toggleSelectedBridge()
                }
            }

            ToolbarSpacer(.fixed)

            ToolbarItemGroup(placement: .automatic) {
                Button {
                    viewModel.refreshDevices()
                } label: {
                    Label("Refresh Interfaces", systemImage: "arrow.clockwise")
                }
                .help("Refresh Core Audio interfaces and active applications (⇧⌘R)")

                Button {
                    viewModel.isBridgeInfoPresented.toggle()
                } label: {
                    Label("Bridge Info", systemImage: "info.circle")
                }
                .disabled(viewModel.selectedBridge == nil)
                .help("Show audio bridge clock and latency info (⌘I)")
                .popover(isPresented: $viewModel.isBridgeInfoPresented, arrowEdge: .bottom) {
                    if let bridge = viewModel.selectedBridge {
                        InspectorTelemetryView(viewModel: viewModel, bridge: bridge)
                    }
                }

                Button {
                    viewModel.isSettingsPresented = true
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                }
                .help("Open Interceptor settings (⌘,)")
            }
        }
        .background(
            MainWindowRegistrationView { window in
                appDelegate.registerMainWindow(window)
            }
        )
        .onAppear {
            appDelegate.openMainWindowAction = { openWindow(id: "main") }
            viewModel.setMainWindowVisible(true)
        }
        .onDisappear {
            viewModel.setMainWindowVisible(false)
        }
        .sheet(isPresented: $viewModel.isSettingsPresented) {
            SettingsView(viewModel: viewModel)
                .tint(Color("AccentColor"))
        }
    }

    private func shouldShowBanner(for state: EngineState) -> Bool {
        switch state {
        case .permissionRequired, .waitingForDevice, .error:
            true
        case .idle, .starting, .running:
            false
        }
    }

    private var windowSubtitle: String {
        guard viewModel.selectedBridge != nil else { return "" }
        let telemetry = viewModel.selectedBridgeTelemetry
        switch telemetry.state {
        case .running:
            let khz = String(format: "%.1f kHz", telemetry.destinationSampleRate / 1000.0)
            let ms = String(format: "%.1f ms", telemetry.estimatedLatencyMs)
            return "Intercepting · \(khz) · \(ms)"
        case .starting:
            return "Starting…"
        case let .waitingForDevice(_, name):
            return "Waiting for \(name)"
        case .permissionRequired:
            return "Permission Required"
        case .error:
            return "Audio Error"
        case .idle:
            return "Standby"
        }
    }
}

/// Captures the hosting `NSWindow` for `MainWindowView` so `AppDelegate` observes
/// close events exclusively for the main app window (ignoring `MenuBarExtra` panels).
private struct MainWindowRegistrationView: NSViewRepresentable {
    let onWindowAvailable: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowObserverNSView {
        let view = WindowObserverNSView()
        view.onWindowAvailable = onWindowAvailable
        return view
    }

    func updateNSView(_ nsView: WindowObserverNSView, context: Context) {
        nsView.onWindowAvailable = onWindowAvailable
        nsView.notifyIfWindowChanged()
    }
}

private final class WindowObserverNSView: NSView {
    var onWindowAvailable: (@MainActor (NSWindow) -> Void)?
    private weak var lastRegisteredWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        notifyIfWindowChanged()
    }

    func notifyIfWindowChanged() {
        guard let window, lastRegisteredWindow !== window else { return }
        lastRegisteredWindow = window
        onWindowAvailable?(window)
    }
}

#Preview("Main Window") {
    MainWindowView(viewModel: AppViewModel(), appDelegate: AppDelegate())
        .frame(width: 840, height: 500)
}
