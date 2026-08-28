import SwiftUI
import CascadeKit

struct SignInView: View {
    @Environment(AppState.self) private var state
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false

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
}
