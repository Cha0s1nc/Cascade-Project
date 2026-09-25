import Foundation

// The same song, album or artist found in more than one library, shown once.
//
// Ported from the desktop's dedupeById (src/core/jellyfin.ts) with its tests,
// so the two apps agree on what counts as a copy. Shuffling three libraries
// that each hold the same album otherwise plays every song three times.

/// Two copies of a song this far apart in length are different cuts (a live
/// version, an extended mix) rather than the same recording.
public let duplicateDurationSeconds = 3.0

/// Merges items that came from different libraries (`sourceLibrary`, set by
/// `itemsAcrossLibraries`), keeping list order: a merged item takes the place
/// its first copy held.
///
/// - Songs match on title and first artist, ignoring case and punctuation, with
///   durations within `duplicateDurationSeconds`. The highest bitrate wins.
/// - Albums match on name and album artist. The copy with the most tracks wins:
///   the same album can be whole in one library and one song in another.
/// - Artists match on name. Jellyfin 12 gives an artist a different id in every
///   library, so the id alone listed each one once per library.
///
/// Copies inside one library are never merged; that is the library's own
/// business, like a single kept next to its album. Items without a
/// `sourceLibrary` only merge by id.
public func mergeLibraryCopies(_ items: [JfItem]) -> [JfItem] {
    struct Copy { var library: Int; var seconds: Double?; var position: Int }
    var seenIds = Set<String>()
    var byContent: [String: [Copy]] = [:]
    var out: [JfItem] = []

    for item in items where seenIds.insert(item.id).inserted {
        guard let library = item.sourceLibrary, let key = contentKey(item) else {
            out.append(item)
            continue
        }
        let seconds = item.runTimeTicks.map { Double($0) / 10_000_000 }
        var copies = byContent[key] ?? []
        if let i = copies.firstIndex(where: { copy in
            guard copy.library != library else { return false }
            guard item.type == "Audio", let a = copy.seconds, let b = seconds else { return true }
            return abs(a - b) <= duplicateDurationSeconds
        }) {
            if isBetter(item, than: out[copies[i].position]) {
                out[copies[i].position] = item
                copies[i].library = library
                copies[i].seconds = seconds
                byContent[key] = copies
            }
            continue
        }
        copies.append(Copy(library: library, seconds: seconds, position: out.count))
        byContent[key] = copies
        out.append(item)
    }
    return out
}

private func isBetter(_ a: JfItem, than b: JfItem) -> Bool {
    if a.type == "MusicAlbum" { return (a.childCount ?? 0) > (b.childCount ?? 0) }
    return (a.mediaSources?.first?.bitrate ?? 0) > (b.mediaSources?.first?.bitrate ?? 0)
}

/// Lowercased, compatibility-normalised, and stripped of punctuation, symbols
/// and spaces, so "Mr. Brightside" and "mr brightside" compare equal.
private func normalise(_ s: String?) -> String {
    let drop = CharacterSet.punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines)
    let folded = (s ?? "").precomposedStringWithCompatibilityMapping.lowercased()
    return String(String.UnicodeScalarView(folded.unicodeScalars.filter { !drop.contains($0) }))
}

/// What makes two songs, albums or artists the same, or nil for anything else.
private func contentKey(_ item: JfItem) -> String? {
    let name = normalise(item.name)
    guard !name.isEmpty else { return nil }
    switch item.type {
    case "Audio": return "a|\(name)|\(normalise(item.artists?.first ?? item.albumArtist))"
    case "MusicAlbum": return "m|\(name)|\(normalise(item.albumArtist ?? item.artists?.first))"
    case "MusicArtist": return "r|\(name)"
    default: return nil
    }
}
