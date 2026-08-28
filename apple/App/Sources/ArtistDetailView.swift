import SwiftUI
import CascadeKit

struct ArtistDetailView: View {
    let artist: JfItem
    var body: some View { Text(artist.name ?? "") }
}
