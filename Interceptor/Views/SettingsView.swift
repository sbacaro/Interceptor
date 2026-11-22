import InterceptorEngine
import SwiftUI

/// Native macOS HIG Settings sheet presented inside the main window (`⌘,`).
struct SettingsView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: "Settings")
                    .font(.headline)
                Spacer()
                Text("v\(viewModel.updater.currentVersionString)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            Form {
                Section("General") {
                    Toggle("Open Interceptor at login", isOn: launchAtLoginBinding)

                    if viewModel.launchAtLoginNeedsApproval {
                        LabeledContent {
                            Button("Open Login Items…") {
                                viewModel.openLoginItemsSettings()
                            }
                            .controlSize(.small)
                        } label: {
                            Label("Approval required in System Settings", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } else if let errorMessage = viewModel.launchAtLoginErrorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Automatically reconnect interfaces after disconnect", isOn: $viewModel.autoReconnectEnabled)
                }

                Section {
                    Picker("Preferred Buffer Size", selection: $viewModel.preferredBufferFramesSetting) {
                        Text("Automatic (Match Monitor Interface)").tag(0)
                        Text("64 frames").tag(64)
                        Text("128 frames").tag(128)
                        Text("256 frames").tag(256)
                        Text("512 frames").tag(512)
                    }
                } header: {
                    Text("Private Monitor Bridge")
                } footer: {
                    Text("Applies only to Interceptor's private monitoring bridges and never modifies your playback interface or DAW Playback Engine settings.")
                }

                Section("Updates") {
                    Toggle("Automatically check for updates", isOn: autoCheckUpdatesBinding)

                    LabeledContent("Release Status") {
                        updateActionControl
                    }

                    if let statusText = updateStatusMessage {
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(isUpdateError ? .orange : .secondary)
                    }
                }

                Section("Permissions") {
                    LabeledContent("System Audio Recording") {
                        Button("Open Privacy Settings…") {
                            viewModel.openAudioCaptureSettings()
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Text("Closing the window keeps Interceptor active in the Menu Bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 480, height: 460)
        .onAppear {
            viewModel.refreshLaunchAtLoginStatus()
        }
    }

    @ViewBuilder
    private var updateActionControl: some View {
        switch viewModel.updater.state {
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case let .updateAvailable(update):
            Button("Install v\(update.version.description)") {
                viewModel.installAvailableUpdate(update)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

        case let .downloading(progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 90)
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

        case .installing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Installing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .idle, .upToDate, .error:
            Button("Check Now") {
                viewModel.checkForUpdates()
            }
            .controlSize(.small)
        }
    }

    private var updateStatusMessage: String? {
        switch viewModel.updater.state {
        case .upToDate:
            "Interceptor \(viewModel.updater.currentVersionString) is up to date."
        case let .updateAvailable(update):
            "Version \(update.version.description) is ready to install."
        case let .error(message):
            message
        default:
            nil
        }
    }

    private var isUpdateError: Bool {
        if case .error = viewModel.updater.state { return true }
        return false
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { viewModel.launchAtLoginEnabled },
            set: { newValue in
                viewModel.setLaunchAtLogin(newValue)
            }
        )
    }

    private var autoCheckUpdatesBinding: Binding<Bool> {
        Binding(
            get: { viewModel.updater.autoCheckEnabled },
            set: { newValue in
                viewModel.updater.autoCheckEnabled = newValue
            }
        )
    }
}

#Preview("Settings") {
    SettingsView(viewModel: AppViewModel())
}
