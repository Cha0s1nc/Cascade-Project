import Foundation

/// One browsing screen's sort and filter, persisted as `cascade.<view>Prefs`
/// in the desktop's shape (src/core/library-browse.ts LibraryPrefs): a JSON
/// object with field, dir ("asc" or "desc"), favorite, genre (a name), decade
/// and played ("played", "unplayed" or null). Keeping the shape means the
/// settings import is a straight copy and a value written by either app reads
/// in the other.
///
/// The field is held as the string it is stored as, because which fields are
/// allowed is each screen's own list; `sortField(default:)` reads it as the
/// screen's enum and falls back for one the screen does not offer.
public struct LibraryPrefs: Hashable, Sendable {
    public var field = "name"
    public var direction = SortDirection.ascending
    public var filter = BrowseFilter()

    public init(field: String = "name", direction: SortDirection = .ascending, filter: BrowseFilter = .init()) {
        self.field = field
        self.direction = direction
        self.filter = filter
    }

    /// The stored text, back into prefs. The store is untrusted: bad JSON, a
    /// non-object, a direction that is not asc or desc, a non-numeric decade
    /// or an unknown played value each fall back to the default for that one
    /// part rather than reaching a query as garbage. Nil when nothing usable
    /// was stored at all.
    public init?(stored raw: String?) {
        guard let data = raw?.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var prefs = LibraryPrefs()
        if let field = object["field"] as? String, !field.isEmpty { prefs.field = field }
        prefs.direction = (object["dir"] as? String) == "desc" ? .descending : .ascending
        prefs.filter.favoritesOnly = (object["favorite"] as? Bool) == true
        // "|" separates the filter's own stored form, and no real genre has one.
        if let genre = object["genre"] as? String, !genre.isEmpty, !genre.contains("|") { prefs.filter.genre = genre }
        // A JSON number, not a numeric string, as the desktop checks it.
        if let decade = object["decade"] as? NSNumber, CFGetTypeID(decade) != CFBooleanGetTypeID(),
           decade.doubleValue.isFinite {
            prefs.filter.decade = decade.intValue
        }
        switch object["played"] as? String {
        case "played": prefs.filter.played = .played
        case "unplayed": prefs.filter.played = .unplayed
        default: break
        }
        self = prefs
    }

    /// The desktop's JSON, with nulls where it has them.
    public var stored: String {
        let object: [String: Any] = [
            "field": field,
            "dir": direction == .descending ? "desc" : "asc",
            "favorite": filter.favoritesOnly,
            "genre": filter.genre ?? NSNull(),
            "decade": filter.decade ?? NSNull(),
            "played": filter.played == .any ? NSNull() : filter.played.rawValue,
        ]
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// The field as a screen's own enum, or `fallback` when what is stored is
    /// not one the screen offers.
    public func sortField<F: RawRepresentable>(default fallback: F) -> F where F.RawValue == String {
        F(rawValue: field) ?? fallback
    }
}

/// So a screen can hold its prefs in `@AppStorage("cascade.albumsPrefs")`.
extension LibraryPrefs: RawRepresentable {
    public init?(rawValue: String) { self.init(stored: rawValue) }
    public var rawValue: String { stored }
}

public enum ArtistSortField: String, Sendable, CaseIterable {
    case name, added

    public var serverSortBy: String { self == .added ? "DateCreated,SortName" : "SortName" }
    public var defaultDirection: SortDirection { self == .added ? .descending : .ascending }
}
