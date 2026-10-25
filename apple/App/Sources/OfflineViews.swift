import SwiftUI
import CascadeKit

// Offline Mode's pieces of UI (docs/offline-mode-plan.md, section 4): the
// pill in the toolbar, the banner when it turned on by itself, and the
// Settings switch. AppState holds the state.

/// "Offline" in the toolbar while Offline Mode is on, either way.
struct OfflinePill: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.isOffline {
            Text("Offline")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
                .help(Self.explanation(state.offlineState))
                .accessibilityLabel("Offline")
                .accessibilityHint(Self.explanation(state.offlineState))
        }
    }

    static func explanation(_ state: OfflineState) -> String {
        state == .manual
            ? "Offline Mode is on: only what is downloaded shows."
            : "Your server isn't answering: only what is downloaded shows."
    }
}

/// Across the top while the server is not answering, with a way to ask it
/// again now rather than at the next probe. Not shown for the switch: that
/// was the person's own choice.
struct OfflineBanner: View {
    @Environment(AppState.self) private var state
    @State private var retrying = false

    var body: some View {
        if state.offlineState == .unreachable {
            HStack(spacing: 10) {
                Image(systemName: "wifi.slash")
                Text("Your server isn't answering. Showing what is downloaded.")
                    .scaledFont(.callout)
                Spacer(minLength: 8)
                Button(retrying ? "Trying\u{2026}" : "Try Again") {
                    retrying = true
                    Task {
                        await state.retryServer()
                        retrying = false
                    }
                }
                .disabled(retrying)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.orange.opacity(0.18))
        }
    }
}

#if os(iOS) || os(macOS)
/// The Settings switch. Stays on across launches until turned off.
struct OfflineModeSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Section {
            Toggle("Offline Mode", isOn: Binding(
                get: { state.offlineState == .manual },
                set: { on in Task { await state.setOfflineSwitch(on) } }))
        } footer: {
            Text("Shows only what is downloaded and sends nothing to your server, playback reports included. Stays on until you turn it off. Without the switch, Offline Mode also turns on by itself when your server stops answering, and off again when it is back.")
        }
    }
}
#endif
