import SwiftUI
import CascadeKit

struct ArtistsView: View {
    @Environment(AppState.self) private var state
    @State private var items: [JfItem] = []
    @State private var isLoading = true
    @State private var error: String?
    @AppStorage("cascade.artists.order") private var sortDirection: SortDirection = .ascending
    @AppStorage("cascade.artists.favorites") private var favoritesOnly = false

    var body: some View {
        ScrollView {
            HStack {
                // Name is the only order the album artists route is worth
                // sorting by, so this is direction and the filter.
                SortMenu(fields: [("name", "Name")], field: .constant("name"),
                         direction: $sortDirection, favoritesOnly: $favoritesOnly)
                Spacer()
            }
            .padding(.horizontal)
            LoadingOverlay(isLoading: isLoading, error: error, isEmpty: items.isEmpty)
            ItemGrid(items: items)
        }
        .navigationTitle("Artists")
        // Keyed on the library selection and the sort, so changing either reloads.
        .task(id: BrowseKey(libraries: state.config?.libraryIds, sort: "SortName",
                            direction: sortDirection, favoritesOnly: favoritesOnly)) {
            guard let client = state.client else { return }
            isLoading = true
            error = nil
            items = []
            let (order, favorites) = (sortDirection.serverValue, favoritesOnly)
            do {
                try await loadPaged(sortBy: "SortName", sortOrder: order, fetch: {
                    try await client.artists(limit: $0, startIndex: $1, sortOrder: order, favoritesOnly: favorites)
                }) {
                    items = $0
                    isLoading = false
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            if !Task.isCancelled { isLoading = false }
        }
    }
}
