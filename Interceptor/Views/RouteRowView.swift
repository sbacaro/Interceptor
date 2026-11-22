import InterceptorEngine
import SwiftUI

/// Pure discrete mono channel patch row with inline studio VU meter:
/// Switch · Click-to-Edit Name · Source Ch → Monitor Out · Graduated VU Meter · Remove.
struct RouteRowView: View {
    let route: ChannelRoute
    let maxSourceChannels: Int
    let maxDestinationChannels: Int
    let meterModel: RouteMeterModel
    let validationIssues: [RouteValidationIssue]
    let onUpdate: (ChannelRoute) -> Void
    let onRemove: () -> Void
    var onResetClips: (() -> Void)? = nil

    @State private var isHovering = false
    @State private var isEditingName = false
    @State private var draftName = ""
    @State private var wasNameFieldFocused = false
    @FocusState private var isNameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle("Enable Channel", isOn: enabledBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.mini)
                    .help("Enable or bypass this channel")

                routeNameControl
                    .frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    channelPicker(
                        prefix: "Ch",
                        selection: sourceChannelBinding,
                        maxChannel: maxSourceChannels
                    )

                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)

                    channelPicker(
                        prefix: "Out",
                        selection: destinationChannelBinding,
                        maxChannel: maxDestinationChannels
                    )
                }

                LiveChannelVUMeterView(meterModel: meterModel, onResetClips: onResetClips)

                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .font(.callout)
                        .foregroundStyle(isHovering ? Color.secondary : Color.secondary.opacity(0.35))
                }
                .buttonStyle(.plain)
                .help("Remove Channel")
                .accessibilityLabel(Text("Remove \(route.label)"))
            }

            if !validationIssues.isEmpty {
                ForEach(validationIssues, id: \.self) { issue in
                    Label(
                        issue.localizedMessage,
                        systemImage: issue.isWarningOnly ? "exclamationmark.triangle.fill" : "xmark.octagon.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(issue.isWarningOnly ? .orange : .red)
                    .padding(.leading, 36)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .opacity(route.isEnabled ? 1.0 : 0.5)
    }

    @ViewBuilder
    private var routeNameControl: some View {
        if isEditingName {
            TextField("", text: $draftName, prompt: Text("Channel Name"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.callout.weight(.medium))
                .focused($isNameFieldFocused)
                .onAppear {
                    isNameFieldFocused = true
                }
                .onSubmit {
                    commitNameEdit()
                }
                .onExitCommand {
                    isEditingName = false
                    wasNameFieldFocused = false
                }
                .onChange(of: isNameFieldFocused) { _, focused in
                    if focused {
                        wasNameFieldFocused = true
                    } else if wasNameFieldFocused && isEditingName {
                        commitNameEdit()
                    }
                }
        } else {
            Text(route.label.isEmpty ? "Untitled Channel" : route.label)
                .font(.callout.weight(.medium))
                .foregroundStyle(route.label.isEmpty ? .tertiary : .primary)
                .lineLimit(1)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture {
                    draftName = route.label
                    wasNameFieldFocused = false
                    isEditingName = true
                }
                .help("Click to rename channel")
        }
    }

    private func commitNameEdit() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != route.label {
            var updated = route
            updated.label = trimmed
            onUpdate(updated)
        }
        isEditingName = false
        wasNameFieldFocused = false
    }

    @ViewBuilder
    private func channelPicker(
        prefix: String,
        selection: Binding<Int>,
        maxChannel: Int
    ) -> some View {
        let upper = max(1, max(maxChannel, selection.wrappedValue))
        Picker(prefix, selection: selection) {
            ForEach(1...upper, id: \.self) { ch in
                Text("\(prefix) \(ch)").tag(ch)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
    }

    // MARK: - Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { route.isEnabled },
            set: { newValue in
                var updated = route
                updated.isEnabled = newValue
                onUpdate(updated)
            }
        )
    }

    private var sourceChannelBinding: Binding<Int> {
        Binding(
            get: { route.sourceChannel },
            set: { newValue in
                var updated = route
                updated.sourceChannel = newValue
                onUpdate(updated)
            }
        )
    }

    private var destinationChannelBinding: Binding<Int> {
        Binding(
            get: { route.destinationChannel },
            set: { newValue in
                var updated = route
                updated.destinationChannel = newValue
                onUpdate(updated)
            }
        )
    }
}

#Preview("Route Row") {
    VStack(spacing: 0) {
        RouteRowView(
            route: ChannelRoute(label: "Channel 1", sourceChannel: 63, destinationChannel: 1),
            maxSourceChannels: 64,
            maxDestinationChannels: 8,
            meterModel: RouteMeterModel(level: SmoothedChannelMeter(rmsDB: -18.0, peakDB: -11.4, peakHoldDB: -7.0, peakHoldTimestamp: 0, isClipped: false)),
            validationIssues: [],
            onUpdate: { _ in },
            onRemove: {}
        )
        Divider().padding(.leading, 20)
        RouteRowView(
            route: ChannelRoute(label: "Channel 2", sourceChannel: 64, destinationChannel: 2),
            maxSourceChannels: 64,
            maxDestinationChannels: 8,
            meterModel: RouteMeterModel(level: SmoothedChannelMeter(rmsDB: -21.0, peakDB: -14.2, peakHoldDB: -9.5, peakHoldTimestamp: 0, isClipped: false)),
            validationIssues: [],
            onUpdate: { _ in },
            onRemove: {}
        )
    }
    .frame(width: 600)
}
