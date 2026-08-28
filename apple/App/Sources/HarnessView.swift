import SwiftUI
import CascadeKit

// A test harness, not the app. Its whole job is to answer the questions a
// simulator cannot: does a FLAC direct play on real hardware, does seeking
// work, and does audio survive the screen locking under free provisioning.
// The real Now Playing screen replaces this once those answers are in.

/// Unique per install. A constant would make every Cascade look like the same
/// device to the server, so remote control could not target one of them and two
/// installs would collide in the session list.
private func installDeviceId() -> String {
    let key = "cascade.deviceId"
    if let existing = UserDefaults.standard.string(forKey: key) { return existing }
    let fresh = UUID().uuidString
    UserDefaults.standard.set(fresh, forKey: key)
    return fresh
}

@MainActor
@Observable
final class HarnessModel {
    var server = "https://jellyfin.chaosinc.xyz"
    var username = ""
    var password = ""
    var status = ""
    var tracks: [JfItem] = []
    var service: PlaybackService?

    func signIn() async {
        status = "Signing in..."
        do {
            let deviceId = installDeviceId()
            let auth = try await authenticate(serverUrl: server, username: username,
                                              password: password, appVersion: "0.1.0",
                                              deviceId: deviceId)
            let config = ServerConfig(url: server, token: auth.accessToken,
                                      userId: auth.user.id, deviceId: deviceId)
            let client = JellyfinClient(config: config)
            service = PlaybackService(client: client, config: config)

            let response: JfItemsResponse = try await client.get("/Items", params: [
                "userId": config.userId,
                "includeItemTypes": "Audio",
                "recursive": "true",
                "sortBy": "Random",
                "limit": "25",
            ])
            tracks = response.items ?? []
            status = "Signed in, \(tracks.count) tracks"
        } catch {
            // Shown rather than swallowed. A sign-in that fails quietly is
            // indistinguishable from one that worked.
            status = error.localizedDescription
        }
    }
}

struct HarnessView: View {
    @State private var model = HarnessModel()

    var body: some View {
        NavigationStack {
            if let service = model.service {
                TrackListView(model: model, service: service)
                    .navigationTitle("Cascade")
            } else {
                SignInView(model: model)
                    .navigationTitle("Sign in")
            }
        }
    }
}

private struct SignInView: View {
    @Bindable var model: HarnessModel

    var body: some View {
        Form {
            Section {
                TextField("Server", text: $model.server)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Username", text: $model.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("Password", text: $model.password)
            }
            Button("Sign in") {
                Task { await model.signIn() }
            }
            if !model.status.isEmpty {
                Text(model.status).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

private struct TrackListView: View {
    let model: HarnessModel
    let service: PlaybackService

    var body: some View {
        VStack(spacing: 0) {
            List(model.tracks) { track in
                Button {
                    Task { await service.play(track) }
                } label: {
                    VStack(alignment: .leading) {
                        Text(track.name ?? track.id)
                        Text(track.albumArtist ?? track.artists?.first ?? "")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            TransportView(service: service)
        }
    }
}

private struct TransportView: View {
    let service: PlaybackService
    /// While the thumb is held, the slider owns the position. Without this the
    /// half-second position updates fight the drag and the thumb jumps back.
    @State private var scrubbing: Double?

    var body: some View {
        VStack(spacing: 8) {
            Divider()
            Text(service.item?.name ?? "Nothing playing")
                .font(.headline).lineLimit(1)

            if let error = service.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if service.isTranscoding {
                // Should essentially never appear on this library. If it does,
                // the device profile and the server disagree about FLAC.
                Text("Transcoding").font(.caption).foregroundStyle(.orange)
            }

            Slider(
                value: Binding(
                    get: { scrubbing ?? service.positionSeconds },
                    set: { scrubbing = $0 }
                ),
                in: 0...max(service.durationSeconds, 1),
                onEditingChanged: { editing in
                    guard !editing, let target = scrubbing else { return }
                    Task {
                        await service.seek(to: target)
                        scrubbing = nil
                    }
                }
            )
            .disabled(service.item == nil)

            HStack {
                Text(clock(scrubbing ?? service.positionSeconds))
                Spacer()
                Button(service.isPaused ? "Play" : "Pause") { service.togglePlayPause() }
                    .buttonStyle(.borderedProminent)
                    .disabled(service.item == nil)
                Spacer()
                Text(clock(service.durationSeconds))
            }
            .font(.caption.monospacedDigit())
        }
        .padding()
    }

    private func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
