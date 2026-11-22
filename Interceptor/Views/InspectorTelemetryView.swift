import InterceptorEngine
import SwiftUI

/// Quiet, on-demand Audio Bridge Info popover opened from the toolbar (`⌘I`).
struct InspectorTelemetryView: View {
    @Bindable var viewModel: AppViewModel
    let bridge: AudioBridgeConfiguration

    var body: some View {
        let telemetry = viewModel.engine.telemetry(for: bridge.id)
        let srcDevice = viewModel.engine.sourceDevice(for: bridge)
        let dstDevice = viewModel.engine.destinationDevice(for: bridge)

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor(for: telemetry.state))
                    .frame(width: 8, height: 8)
                Text(telemetry.state.statusTitle)
                    .font(.headline)
                Spacer()
                Text("Passive Tap")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(spacing: 7) {
                let effectiveBufferFrames = telemetry.bufferFrames > 0
                    ? telemetry.bufferFrames
                    : (dstDevice?.bufferFrameSize ?? 0)
                infoRow(
                    "Source Rate",
                    value: AudioDeviceDescriptor.formatSampleRate(
                        telemetry.sourceSampleRate > 0 ? telemetry.sourceSampleRate : (srcDevice?.nominalSampleRate ?? 0)
                    )
                )
                infoRow(
                    "Monitor Rate",
                    value: AudioDeviceDescriptor.formatSampleRate(
                        telemetry.destinationSampleRate > 0 ? telemetry.destinationSampleRate : (dstDevice?.nominalSampleRate ?? 0)
                    )
                )
                infoRow("Drift Compensation", value: telemetry.driftCompensationActive ? "Active (PI Hermite)" : "Standby")
                infoRow("Buffer Size", value: effectiveBufferFrames > 0 ? "\(effectiveBufferFrames) frames" : "—")
                infoRow("Monitor Latency", value: telemetry.estimatedLatencyMs > 0 ? String(format: "%.2f ms", telemetry.estimatedLatencyMs) : "—")
                infoRow("XRuns", value: "\(telemetry.xrunCount)", tint: telemetry.xrunCount > 0 ? .orange : nil)
            }

            Divider()

            VStack(spacing: 7) {
                infoRow("Tap Mode", value: "Unmuted · Non-Exclusive")
                infoRow("Process Scope", value: bridge.processTarget.shortDescription)
                infoRow("Signal Path", value: telemetry.isSampleRateConverted ? "Unity (SRC)" : "Unity (Bit-Transparent)")
            }

            Divider()

            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(telemetry.state == .permissionRequired ? Color.orange : Color.green)
                        .frame(width: 7, height: 7)
                    Text(telemetry.state == .permissionRequired ? "Audio Capture Required" : "Audio Capture Ready")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Privacy…") {
                    viewModel.openAudioCaptureSettings()
                }
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 295)
    }

    private func infoRow(_ label: LocalizedStringKey, value: String, tint: Color? = nil) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(tint ?? .primary)
        }
    }

    private func statusColor(for state: EngineState) -> Color {
        switch state {
        case .running: .green
        case .starting, .waitingForDevice, .permissionRequired: .orange
        case .error: .red
        case .idle: .secondary
        }
    }
}

#Preview("Bridge Info Popover") {
    let vm = AppViewModel()
    if let first = vm.selectedBridge {
        InspectorTelemetryView(viewModel: vm, bridge: first)
    }
}
