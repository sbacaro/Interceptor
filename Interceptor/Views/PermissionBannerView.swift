import InterceptorEngine
import SwiftUI

/// Inline Apple HIG status banner displayed when System Audio Recording permission is needed,
/// an interface is temporarily disconnected, or Core Audio reports an error.
struct PermissionBannerView: View {
    let state: EngineState
    let onOpenSystemSettings: () -> Void
    let onRetry: () -> Void

    var body: some View {
        switch state {
        case .permissionRequired:
            bannerCard(
                icon: "lock.shield",
                tint: .orange,
                title: "System Audio Recording Permission Required",
                message: "Interceptor passively taps output streams using Core Audio without taking exclusive control or muting playback. Grant System Audio Recording permission in System Settings, then click Retry.",
                primaryActionTitle: "Open System Settings",
                primaryAction: onOpenSystemSettings,
                secondaryActionTitle: "Retry",
                secondaryAction: onRetry
            )

        case let .waitingForDevice(role, deviceName):
            bannerCard(
                icon: "cable.connector.slash",
                tint: .orange,
                title: "Waiting for \(role.displayName)",
                message: "\"\(deviceName)\" is currently disconnected. Interceptor will reconnect automatically as soon as the interface becomes available.",
                primaryActionTitle: nil,
                primaryAction: nil,
                secondaryActionTitle: "Retry Now",
                secondaryAction: onRetry
            )

        case let .error(message):
            bannerCard(
                icon: "exclamationmark.triangle.fill",
                tint: .red,
                title: "Audio Bridge Error",
                message: message,
                primaryActionTitle: "Retry",
                primaryAction: onRetry,
                secondaryActionTitle: nil,
                secondaryAction: nil
            )

        case .idle, .starting, .running:
            EmptyView()
        }
    }

    @ViewBuilder
    private func bannerCard(
        icon: String,
        tint: Color,
        title: LocalizedStringKey,
        message: String,
        primaryActionTitle: LocalizedStringKey?,
        primaryAction: (() -> Void)?,
        secondaryActionTitle: LocalizedStringKey?,
        secondaryAction: (() -> Void)?
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                if let secondaryTitle = secondaryActionTitle, let secondary = secondaryAction {
                    Button(secondaryTitle, action: secondary)
                        .controlSize(.regular)
                }
                if let primaryTitle = primaryActionTitle, let primary = primaryAction {
                    Button(primaryTitle, action: primary)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.28), lineWidth: 1)
        )
    }
}

#Preview("Permission Banner") {
    PermissionBannerView(
        state: .permissionRequired,
        onOpenSystemSettings: {},
        onRetry: {}
    )
    .padding()
    .frame(width: 720)
}
