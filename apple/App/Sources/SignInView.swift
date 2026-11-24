import SwiftUI
import CascadeKit

struct SignInView: View {
    @Environment(AppState.self) private var state
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false
    /// Return in the username moves to the password, as every sign-in form does.
    @FocusState private var passwordFocused: Bool

    /// Whether the typed server offers QuickConnect, checked as the address
    /// changes. The password form stays either way.
    @State private var quickConnectAvailable = false
    /// The code on screen while a QuickConnect request is waiting for approval.
    @State private var quickConnectCode: String?
    @State private var quickConnectTask: Task<Void, Never>?
    /// The server's login disclaimer (Branding), as Jellyfin's own sign-in page shows it.
    @State private var disclaimer = ""
    /// The reverse proxy headers and client certificate, open when any are saved.
    @State private var showsAdvanced: Bool = {
        if !ProxyConnection.shared.currentHeaders.isEmpty { return true }
        #if os(macOS)
        return ClientIdentity.chosen != nil
        #elseif os(iOS)
        return ClientIdentity.summary() != nil
        #else
        return false
        #endif
    }()

    #if os(macOS)
    /// The Mac signs in with Quick Connect when the server offers it, a password when asked.
    @State private var usePassword = false
    /// What the typed address answered: "Found it" under the field, or nothing there.
    @State private var probe: Probe?
    @FocusState private var focus: Field?
    private enum Field { case server, username, password }
    private enum Probe { case found(String), missing }
    #endif

    var body: some View {
        content
            // Re-checked as the address is typed; .task(id:) cancels the previous
            // check, which is the debounce.
            .task(id: server) {
                ProxyConnection.shared.setServer(server)
                quickConnectAvailable = false
                #if os(macOS)
                probe = nil
                #endif
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, !server.isEmpty else { disclaimer = ""; return }
                async let text = ServerMessage.fetchLoginDisclaimer(serverURL: server)
                #if os(macOS)
                async let info = Self.serverSummary(server)
                #endif
                let available = await QuickConnect.isEnabled(serverUrl: server)
                let said = await text
                #if os(macOS)
                let found = await info
                #endif
                if !Task.isCancelled {
                    quickConnectAvailable = available
                    disclaimer = said
                    #if os(macOS)
                    probe = found.map(Probe.found) ?? .missing
                    #endif
                }
            }
            .onDisappear { quickConnectTask?.cancel() }
            .onAppear {
                // Sign-out keeps the server address, so signing back in starts
                // from it instead of an empty field.
                if server.isEmpty, let saved = UserDefaults.standard.string(forKey: "cascade.serverUrl") {
                    server = saved
                }
                #if DEBUG
                // ponytail: test hook for driving sign-in with no UI automation
                // (simulators, tvOS): launch with `-cascade.autoQuickConnect YES`.
                // Debug builds only.
                if UserDefaults.standard.bool(forKey: "cascade.autoQuickConnect"), !server.isEmpty {
                    startQuickConnect()
                }
                #endif
            }
    }

    @ViewBuilder private var content: some View {
        #if os(macOS)
        macLayout
        #else
        form.navigationTitle("Cascade")
        #endif
    }

