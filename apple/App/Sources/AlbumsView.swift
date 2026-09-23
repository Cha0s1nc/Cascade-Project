import SwiftUI
import CascadeKit

struct AlbumsView: View {
    @Environment(AppState.self) private var state
    @State private var items: [JfItem] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            LoadingOverlay(isLoading: isLoading, error: error, isEmpty: items.isEmpty)
            ItemGrid(items: items)
        }
        .navigationTitle("Albums")
        // Keyed on the library selection, so changing it in Settings reloads.
        .task(id: state.config?.libraryIds) {
            guard let client = state.client else { return }
            isLoading = true
            error = nil
            do {
                try await loadPaged(fetch: { try await client.albums(limit: $0, startIndex: $1) }) {
                    items = $0
                    isLoading = false
                }
            } catch { self.error = error.localizedDescription }
            isLoading = false
        }
    }
}
