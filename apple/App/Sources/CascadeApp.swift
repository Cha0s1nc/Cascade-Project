import SwiftUI
import CascadeKit

@main
struct CascadeApp: App {
    @State private var state = AppState()
    #if os(iOS)
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor private var appDelegate: MacAppDelegate
    #endif

    init() {
        // Artwork loads through AsyncImage on URLSession.shared. Jellyfin marks
        // images cache-control: public, but the default cache holds only a
        // few megabytes, so scrolling back up re-downloaded every cover.
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup(id: "main") {
            RootView()
                .environment(state)
                .onAppear { MacIntegrations.start(state: state) }
        }
        .defaultSize(width: 1100, height: 700)
        .commands { PlaybackCommands(state: state) }

        Window("Miniplayer", id: "miniplayer") {
            MiniplayerView().environment(state)
        }
        WindowGroup("Lyrics Editor", id: "lyrics-editor", for: String.self) { $itemId in
            if let itemId { LyricsEditorView(itemId: itemId).environment(state) }
        }
        WindowGroup("Metadata Editor", id: "metadata-editor", for: String.self) { $itemId in
            if let itemId { MetadataEditorView(itemId: itemId).environment(state) }
        }
        Window("Update Available", id: "update") {
            UpdateAvailableView().environment(state)
        }
        Settings {
            MacSettingsView().environment(state)
        }
        #else
        WindowGroup {
            RootView()
                .environment(state)
        }
        #endif
    }
}

#if os(macOS)
/// Closing the main window quits, as the Electron build does.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif

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
            #if os(macOS)
            MacRootView()
            #else
            MainView()
            #endif
        } else {
            // Wrapped so the title renders. MainView brings its own stack per
            // tab, so this one is only for sign in.
            NavigationStack { SignInView() }
        }
    }
}
