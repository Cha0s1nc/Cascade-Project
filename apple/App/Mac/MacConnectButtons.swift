import SwiftUI
import CascadeKit

/// Toolbar buttons for the two ways of listening beyond this Mac: driving
/// another device (the desktop's device panel) and a Waterfall room. Each
/// opens its own sheet; the Devices one polls only while it is open.
struct MacConnectButtons: View {
    @Environment(AppState.self) private var state
    @State private var devices = false
    @State private var waterfall = false

    var body: some View {
        HStack {
            Button { devices = true } label: {
                Image(systemName: state.controlledDevice == nil ? "hifispeaker.2" : "hifispeaker.2.fill")
            }
            .help("Control other devices")
            .accessibilityLabel("Control Devices")
            Button { waterfall = true } label: {
                Image(systemName: state.waterfall?.isActive == true ? "person.2.wave.2.fill" : "person.2.wave.2")
            }
            .help("Waterfall: listen together")
            .accessibilityLabel("Waterfall")
        }
        .sheet(isPresented: $devices) { DevicesSheet().environment(state) }
        .sheet(isPresented: $waterfall) {
            NavigationStack {
                WaterfallView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { waterfall = false } } }
            }
            .frame(minWidth: 420, minHeight: 460)
            .environment(state)
        }
    }
}
