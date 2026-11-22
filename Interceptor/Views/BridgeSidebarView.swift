import InterceptorEngine
import SwiftUI

/// Authentic Apple Audio MIDI Setup-style sidebar listing user-created Virtual Bridges,
/// each with an independent On/Off switch, inline click-to-rename, and native `+` / `−` footer bar.
struct BridgeSidebarView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        List(selection: $viewModel.selectedBridgeID) {
            Section("Virtual Devices") {
                ForEach(viewModel.engine.bridges) { bridge in
                    BridgeSidebarRow(
                        bridge: bridge,
                        telemetry: viewModel.engine.telemetry(for: bridge.id),
                        onRename: { viewModel.renameBridge(id: bridge.id, newName: $0) }
                    )
                    .tag(bridge.id)
                    .contextMenu {
                        let isActive = viewModel.engine.isBridgeActiveOrPending(bridge.id)
                        Button(isActive ? "Stop" : "Intercept") {
                            viewModel.toggleBridge(id: bridge.id)
                        }
                        .disabled(!viewModel.engine.canStartBridge(bridge.id) && !isActive)

                        Divider()

                        Button("Duplicate") {
                            viewModel.duplicateBridge(id: bridge.id)
                        }

                        Button("Delete", role: .destructive) {
                            viewModel.removeBridge(id: bridge.id)
                        }
                        .disabled(viewModel.engine.bridges.count <= 1)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand {
            if let id = viewModel.selectedBridgeID, viewModel.engine.bridges.count > 1 {
                viewModel.removeBridge(id: id)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 2) {
                    Button {
                        viewModel.addBridge()
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .help("Create a new virtual routing bridge (⇧⌘N)")
                    .accessibilityLabel(Text("New Virtual Bridge"))

                    Button {
                        if let id = viewModel.selectedBridgeID {
                            viewModel.removeBridge(id: id)
                        }
                    } label: {
                        Image(systemName: "minus")
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .disabled(viewModel.selectedBridgeID == nil || viewModel.engine.bridges.count <= 1)
                    .help("Delete selected virtual bridge")
                    .accessibilityLabel(Text("Delete Virtual Bridge"))

                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
        }
        .navigationSplitViewColumnWidth(min: 205, ideal: 230, max: 280)
    }
}

private struct BridgeSidebarRow: View {
    let bridge: AudioBridgeConfiguration
    let telemetry: EngineTelemetry
    let onRename: (String) -> Void

    @State private var isEditingName = false
    @State private var draftName = ""
    @FocusState private var isNameFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if isEditingName {
                    TextField("", text: $draftName, prompt: Text("Device Name"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .focused($isNameFocused)
                        .onSubmit { commitRename() }
                        .onExitCommand { isEditingName = false }
                        .onChange(of: isNameFocused) { _, focused in
                            if !focused && isEditingName { commitRename() }
                        }
                } else {
                    Text(bridge.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .onTapGesture(count: 2) {
                            draftName = bridge.name
                            isEditingName = true
                            isNameFocused = true
                        }
                }

                Text(bridge.routingSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if telemetry.state.isRunning {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(Text("Intercepting"))
            } else if case .waitingForDevice = telemetry.state {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(Text("Waiting for device"))
            }
        }
        .padding(.vertical, 3)
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != bridge.name {
            onRename(trimmed)
        }
        isEditingName = false
    }
}

#Preview("Bridge Sidebar") {
    BridgeSidebarView(viewModel: AppViewModel())
        .frame(width: 230, height: 460)
}
