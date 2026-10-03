import SwiftUI
import CascadeKit

// Owner: integrations agent (I1). Stub from the contract in apple/MAC-MAP.md; replace freely.
/// Discord status, embedded by Settings > Integrations.
struct DiscordSettingsSection: View {
    var body: some View { EmptyView() }
}

/// Starts the Mac-only integrations (Discord, control server, Touch Bar,
/// debug panel) once the app has its state.
@MainActor
enum MacIntegrations {
    static func start(state: AppState) {}
}
