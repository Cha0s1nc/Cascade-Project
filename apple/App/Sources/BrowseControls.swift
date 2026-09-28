import SwiftUI
import CascadeKit

// Controls the browsing screens share: the sort menu, and the key a screen
// reloads on.

/// Sort field, direction and (where the screen has one) a favorites filter,
/// behind one button.
///
/// Placed at the top of each screen's content rather than in the toolbar, on
/// both platforms: tvOS does not show toolbar items on these screens.
///
/// tvOS gets a dialog instead of a Menu. A Menu there takes focus but never
/// opened on select (tvOS 26.5 simulator, driven by the Siri Remote script),
/// while a confirmation dialog is a plain list of focusable buttons.
struct SortMenu<Field: Hashable>: View {
    let fields: [(Field, String)]
    @Binding var field: Field
    @Binding var direction: SortDirection
    var favoritesOnly: Binding<Bool>?
    #if os(tvOS)
    @State private var isChoosing = false
    #endif

    var body: some View {
        #if os(tvOS)
        Button { isChoosing = true } label: {
            Label(summary, systemImage: "arrow.up.arrow.down")
        }
        .confirmationDialog("Sort", isPresented: $isChoosing) {
            if fields.count > 1 {
                ForEach(fields, id: \.0) { option in
                    Button(option.0 == field ? "\(option.1) \u{2713}" : option.1) { field = option.0 }
                }
            }
            Button(direction == .ascending ? "Order: Ascending" : "Order: Descending") {
                direction = direction == .ascending ? .descending : .ascending
            }
            if let favoritesOnly {
                Button(favoritesOnly.wrappedValue ? "Favorites Only: On" : "Favorites Only: Off") {
                    favoritesOnly.wrappedValue.toggle()
                }
            }
        }
        #else
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
        #endif
    }

    private var summary: String {
        let name = fields.first { $0.0 == field }?.1 ?? "Sort"
        return favoritesOnly?.wrappedValue == true ? "\(name), Favorites" : name
    }
}

/// Everything a browsing screen's list depends on. The screen's `.task(id:)`
/// is keyed on this, so changing the library selection, the sort or the filter
/// cancels a load still paging in and starts over.
struct BrowseKey: Hashable {
    var libraries: [String]?
    var sort: String
    var direction: SortDirection
    var favoritesOnly = false
    /// Bumped to reload after a write the screen made itself.
    var generation = 0
}

/// The browse screens whose lists AppState keeps; see AppState.browseList.
enum BrowseScreen: Hashable { case albums, artists, songs, playlists }

/// One browse screen's list as AppState loads it. Observable, so a screen
/// showing it updates as pages arrive, including the ones that arrived while
/// it was off screen.
@MainActor @Observable
final class BrowseList {
    var items: [JfItem] = []
    var isLoading = true
    var error: String?
    /// Every page is in, not just the ones so far.
    var isComplete = false
    @ObservationIgnored var task: Task<Void, Never>?
}

struct BrowseCacheKey: Hashable {
    let screen: BrowseScreen
    let key: BrowseKey
}

/// Plays a list shuffled, the way the player's own shuffle does it: a random
/// first track, then shuffle turned on around it. Playing index 0 and then
/// shuffling always started on the list's first song.
@MainActor
func playShuffled(_ items: [JfItem], on player: PlaybackService?) async {
    guard let player, !items.isEmpty else { return }
    await player.play(items, startIndex: Int.random(in: items.indices))
    player.toggleShuffle()
}

extension View {
    /// The row of controls above a browsing screen's list. On tvOS it is a
    /// focus section: its button sits at the left edge, and moving up from
    /// the grid only looks straight up, so without this focus skipped the
    /// row and landed on the tab bar.
    @ViewBuilder
    func browseHeader() -> some View {
        #if os(tvOS)
        focusSection()
        #else
        self
        #endif
    }
}

extension View {
    /// The alert every write failure shows. A refused write must never look
    /// like a saved one (CODEMAP rule 1), so the server's reason is shown.
    func writeErrorAlert(_ message: Binding<String?>) -> some View {
        alert("Could not save", isPresented: Binding(get: { message.wrappedValue != nil },
                                                     set: { if !$0 { message.wrappedValue = nil } })) {
            Button("OK") {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
