import SwiftUI
import CascadeKit

struct AlbumDetailView: View {
    let album: JfItem
    var body: some View { Text(album.name ?? "") }
}
