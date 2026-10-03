import SwiftUI
import CascadeKit

// Owner: video agent (V). Stub from the contract in apple/MAC-MAP.md; replace freely.
/// Plays AppState.videoSession over the whole window while it is set.
struct MacVideoHost: View {
    @Environment(AppState.self) private var state
    var body: some View {
        if let session = state.videoSession {
            VideoScreen(session: session)
                .background(.black)
        }
    }
}
