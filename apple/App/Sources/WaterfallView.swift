import SwiftUI
import CascadeKit
#if os(macOS)
import AppKit
#endif

/// Waterfall: listen along with others signed in to the same server, the
/// desktop's room panel. Start a room and share its code, or join one.
struct WaterfallView: View {
    @Environment(AppState.self) private var state
    @State private var joinCode = ""
    @State private var working = false
    @State private var error: String?
    @AppStorage("cascade.wf.guestAdds") private var guestAdds = true
    @AppStorage("cascade.wf.guestControl") private var guestControl = false
    @AppStorage("cascade.wf.relay") private var relay = ""

    var body: some View {
        Form {
            if let session = state.waterfall, session.isActive {
                live(session)
            } else {
                idle
            }
            Section {
                Toggle("Guests Can Add Songs", isOn: $guestAdds)
                Toggle("Guests Can Control Playback", isOn: $guestControl)
            } header: {
                Text("When You Host")
            } footer: {
                Text("Adding is harmless; letting guests pause, skip and seek interrupts everyone.")
            }
            .onChange(of: guestAdds) { _, _ in pushPermissions() }
            .onChange(of: guestControl) { _, _ in pushPermissions() }
            Section {
                TextField(Waterfall.defaultRelay, text: $relay)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
            } header: {
                Text("Relay")
            } footer: {
                Text("Rooms pass through this relay, which only ever carries the room's small control messages, never audio. Leave it empty for Cascade's own; the desktop's signaling folder deploys your own.")
            }
        }
        .navigationTitle("Waterfall")
    }

    private var idle: some View {
        Section {
            Button("Start a Room") { run { try await $0.create(relayBase: relay, name: name,
                                                                 allowGuestAdds: guestAdds, allowGuestControl: guestControl) } }
            HStack {
                TextField("Room Code", text: $joinCode)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                Button("Join") { run { try await $0.join(code: joinCode, relayBase: relay, name: name) } }
                    .disabled(Waterfall.normalizedCode(joinCode) == nil)
            }
            if working { ProgressView() }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Everyone streams the same songs from this server with their own account, and the host's playback leads. Everyone in a room must use the same Jellyfin server.")
                if let error { Text(error).foregroundStyle(.red) }
            }
        }
        .disabled(working)
    }

    @ViewBuilder
    private func live(_ session: WaterfallSession) -> some View {
        Section {
            LabeledContent("Room Code") {
                Text(session.code ?? "").font(.title2.monospaced().bold())
            }
            #if os(iOS)
            if let code = session.code {
                ShareLink("Share Code", item: "Join my Cascade Waterfall room: \(code)")
            }
            #elseif os(macOS)
            if let code = session.code {
                Button("Copy Code", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
            }
            #endif
            Button("Leave Room", role: .destructive) { session.leave() }
        } footer: {
            Text(session.role == .host
                 ? "You are hosting. Everyone follows your playback."
                 : session.guestControlAllowed
                    ? "Following the host. Your play, skip and seek go to the host."
                    : "Following the host, who controls playback.")
        }
        Section("Listening") {
            ForEach(session.roster) { member in
                HStack {
                    Text(member.name)
                    if member.id == session.memberId { Text("(you)").foregroundStyle(.secondary) }
                }
            }
        }
    }

    private var name: String { state.username ?? "Listener" }

    private func pushPermissions() {
        state.waterfall?.setGuestPermissions(adds: guestAdds, control: guestControl)
    }

    private func run(_ action: @escaping (WaterfallSession) async throws -> Void) {
        guard let session = state.waterfall else { return }
        working = true
        error = nil
        Task {
            do { try await action(session) } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}
