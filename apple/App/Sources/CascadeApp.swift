import SwiftUI
import CascadeKit

@main
struct CascadeApp: App {
    @State private var state = AppState()
    #if os(iOS)
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    #endif

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

#if os(iOS)
/// Only here for background downloads: iOS relaunches the app to hand over
/// finished ones and wants to hear when they have all been taken in.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == OfflineLibrary.sessionIdentifier else { return completionHandler() }
        OfflineLibrary.handBackgroundCompletion(completionHandler)
    }
}
#endif

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
