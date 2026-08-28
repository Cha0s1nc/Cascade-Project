import SwiftUI
import CascadeKit

@main
struct CascadeApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.isSignedIn {
            MainView()
        } else {
            // Wrapped so the title renders. MainView brings its own stack per
            // tab, so this one is only for sign in.
            NavigationStack { SignInView() }
        }
    }
}
