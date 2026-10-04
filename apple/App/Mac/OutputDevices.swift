import SwiftUI
import CascadeKit

/// Output device picker, embedded by Settings > Playback. Lists the Mac's
/// CoreAudio outputs and keeps the list current as devices come and go. A
/// device that vanishes while chosen drops to the system default, and the
/// notice says so until it is dismissed.
struct OutputDeviceSettings: View {
    @Environment(AppState.self) private var state

    /// A tag for "no device chosen", since a Picker cannot tag nil.
    private let systemDefault = AudioOutput.defaultId

    var body: some View {
        if let player = state.player {
            Picker("Output Device", selection: Binding(
                get: { player.outputDeviceId ?? systemDefault },
                set: { choice in
                    player.outputNotice = nil
                    player.outputDeviceId = choice == systemDefault ? nil : choice
                })) {
                Text("System Default").tag(systemDefault)
                ForEach(player.outputDevices) { device in
                    Text(device.name).tag(device.id)
                }
            }
            if let notice = player.outputNotice {
                HStack(alignment: .firstTextBaseline) {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss") { player.outputNotice = nil }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }
}