    #if !os(macOS)
    private var form: some View {
        Form {
            Section("Server") {
                TextField("https://jellyfin.example.com", text: $server)
                    .autocorrectionDisabled()
                    .noAutocaps()
                    #if os(iOS)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    #endif
            }

            // Before the first request goes out: a proxy that wants a header
            // refuses the sign-in itself without it. Tucked away, as on the
            // desktop, unless something is already saved.
            Section {
                Button { withAnimation { showsAdvanced.toggle() } } label: {
                    HStack {
                        Text("Advanced")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(showsAdvanced ? 90 : 0))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                #if !os(tvOS)
                .buttonStyle(.plain)
                #endif
                .accessibilityValue(showsAdvanced ? "Expanded" : "Collapsed")
            }
            if showsAdvanced { ProxySettingsSection() }

            if let code = quickConnectCode {
                Section("Quick Connect") {
                    Text(code)
                        .font(.system(size: codeSize, weight: .bold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Quick Connect code \(code.map(String.init).joined(separator: " "))")
                    Text("Enter this code in Jellyfin on a device where you're already signed in: your profile, then Quick Connect.")
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Cancel", role: .cancel, action: cancelQuickConnect)
                }
            } else if quickConnectAvailable {
                Section {
                    Button("Sign in with Quick Connect", action: startQuickConnect)
                        .disabled(busy)
                } footer: {
                    Text("No password needed: approve a code from another device.")
                }
            }

            Section("Account") { accountFields }
            if let error {
                // Shown, not swallowed. A sign-in that fails quietly is
                // indistinguishable from one that worked.
                Text(error).foregroundStyle(.red)
            }
            Button(busy ? "Signing In\u{2026}" : "Sign In", action: submit)
                .disabled(busy || server.isEmpty || username.isEmpty)
            if !disclaimer.isEmpty {
                Section {
                    Text(disclaimer).scaledFont(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Content types, so Passwords and other managers offer the saved login.
    @ViewBuilder private var accountFields: some View {
        TextField("Username", text: $username)
            .autocorrectionDisabled()
            .noAutocaps()
            .textContentType(.username)
            .submitLabel(.next)
            .onSubmit { passwordFocused = true }
        SecureField("Password", text: $password)
            .textContentType(.password)
            .submitLabel(.go)
            .focused($passwordFocused)
            .onSubmit(submit)
    }

    /// Read from across the room on a TV, at arm's length on a phone.
    private var codeSize: CGFloat {
        #if os(tvOS)
        120
        #else
        44
        #endif
    }
    #endif

    #if os(macOS)
    /// Personality v1's "Mac / Sign in" board: the falling art down the left, the welcome and
    /// the form on the right. Quick Connect is the way in when the server offers it, with a
    /// password behind a link; Advanced (proxy headers, client certificate) is tucked under.
    private var macLayout: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if geo.size.width >= 760 {
                    SignInArt().frame(width: min(480, max(360, geo.size.width * 0.4)))
                }
                ScrollView {
                    macForm
                        .frame(maxWidth: 400, alignment: .leading)
                        .padding(.horizontal, 56).padding(.vertical, 48)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
            }
        }
        .background(Cx.bg)
        // The art runs up under the title bar, as the board's traffic lights sit on it.
        .ignoresSafeArea()
        .frame(minWidth: 520, minHeight: 560)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .defaultFocus($focus, .server)
    }

    private var macForm: some View {
        let quickConnect = quickConnectAvailable && !usePassword
        return VStack(alignment: .leading, spacing: 0) {
            Text("Welcome to your Cascade").cx(.title).foregroundStyle(Cx.text)
            Text("Point it at your Jellyfin server. Everything you own, flowing from one place.")
                .cx(.voice).foregroundStyle(Cx.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            field("Server address", .server) {
                TextField("", text: $server, prompt: Text(verbatim: "https://jellyfin.example.com"))
                    .autocorrectionDisabled()
            }
            .padding(.top, 28)
            probeLine.padding(.top, 6)

            if quickConnect {
                quickConnectCard.padding(.top, 16)
            } else {
                field("Username", .username) {
                    TextField("", text: $username)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .onSubmit { focus = .password }
                }
                .padding(.top, 16)
                field("Password", .password) {
                    SecureField("", text: $password)
                        .textContentType(.password)
                        .onSubmit(submit)
                }
                .padding(.top, 12)
            }

            if let error {
                // Shown, not swallowed. A sign-in that fails quietly is
                // indistinguishable from one that worked.
                Text(error).cx(.small).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            HStack(spacing: 16) {
                if quickConnect {
                    if quickConnectCode == nil {
                        PillButton("Get a Code", primary: true, action: startQuickConnect)
                            .disabled(busy || server.isEmpty)
                    } else {
                        PillButton(busy ? "Signing In\u{2026}" : "Waiting for Approval", primary: true) {}
                            .disabled(true)
                    }
                } else {
                    PillButton(busy ? "Signing In\u{2026}" : "Sign In", primary: true, action: submit)
                        .disabled(busy || server.isEmpty || username.isEmpty)
                }
                if quickConnectAvailable {
                    SignInLink(quickConnect ? "Sign in with a password instead" : "Use Quick Connect instead") {
                        cancelQuickConnect()
                        usePassword.toggle()
                        focus = usePassword ? .username : nil
                    }
                }
            }
            .padding(.top, 18)

            SignInLink("Advanced", symbol: showsAdvanced ? "chevron.down" : "chevron.right", quiet: true) {
                withAnimation { showsAdvanced.toggle() }
            }
            .accessibilityValue(showsAdvanced ? "Expanded" : "Collapsed")
            .padding(.top, 18)
            if showsAdvanced {
                Form { ProxySettingsSection() }
                    .formStyle(CxFormStyle(scrolls: false))
                    .padding(.top, 10)
            }

            if !disclaimer.isEmpty {
                Text(disclaimer).cx(.small).foregroundStyle(Cx.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Cx.surface, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.top, 24)
            }
        }
    }

    /// A labeled input as the board draws it: the label over a field on surface 2, its
    /// outline in the accent while it has focus.
    private func field<Input: View>(_ label: String, _ which: Field, @ViewBuilder _ input: () -> Input) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).cx(.small).foregroundStyle(Cx.text2)
            input()
                .textFieldStyle(.plain)
                .font(.cxBody(13, .medium)).foregroundStyle(Cx.text)
                .focused($focus, equals: which)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Cx.surface2, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focus == which ? Cx.accent : Cx.line))
                .accessibilityLabel(label)
        }
    }

    @ViewBuilder private var probeLine: some View {
        switch probe {
        case .found(let summary):
            Label("Found it: \(summary)", systemImage: "server.rack")
                .cx(.small).foregroundStyle(Cx.accent)
        case .missing:
            Label("No Jellyfin server answers at that address yet", systemImage: "exclamationmark.circle")
                .cx(.small).foregroundStyle(Cx.text3)
        case nil:
            // Holds the line's height, so the form does not jump as the check comes back.
            Text(" ").cx(.small).accessibilityHidden(true)
        }
    }

    private var quickConnectCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Connect").cx(.caps).foregroundStyle(Cx.text3)
            if let code = quickConnectCode {
                Text(code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code)
                    .cx(.hero).foregroundStyle(Cx.text)
                    .textSelection(.enabled)
                    .accessibilityLabel("Quick Connect code \(code.map(String.init).joined(separator: " "))")
            }
            Text(quickConnectCode == nil
                 ? "Get a code, then approve it in Jellyfin on any signed in device: your profile, then Quick Connect. No password typed here."
                 : "Approve this code in Jellyfin on any signed in device: your profile, then Quick Connect. No password typed here.")
                .cx(.small).foregroundStyle(Cx.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Cx.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    /// The server's name and version from its public info, or nil when nothing answers.
    private static func serverSummary(_ server: String) async -> String? {
        struct Info: Decodable {
            let ServerName: String?
            let Version: String?
        }
        guard let url = URL(string: server.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/System/Info/Public"),
              url.scheme == "http" || url.scheme == "https" else { return nil }
        let request = URLRequest(url: url, timeoutInterval: 6)
        guard let (data, response) = try? await ProxyConnection.shared.session(for: url).data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let info = try? JSONDecoder().decode(Info.self, from: data) else { return nil }
        let version = info.Version.map { "Jellyfin \($0)" } ?? "Jellyfin"
        guard let name = info.ServerName, !name.isEmpty else { return version }
        return "\(name), \(version)"
    }
    #endif

    private func submit() {
        // Also reached from the return key, which the disabled button does not stop.
        guard !busy, !server.isEmpty, !username.isEmpty else { return }
        ProxyConnection.shared.setServer(server)
        busy = true
        error = nil
        Task {
            do {
                try await state.signIn(server: server, username: username, password: password)
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    private func startQuickConnect() {
        ProxyConnection.shared.setServer(server)
        error = nil
        let server = self.server
        quickConnectTask = Task {
            do {
                let start = try await QuickConnect.initiate(serverUrl: server, appVersion: state.appVersion,
                                                            deviceId: AppState.deviceId)
                quickConnectCode = start.code
                let deadline = ContinuousClock.now + QuickConnect.timeout
                while !Task.isCancelled {
                    if await QuickConnect.isApproved(serverUrl: server, secret: start.secret) {
                        busy = true
                        try await state.signIn(server: server, quickConnectSecret: start.secret)
                        break
                    }
                    if ContinuousClock.now >= deadline {
                        error = "The code expired. Start Quick Connect again."
                        break
                    }
                    try await Task.sleep(for: QuickConnect.pollInterval)
                }
            } catch is CancellationError {
                // Cancelled by the user or by leaving the screen: nothing to report.
            } catch {
                self.error = error.localizedDescription
            }
            quickConnectCode = nil
            busy = false
        }
    }

    private func cancelQuickConnect() {
        quickConnectTask?.cancel()
        quickConnectTask = nil
        quickConnectCode = nil
    }
}

#if os(macOS)
/// A quiet text button beside the sign-in's pill: text 2, text on hover.
private struct SignInLink: View {
    let title: String
    var symbol: String?
    var quiet = false
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, symbol: String? = nil, quiet: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.quiet = quiet
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            }
            .cx(.small)
            .foregroundStyle(hovering ? Cx.text : quiet ? Cx.text3 : Cx.text2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The board's art side: album-colored tiles falling down a blue wash, drawn at the board's
/// 420 by 640 and scaled to the panel.
private struct SignInArt: View {
    private struct Tile { let x, y, size: CGFloat; let from, to: UInt32; let opacity: Double }
    private static let tiles = [
        Tile(x: 60, y: 90, size: 150, from: 0x7CC4FF, to: 0x3D3A8C, opacity: 1),
        Tile(x: 170, y: 210, size: 120, from: 0x06D6A0, to: 0x118AB2, opacity: 0.75),
        Tile(x: 80, y: 330, size: 100, from: 0xFF8FAB, to: 0x6A4C93, opacity: 0.5),
        Tile(x: 190, y: 430, size: 80, from: 0xFFD166, to: 0xEF476F, opacity: 0.32),
        Tile(x: 110, y: 520, size: 62, from: 0xBFD8C2, to: 0x4B6B5A, opacity: 0.2),
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(Self.tiles.indices, id: \.self) { i in
                    let t = Self.tiles[i]
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(colors: [Color(dark: t.from, light: t.from), Color(dark: t.to, light: t.to)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: t.size, height: t.size)
                        .opacity(t.opacity)
                        .offset(x: t.x, y: t.y)
                }
            }
            .frame(width: 420, height: 640, alignment: .topLeading)
            .scaleEffect(min(geo.size.width / 420, geo.size.height / 640))
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background {
            LinearGradient(colors: [Color(dark: 0x1D3557, light: 0x1D3557), Cx.bg], startPoint: .top, endPoint: .bottom)
                .overlay(LinearGradient(colors: [Color(dark: 0x2B6CB0, light: 0x2B6CB0, darkOpacity: 0.55, lightOpacity: 0.55), .clear],
                                        startPoint: .top, endPoint: .bottom))
        }
        .clipped()
        .accessibilityHidden(true)
    }
}
#endif
