import SwiftUI
import CascadeKit

/// The metadata editor window (metadata-editor.html): eight fields, admin
/// only. Fetches the whole item and sends the whole item back with those
/// fields changed, since POST /Items/{id} blanks whatever it is not sent.
struct MetadataEditorView: View {
    let itemId: String
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var original: RawItem?
    @State private var fields = MetadataFields()
    @State private var loadError: String?
    @State private var status: (text: String, failed: Bool)?
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !state.isAdmin {
                // Re-checked in save() too: this only explains.
                Text("This Jellyfin account is not an administrator. The server only lets admins edit metadata, so saving would be refused.")
                    .foregroundStyle(.red).padding()
            }
            if let loadError {
                Text("Could not load this item: \(loadError)").foregroundStyle(.secondary).padding().frame(maxHeight: .infinity)
            } else if original == nil {
                ProgressView().frame(maxHeight: .infinity)
            } else {
                form
            }
            Divider()
            HStack {
                if let status { Text(status.text).foregroundStyle(status.failed ? .red : .green) }
                Spacer()
                Button("Cancel") { dismiss() }
                Button(saving ? "Saving\u{2026}" : "Save to Jellyfin") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(original == nil || saving || !state.isAdmin)
            }
            .padding(12)
        }
        .frame(minWidth: 460, minHeight: 440)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ArtworkView(itemId: itemId, size: 44)
            VStack(alignment: .leading) {
                Text(fields.name.isEmpty ? "Loading\u{2026}" : fields.name).font(.headline).lineLimit(1)
                Text([fields.albumArtist, fields.album].filter { !$0.isEmpty }.joined(separator: " - "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(14)
    }

    private var form: some View {
        Form {
            TextField("Name", text: $fields.name)
            TextField("Album", text: $fields.album)
            TextField("Album artist", text: $fields.albumArtist)
            TextField("Artists (comma-separated)", text: $fields.artists)
            TextField("Genres (comma-separated)", text: $fields.genres)
            TextField("Year", text: $fields.year)
            TextField("Track #", text: $fields.track)
            TextField("Disc #", text: $fields.disc)
        }
        .formStyle(.grouped)
    }

    private func load() async {
        guard let client = state.client else { return }
        do {
            let raw = try await client.fullItem(itemId: itemId)
            original = raw
            fields = MetadataEdit.fields(from: try raw.object())
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save() async {
        // The second gate: a dimmed menu item or button can still be triggered.
        guard state.isAdmin, let client = state.client, let original else { return }
        saving = true
        defer { saving = false }
        do {
            let edited = try RawItem(object: try MetadataEdit.apply(fields, to: try original.object()))
            try await client.updateItem(itemId: itemId, item: edited)
            self.original = edited
            status = ("Saved", false)
            // Lists and Home re-read, so the new name shows everywhere.
            state.libraryMutated()
        } catch {
            status = ("Failed: \(error.localizedDescription)", true)
        }
    }
}

/// Waterfall relay URL and guest permissions, embedded by Settings >
/// Integrations. Same keys as the room screen (WaterfallView), so the two
/// always agree.
struct WaterfallSettingsSection: View {
    @Environment(AppState.self) private var state
    @AppStorage("cascade.wf.relay") private var relay = ""
    @AppStorage("cascade.wf.guestAdds") private var guestAdds = true
    @AppStorage("cascade.wf.guestControl") private var guestControl = false

    var body: some View {
        Section {
            TextField("Relay server", text: $relay, prompt: Text(Waterfall.defaultRelay))
                .autocorrectionDisabled()
                // As the desktop saves it: no trailing slashes.
                .onSubmit { relay = relay.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/+$", with: "", options: .regularExpression) }
            Toggle("Guests can add to the queue", isOn: $guestAdds)
            Toggle("Guests can control playback", isOn: $guestControl)
        } header: {
            Text("Waterfall")
        } footer: {
            Text("The relay handles room codes and keeps listeners in sync, and only carries small control messages, never audio. Leave it empty for the default. Letting guests control playback means anyone in your room can interrupt everyone else.")
        }
        .onChange(of: guestAdds) { state.waterfall?.setGuestPermissions(adds: guestAdds, control: guestControl) }
        .onChange(of: guestControl) { state.waterfall?.setGuestPermissions(adds: guestAdds, control: guestControl) }
    }
}
