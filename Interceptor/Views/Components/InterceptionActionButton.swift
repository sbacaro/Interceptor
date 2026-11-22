import SwiftUI

/// Single shared native SwiftUI `Intercept` / `Stop` button used identically across
/// the Main Window toolbar and the Menu Bar Extra popover, letting SwiftUI/macOS render
/// the native Liquid Glass capsule bezel directly (zero double-pill wrapper).
struct InterceptionActionButton: View {
    let isActive: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isActive ? "stop.fill" : "play.fill")
                    .font(.caption.weight(.semibold))
                Text(isActive ? "Stop" : "Intercept")
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(isActive ? Color("StopTint") : Color("AccentColor"))
        .disabled(isDisabled)
        .fixedSize()
        .help("Start or stop passive audio interception (⌘R)")
    }
}

#Preview("Interception Action Button") {
    HStack(spacing: 12) {
        InterceptionActionButton(isActive: false, isDisabled: false, action: {})
        InterceptionActionButton(isActive: true, isDisabled: false, action: {})
    }
    .padding()
}
