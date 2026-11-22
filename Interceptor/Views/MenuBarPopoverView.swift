import AppKit
import InterceptorEngine
import SwiftUI

/// Native macOS Control Center-inspired Menu Bar popover listing all Virtual Devices
/// with identical native `Intercept` / `Stop` controls and clean macOS hover action rows.
struct MenuBarPopoverView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Interceptor")
                        .font(.headline)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(viewModel.engine.anyBridgeRunning ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(headerSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if viewModel.engine.bridges.count == 1, let single = viewModel.engine.bridges.first {
                    let isActive = viewModel.engine.isBridgeActiveOrPending(single.id)
                    let canStart = viewModel.engine.canStartBridge(single.id)
                    InterceptionActionButton(
                        isActive: isActive,
                        isDisabled: !canStart && !isActive
                    ) {
                        viewModel.toggleBridge(id: single.id)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()

            // Virtual Devices List
            VStack(spacing: 2) {
                ForEach(viewModel.engine.bridges) { bridge in
                    let telemetry = viewModel.engine.telemetry(for: bridge.id)
                    let isActive = telemetry.state.isActiveOrPending
                    let canStart = viewModel.engine.canStartBridge(bridge.id)

                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(bridge.name)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                if telemetry.state.isRunning {
                                    Text(String(format: "%.1f ms", telemetry.estimatedLatencyMs))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(bridge.routingSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 6)

                        if viewModel.engine.bridges.count > 1 {
                            InterceptionActionButton(
                                isActive: isActive,
                                isDisabled: !canStart && !isActive
                            ) {
                                viewModel.toggleBridge(id: bridge.id)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
            .padding(.vertical, 4)

            Divider()

            // Native Apple Menu-Style Action Rows
            VStack(spacing: 2) {
                MenuBarActionRow(title: "Open Interceptor", shortcut: nil) {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }

                MenuBarActionRow(title: "Settings…", shortcut: "⌘,") {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }

                Divider()
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)

                MenuBarActionRow(title: "Quit Interceptor", shortcut: "⌘Q") {
                    NSApp.terminate(nil)
                }
            }
            .padding(6)
        }
        .frame(width: 300)
    }

    private var headerSubtitle: String {
        let count = viewModel.engine.runningBridgeCount
        if count == 0 {
            return "Standby"
        }
        if count == 1, let running = viewModel.engine.bridges.first(where: { viewModel.engine.isBridgeRunning($0.id) }) {
            let t = viewModel.engine.telemetry(for: running.id)
            return String(format: "%.1f kHz · %.1f ms", t.destinationSampleRate / 1000.0, t.estimatedLatencyMs)
        }
        return "\(count) Active"
    }
}

private struct MenuBarActionRow: View {
    let title: LocalizedStringKey
    let shortcut: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.primary)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.10) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

#Preview("Menu Bar Popover") {
    MenuBarPopoverView(viewModel: AppViewModel())
}
