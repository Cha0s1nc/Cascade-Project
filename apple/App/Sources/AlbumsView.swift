import SwiftUI
import CascadeKit

struct AlbumsView: View {
    @Environment(AppState.self) private var state
    @State private var items: [JfItem] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var selected: JfItem?
    @State private var showDetail = false

    var body: some View {
        ScrollView {
            LoadingOverlay(isLoading: isLoading, error: error, isEmpty: items.isEmpty)
            ItemGrid(items: items) { selected = $0; showDetail = true }
        }
        .navigationTitle("Albums")
        // JfItem is not Hashable, so navigationDestination(item:) is out;
        // isPresented only needs the Bool.
        .navigationDestination(isPresented: $showDetail) {
            if let selected { AlbumDetailView(album: selected) }
        }
        .task {
            guard let client = state.client else { return }
            do { items = try await client.albums() }
            catch { self.error = error.localizedDescription }
            isLoading = false
        }
    }
}
