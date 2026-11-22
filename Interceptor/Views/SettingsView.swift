import InterceptorEngine
import SwiftUI

/// Native macOS HIG Settings window (`⌘,`).
struct SettingsView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        Form {
            Section("Behavior") {
                Toggle("Keep running in Menu Bar when main window closes", isOn: $viewModel.keepRunningInMenuBar)
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

            Section("Permissions") {
                LabeledContent("System Audio Recording") {
                    Button("Open Privacy Settings…") {
                        viewModel.openAudioCaptureSettings()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 300)
    }
}

#Preview("Settings") {
    SettingsView(viewModel: AppViewModel())
}
