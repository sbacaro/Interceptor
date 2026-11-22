import InterceptorEngine
import SwiftUI

/// Clean horizontal Source ──▶ Monitor interface selector for the active Virtual Bridge.
struct SignalPathHeaderView: View {
    @Bindable var viewModel: AppViewModel
    let bridge: AudioBridgeConfiguration

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            sourceColumn
            signalBridgeArrow
            destinationColumn
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Source

    private var sourceColumn: some View {
        let srcDevice = viewModel.engine.sourceDevice(for: bridge)

        return VStack(alignment: .leading, spacing: 6) {
            Text("Source")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Picker("Playback Interface", selection: sourceSelectionBinding) {
                devicePickerOptions(selectedUID: bridge.sourceDeviceUID, savedName: bridge.sourceDeviceName)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                if let src = srcDevice {
                    Text("\(src.totalOutputChannels) ch · \(src.formattedSampleRate)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Menu {
                    Button {
                        viewModel.updateBridge(id: bridge.id) { $0.processTarget = .allProcesses }
                    } label: {
                        menuCheckLabel("All Processes", isSelected: bridge.processTarget == .allProcesses)
                    }

                    if !viewModel.engine.availableProcesses.isEmpty {
                        Divider()
                        ForEach(viewModel.engine.availableProcesses) { process in
                            if let bundleID = process.bundleID {
                                let target = ProcessTarget.application(bundleID: bundleID, displayName: process.displayName)
                                Button {
                                    viewModel.updateBridge(id: bridge.id) { $0.processTarget = target }
                                } label: {
                                    menuCheckLabel(
                                        process.isRunningOutput ? "\(process.displayName) (Active)" : process.displayName,
                                        isSelected: bridge.processTarget == target
                                    )
                                }
                            }
                        }
                    }

                    if case let .application(bundleID, displayName) = bridge.processTarget,
                       !viewModel.engine.availableProcesses.contains(where: { $0.bundleID == bundleID }) {
                        Divider()
                        Button {} label: {
                            menuCheckLabel("\(displayName) (Armed)", isSelected: true)
                        }
                    }
                } label: {
                    Text(bridge.processTarget.shortDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
                .help("Filter which application output is tapped on the source interface")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Bridge Arrow

    private var signalBridgeArrow: some View {
        let isRunning = viewModel.engine.isBridgeRunning(bridge.id)
        return Image(systemName: "arrow.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isRunning ? Color.accentColor : Color.secondary.opacity(0.45))
            .frame(width: 24)
            .padding(.top, 8)
            .accessibilityHidden(true)
    }

    // MARK: - Destination

    private var destinationColumn: some View {
        let dstDevice = viewModel.engine.destinationDevice(for: bridge)
        let telemetry = viewModel.engine.telemetry(for: bridge.id)

        return VStack(alignment: .leading, spacing: 6) {
            Text("Monitor")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Picker("Monitor Interface", selection: destinationSelectionBinding) {
                devicePickerOptions(selectedUID: bridge.destinationDeviceUID, savedName: bridge.destinationDeviceName)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if let dst = dstDevice {
                    let frames = telemetry.state.isRunning ? telemetry.bufferFrames : dst.bufferFrameSize
                    Text("\(dst.totalOutputChannels) ch · \(dst.formattedSampleRate) · \(frames) fr")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if isSameDeviceSelected {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("Same interface selected for source and destination. Use distinct channels to avoid double monitoring.")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func devicePickerOptions(selectedUID: String?, savedName: String?) -> some View {
        let devices = viewModel.engine.availableDevices
        if devices.isEmpty {
            if let uid = selectedUID {
                let offlineName = savedName ?? uid
                Text("\(offlineName) (Offline)").tag(Optional(uid))
            } else {
                Text("No Output Interfaces Found").tag(Optional<String>.none)
            }
        } else {
            if selectedUID == nil {
                Text("Select Interface…").tag(Optional<String>.none)
            } else if let uid = selectedUID, !devices.contains(where: { $0.uid == uid }) {
                let offlineName = savedName ?? uid
                Text("\(offlineName) (Offline)").tag(Optional(uid))
            }
            ForEach(devices) { device in
                Text(device.name).tag(Optional(device.uid))
            }
        }
    }

    @ViewBuilder
    private func menuCheckLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    // MARK: - Bindings

    private var sourceSelectionBinding: Binding<String?> {
        Binding(
            get: { bridge.sourceDeviceUID },
            set: { newUID in
                viewModel.updateBridge(id: bridge.id) { $0.sourceDeviceUID = newUID }
            }
        )
    }

    private var destinationSelectionBinding: Binding<String?> {
        Binding(
            get: { bridge.destinationDeviceUID },
            set: { newUID in
                viewModel.updateBridge(id: bridge.id) { $0.destinationDeviceUID = newUID }
            }
        )
    }

    private var isSameDeviceSelected: Bool {
        guard let src = bridge.sourceDeviceUID, let dst = bridge.destinationDeviceUID else { return false }
        return src == dst
    }
}

#Preview("Signal Path Header") {
    let vm = AppViewModel()
    if let first = vm.selectedBridge {
        SignalPathHeaderView(viewModel: vm, bridge: first)
            .frame(width: 600)
    }
}
