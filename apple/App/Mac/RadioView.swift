import SwiftUI
import CascadeKit

/// Internet radio: the server's Live TV channels as stations, the desktop's
/// Radio tab. Jellyfin cannot say which channels are radio, so the section
/// only lists them once the person has said theirs are (the setting below),
/// and an account without Live TV access gets an explanation, not a 403.
struct RadioView: View {
    @Environment(AppState.self) private var state
    @State private var channels: [JfItem] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        Group {
            if !state.hasLiveTv {
                ContentUnavailableView("No Live TV access", systemImage: "dot.radiowaves.left.and.right",
                                       description: Text("Radio plays the Live TV channels on your server, and this account does not have access to them."))
            } else if !state.radioEnabled {
                ContentUnavailableView {
                    Label("Radio is off", systemImage: "dot.radiowaves.left.and.right")
                } description: {
                    Text("Radio lists your server's Live TV channels as stations. Jellyfin cannot tell radio channels from TV ones, so turn this on only if yours are internet radio stations.")
                } actions: {
                    Button("Turn On Radio") { state.radioEnabled = true }
                }
            } else {
                stations
            }
        }
        .navigationTitle("Radio")
        .task(id: "\(state.hasLiveTv)|\(state.radioEnabled)|\(state.config?.url ?? "")") { await load() }
    }

    @ViewBuilder private var stations: some View {
        ScrollView {
            if isLoading {
                ProgressView().padding(40)
            } else if let error {
                ContentUnavailableView("Could not load channels", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if channels.isEmpty {
                ContentUnavailableView("No Live TV channels found on this server", systemImage: "dot.radiowaves.left.and.right")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                    ForEach(channels) { channel in
                        Button { Task { await state.player?.playRadio(channel) } } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkView(itemId: channel.id, size: 150)
                                    .overlay(alignment: .bottomLeading) {
                                        if state.player?.item?.id == channel.id {
                                            Label("Playing", systemImage: "dot.radiowaves.left.and.right")
                                                .font(.caption2.bold())
                                                .padding(4)
                                                .background(.regularMaterial, in: Capsule())
                                                .padding(6)
                                        }
                                    }
                                Text(channel.name ?? "Station").font(.caption).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Play \(channel.name ?? "station")")
                    }
                }
                .padding()
            }
        }
    }

    private func load() async {
        guard state.hasLiveTv, state.radioEnabled, let client = state.client else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            channels = try await client.radioChannels()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The opt-in, for Settings > Playback (or wherever settings put it): shown
/// only to an account that has Live TV, as on the desktop, where the row hides
/// itself otherwise.
struct RadioSettingsSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.hasLiveTv {
            @Bindable var state = state
            Toggle("Show Radio", isOn: $state.radioEnabled)
            Text("Lists your server's Live TV channels in a Radio section. Turn this on only if those channels are internet radio stations, not real TV.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
