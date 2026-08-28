import SwiftUI
import CascadeKit

struct NowPlayingView: View {
    let player: PlaybackService
    var body: some View { Text(player.item?.name ?? "Nothing playing") }
}
