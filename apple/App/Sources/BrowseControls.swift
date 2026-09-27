import SwiftUI
import CascadeKit

// Controls the browsing screens share: the sort menu, and the key a screen
// reloads on.

/// Sort field, direction and (where the screen has one) a favorites filter,
/// behind one button.
///
/// Placed at the top of each screen's content rather than in the toolbar, on
/// both platforms: tvOS does not show toolbar items on these screens, and a
/// Menu in the content is an ordinary focus target there.
struct SortMenu<Field: Hashable>: View {
    let fields: [(Field, String)]
    @Binding var field: Field
    @Binding var direction: SortDirection
    var favoritesOnly: Binding<Bool>?

    var body: some View {
        Menu {
            // One field (Artists) needs no picker, only the direction.
            if fields.count > 1 {
                Picker("Sort By", selection: $field) {
                    ForEach(fields, id: \.0) { Text($0.1).tag($0.0) }
                }
            }
            Picker("Order", selection: $direction) {
                Text("Ascending").tag(SortDirection.ascending)
                Text("Descending").tag(SortDirection.descending)
            }
            if let favoritesOnly {
                Toggle("Favorites Only", isOn: favoritesOnly)
            }
        } label: {
            Label(summary, systemImage: "arrow.up.arrow.down")
        }
    }

    private var summary: String {
        let name = fields.first { $0.0 == field }?.1 ?? "Sort"
        return favoritesOnly?.wrappedValue == true ? "\(name), Favorites" : name
    }
}

/// Everything a browsing screen's list depends on. The screen's `.task(id:)`
/// is keyed on this, so changing the library selection, the sort or the filter
/// cancels a load still paging in and starts over.
struct BrowseKey: Equatable {
    var libraries: [String]?
    var sort: String
    var direction: SortDirection
    var favoritesOnly = false
}
