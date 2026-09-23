import SwiftUI
import CascadeKit

struct SignInView: View {
    @Environment(AppState.self) private var state
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false

    /// Whether the typed server offers QuickConnect, checked as the address
    /// changes. The password form stays either way.
    @State private var quickConnectAvailable = false
    /// The code on screen while a QuickConnect request is waiting for approval.
    @State private var quickConnectCode: String?
    @State private var quickConnectTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section("Server") {
                TextField("https://jellyfin.example.com", text: $server)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    #if os(iOS)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    #endif
            }

            if let code = quickConnectCode {
                Section("Quick Connect") {
                    Text(code)
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Quick Connect code \(code.map(String.init).joined(separator: " "))")
                    Text("Enter this code in Jellyfin on a device where you're already signed in: your profile, then Quick Connect.")
                        .font(.footnote)
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

            Section("Account") {
                TextField("Username", text: $username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("Password", text: $password)
            }
            if let error {
                // Shown, not swallowed. A sign-in that fails quietly is
                // indistinguishable from one that worked.
                Text(error).foregroundStyle(.red)
            }
            Button(busy ? "Signing in..." : "Sign in", action: submit)
                .disabled(busy || server.isEmpty || username.isEmpty)
        }
        .navigationTitle("Cascade")
        // Re-checked as the address is typed; .task(id:) cancels the previous
        // check, which is the debounce.
        .task(id: server) {
            quickConnectAvailable = false
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, !server.isEmpty else { return }
            let available = await QuickConnect.isEnabled(serverUrl: server)
            if !Task.isCancelled { quickConnectAvailable = available }
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

    private func submit() {
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
