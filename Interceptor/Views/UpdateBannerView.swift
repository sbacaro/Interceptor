import SwiftUI

/// Subtle native macOS in-app banner notifying the user when a newer GitHub release is available.
struct UpdateBannerView: View {
    let updater: GitHubReleaseUpdater
    let onInstall: (AvailableUpdate) -> Void

    @State private var isNotesPresented = false

    var body: some View {
        switch updater.state {
        case let .updateAvailable(update):
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color("AccentColor"))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Interceptor \(update.version.description) is available")
                        .font(.callout.weight(.semibold))
                    Text("You are running \(updater.currentVersionString). Download and install directly from GitHub Releases.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                if !update.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Notes") {
                        isNotesPresented.toggle()
                    }
                    .controlSize(.small)
                    .popover(isPresented: $isNotesPresented, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(update.title)
                                .font(.headline)
                            ScrollView {
                                Text(update.releaseNotes)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 220)
                        }
                        .padding(14)
                        .frame(width: 340)
                    }
                }

                Button("Install Update") {
                    onInstall(update)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    updater.isBannerDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss until next launch")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color("AccentColor").opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color("AccentColor").opacity(0.25), lineWidth: 1)
            )

        case let .downloading(progress):
            HStack(spacing: 12) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 180)

                Text("Downloading update… \(Int(progress * 100))%")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.10))
            )

        case .installing:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Verifying and installing update…")
                    .font(.callout.weight(.medium))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.10))
            )

        default:
            EmptyView()
        }
    }
}
