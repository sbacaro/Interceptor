import InterceptorEngine
import SwiftUI

/// Clean macOS native discrete mono channel patch list belonging to a Virtual Bridge.
struct RoutePatchListView: View {
    @Bindable var viewModel: AppViewModel
    let bridge: AudioBridgeConfiguration

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Channels")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Spacer()

                Button {
                    viewModel.addChannelToSelectedBridge()
                } label: {
                    Label("Add Channel", systemImage: "plus")
                        .font(.caption.weight(.medium))
                }
                .controlSize(.small)
                .fixedSize()
                .help("Add a discrete mono channel patch (⌘N)")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            if bridge.routes.isEmpty {
                ContentUnavailableView {
                    Label("No Channels", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                } description: {
                    Text("Add a channel to patch a source output directly to a monitor output.")
                } actions: {
                    Button("Add Channel") {
                        viewModel.addChannelToSelectedBridge()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let maxSrc = max(1, viewModel.engine.sourceDevice(for: bridge)?.totalOutputChannels ?? 64)
                let maxDst = max(1, viewModel.engine.destinationDevice(for: bridge)?.totalOutputChannels ?? 2)
                let issuesByID = viewModel.engine.validationIssues(for: bridge)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(bridge.routes.enumerated()), id: \.element.id) { index, route in
                            RouteRowView(
                                route: route,
                                maxSourceChannels: maxSrc,
                                maxDestinationChannels: maxDst,
                                meter: viewModel.meter(for: route, inBridgeID: bridge.id),
                                validationIssues: issuesByID[route.id] ?? [],
                                onUpdate: { viewModel.updateRouteInSelectedBridge($0) },
                                onRemove: { viewModel.removeRouteFromSelectedBridge(routeID: route.id) }
                            )

                            if index < bridge.routes.count - 1 {
                                Divider()
                                    .padding(.leading, 20)
                            }
                        }
                    }
                }
                .scrollEdgeEffectStyle(.soft, for: .vertical)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }
}

#Preview("Route Patch List") {
    let vm = AppViewModel()
    if let first = vm.selectedBridge {
        RoutePatchListView(viewModel: vm, bridge: first)
            .frame(width: 600, height: 280)
    }
}
