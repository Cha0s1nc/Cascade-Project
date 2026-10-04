#if !os(tvOS)
import SwiftUI
import CascadeKit

/// Links the playing song to a Spotify track, for SpicyLyrics: Cascade Server
/// finds a song's Spotify id itself, and this is for the songs it cannot, or
/// where it picked the wrong release. Saved on the server for everyone when
/// this user may do that, otherwise on this device for them only. The
/// desktop's Link a Spotify Track dialog.
struct SpotifyLinkSheet: View {
    let track: JfItem

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var error: String?
    /// Something is linked that a person set, so it can be removed (handing
    /// the song back to the automatic lookup).
    @State private var removable = false
    @State private var busy = false

    private var serverWide: Bool { state.cascadePluginInfo.spotifyLinkServerWide }
    private var localLink: String? { state.localSpotifyLinks[track.id] }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Spotify song link", text: $link)
                        #if os(iOS)
                        .keyboardType(.URL)
                        #endif
                        .noAutocaps()
                        .autocorrectionDisabled()
                        .onSubmit(save)
                    PasteButton(payloadType: String.self) { strings in
                        if let first = strings.first { link = first }
                    }
                } header: {
                    Text(track.name ?? "")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(serverWide
                             ? "Paste this song's Spotify link and Cascade Server will look for Spicy Lyrics with it. The link is saved on the server, so it works for everyone there."
                             : "Paste this song's Spotify link and Cascade will look for Spicy Lyrics with it. The link is saved on this device, for you only; a server admin can let you link songs for everyone.")
                        if let error {
                            Text(error).foregroundStyle(.red)
                        }
                    }
                }
                if removable {
                    Section {
                        Button("Remove Link", role: .destructive, action: remove)
                            .disabled(busy)
                    }
                }
            }
            .navigationTitle("Link Spotify Track")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(busy || link.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .task(loadCurrent)
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        // A Mac sheet has no detents; give the form room.
        .frame(minWidth: 460, minHeight: 300)
        #endif
    }

    /// What the song is linked to now: this device's link, else the server's.
    private func loadCurrent() async {
        if let localLink {
            link = "https://open.spotify.com/track/\(localLink)"
            removable = true
            return
        }
        guard serverWide, let client = state.client,
              let current = try? await client.spotifyLink(itemId: track.id) else { return }
        if let id = current.spotifyId, link.isEmpty { link = "https://open.spotify.com/track/\(id)" }
        removable = current.manual
    }

    private func save() {
        guard let id = Spotify.trackId(link) else {
            error = "That is not a Spotify track link. Copy it from Share \u{2192} Copy Song Link."
            return
        }
        guard serverWide else {
            state.setLocalSpotifyLink(itemId: track.id, spotifyId: id)
            dismiss()
            return
        }
        send { try await $0.setSpotifyLink(itemId: track.id, spotifyId: id) }
    }

    private func remove() {
        // A personal link is removed here; a server-wide one on the server.
        if localLink != nil || !serverWide {
            state.setLocalSpotifyLink(itemId: track.id, spotifyId: nil)
            dismiss()
            return
        }
        send { try await $0.removeSpotifyLink(itemId: track.id) }
    }

    /// A change on the server, then the song's lyrics asked for again. Only
    /// closes once the server has taken it: a refusal (403 when this user may
    /// not) says why instead.
    private func send(_ change: @escaping (JellyfinClient) async throws -> Void) {
        guard let client = state.client else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await change(client)
                state.lyricsRevision += 1
                dismiss()
            } catch let e as JellyfinError {
                error = e.message
            } catch {
                self.error = "Could not reach the server."
            }
        }
    }
}
#endif
