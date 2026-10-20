import SwiftUI
import CascadeKit
#if !os(tvOS)
import UniformTypeIdentifiers
#endif

/// Where the reverse proxy headers are kept: the keychain, not UserDefaults,
/// since a Cloudflare Access service token is a credential. Never the password.
enum ProxyHeaderStore {
    private static let account = "proxyHeaders"

    static func load() -> [ProxyHeader] {
        guard let text = Keychain.get(account), let data = text.data(using: .utf8),
              let list = try? JSONDecoder().decode([ProxyHeader].self, from: data) else { return [] }
        return ProxyHeaders.sanitized(list)
    }

    /// Saves, and applies them to every connection from the next request on.
    static func save(_ list: [ProxyHeader]) {
        let clean = ProxyHeaders.sanitized(list)
        if clean.isEmpty {
            Keychain.remove(account)
        } else if let data = try? JSONEncoder().encode(clean), let text = String(data: data, encoding: .utf8) {
            Keychain.set(text, for: account)
        }
        ProxyConnection.shared.setHeaders(clean)
    }
}

/// Headers (and on iOS and the Mac a client certificate) for a Jellyfin server behind
/// Cloudflare Access, Authelia or an mTLS proxy. Used on the sign-in screen,
/// where the proxy would otherwise refuse the sign-in itself, and in Settings.
struct ProxySettingsSection: View {
    @State private var headers = ProxyConnection.shared.currentHeaders
    @State private var name = ""
    @State private var value = ""
    @State private var problem: String?

    #if !os(tvOS)
    @State private var importing = false
    @State private var pickedFile: Data?
    @State private var askingPassphrase = false
    @State private var passphrase = ""
    @State private var certificateProblem: String?
    #endif
    #if os(iOS)
    @State private var certificate = ClientIdentity.summary()
    #elseif os(macOS)
    @State private var choices: [ClientIdentity.Choice] = []
    @State private var chosen = ClientIdentity.chosen
    #endif

    var body: some View {
        section
        #if !os(tvOS)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pkcs12], onCompletion: picked)
            .alert("Certificate Passphrase", isPresented: $askingPassphrase) {
                SecureField("Passphrase", text: $passphrase)
                Button("Import", action: importPicked)
                Button("Cancel", role: .cancel) { pickedFile = nil; passphrase = "" }
            } message: {
                Text("The passphrase that protects the certificate file.")
            }
        #endif
    }

    private var section: some View {
        Section {
            ForEach(headers, id: \.name) { header in
                // The value stays hidden: it is usually a secret.
                LabeledContent(header.name, value: "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}")
            }
            .onDelete(perform: remove)
            TextField("Header name", text: $name)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            SecureField("Header value", text: $value)
            Button("Add Header", action: add)
                .disabled(name.isEmpty || value.isEmpty)
            if let problem {
                Text(problem).foregroundStyle(.red)
            }
            #if !os(tvOS)
            clientCertificateRows
            #endif
        } header: {
            Text("Reverse Proxy")
        } footer: {
            Text("For a server behind Cloudflare Access, Authelia or similar: headers are sent only to your server, never to anyone else. Authorization and Host cannot be set. Saved in the keychain.")
        }
    }

    private func add() {
        let header = ProxyHeader(name: name.trimmingCharacters(in: .whitespaces),
                                 value: value.trimmingCharacters(in: .whitespaces))
        if let p = ProxyHeaders.problem(adding: header, to: headers) { problem = p; return }
        problem = nil
        headers.append(header)
        ProxyHeaderStore.save(headers)
        name = ""
        value = ""
    }

    private func remove(at offsets: IndexSet) {
        headers.remove(atOffsets: offsets)
        ProxyHeaderStore.save(headers)
    }

    #if os(macOS)
    /// Any identity in the keychains, or a .p12 or .pfx imported into the login
    /// keychain, offered when the server asks for a client certificate.
    @ViewBuilder private var clientCertificateRows: some View {
        Picker("Client Certificate", selection: $chosen) {
            Text("None").tag(String?.none)
            ForEach(choices) { choice in
                Text(choice.issuer.map { "\(choice.name) (\($0))" } ?? choice.name).tag(Optional(choice.id))
            }
            // A remembered one that left the keychain (or expired) stays visible.
            if let chosen, !choices.contains(where: { $0.id == chosen }) {
                Text("Not in the keychain").tag(Optional(chosen))
            }
        }
        .onAppear { choices = ClientIdentity.available() }
        .onChange(of: chosen) { _, id in
            if id != ClientIdentity.chosen { ClientIdentity.choose(id) }
        }
        Button("Import Certificate File\u{2026}") { importing = true }
        if let certificateProblem {
            Text(certificateProblem).foregroundStyle(.red)
        }
    }
    #elseif os(iOS)
    /// A .p12 or .pfx the person picks, kept in the keychain and offered when
    /// the server asks for a client certificate.
    @ViewBuilder private var clientCertificateRows: some View {
        if let certificate {
            LabeledContent("Client Certificate", value: certificate)
            Button("Remove Certificate", role: .destructive) {
                ClientIdentity.remove()
                self.certificate = nil
            }
        } else {
            Button("Import Client Certificate\u{2026}") { importing = true }
        }
        if let certificateProblem {
            Text(certificateProblem).foregroundStyle(.red)
        }
    }
    #endif

    #if !os(tvOS)
    private func picked(_ result: Result<URL, Error>) {
        certificateProblem = nil
        switch result {
        case .success(let url):
            // Files outside the app need their scope opened to be read.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                certificateProblem = "Could not read that file."
                return
            }
            pickedFile = data
            passphrase = ""
            askingPassphrase = true
        case .failure(let error):
            certificateProblem = error.localizedDescription
        }
    }

    private func importPicked() {
        guard let data = pickedFile else { return }
        do {
            try ClientIdentity.save(p12: data, passphrase: passphrase)
            #if os(iOS)
            certificate = ClientIdentity.summary()
            #else
            choices = ClientIdentity.available()
            chosen = ClientIdentity.chosen
            #endif
        } catch {
            certificateProblem = error.localizedDescription
        }
        pickedFile = nil
        passphrase = ""
    }
    #endif
}
