import SwiftUI
import CascadeKit

@main
struct CascadeApp: App {
    @State private var state = AppState()

    init() {
        // Artwork loads through AsyncImage on URLSession.shared. Jellyfin marks
        // images cache-control: public, but the default cache holds only a
        // few megabytes, so scrolling back up re-downloaded every cover.
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
    }

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
