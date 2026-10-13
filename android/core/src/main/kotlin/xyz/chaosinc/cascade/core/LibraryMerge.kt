package xyz.chaosinc.cascade.core

import java.text.Collator
import java.text.Normalizer
import java.util.Locale
import kotlin.math.abs

// The same song, album or artist found in more than one library, shown once.
//
// Ported from the desktop's dedupeById (src/core/jellyfin.ts) through
// CascadeKit's LibraryMerge.swift, with its tests, so the apps agree on what
// counts as a copy. Shuffling three libraries that each hold the same album
// otherwise plays every song three times.

/** Two copies of a song this far apart in length are different cuts (a live version, an extended mix). */
const val DUPLICATE_DURATION_SECONDS = 3.0

/**
 * Merges items that came from different libraries (`sourceLibrary`), keeping
 * list order: a merged item takes the place its first copy held.
 *
 * - Songs match on title and first artist, ignoring case and punctuation, with
 *   durations within DUPLICATE_DURATION_SECONDS. The highest bitrate wins.
 * - Albums match on name and album artist. The copy with the most tracks wins:
 *   the same album can be whole in one library and one song in another.
 * - Artists match on name. Jellyfin 12 gives an artist a different id in every
 *   library, so the id alone listed each one once per library.
 *
 * Copies inside one library are never merged; that is the library's own
 * business. Items without a `sourceLibrary` only merge by id.
 */
fun mergeLibraryCopies(items: List<JfItem>): List<JfItem> {
    class Copy(var library: Int, var seconds: Double?, val position: Int)
    val seenIds = HashSet<String>()
    val byContent = HashMap<String, MutableList<Copy>>()
    val out = mutableListOf<JfItem>()

    for (item in items) {
        if (!seenIds.add(item.id)) continue
        val library = item.sourceLibrary
        val key = contentKey(item)
        if (library == null || key == null) { out += item; continue }
        val seconds = item.runTimeTicks?.let { it / 10_000_000.0 }
        val copies = byContent.getOrPut(key) { mutableListOf() }
        val match = copies.firstOrNull { copy ->
            if (copy.library == library) false
            else {
                val a = copy.seconds
                if (item.type != "Audio" || a == null || seconds == null) true else abs(a - seconds) <= DUPLICATE_DURATION_SECONDS
            }
        }
        if (match != null) {
            if (isBetter(item, out[match.position])) {
                out[match.position] = item
                match.library = library
                match.seconds = seconds
            }
            continue
        }
        copies += Copy(library, seconds, out.size)
        out += item
    }
    return out
}

/**
 * Whether sortedLikeServer orders by this sortBy's first key the way the
 * server does, so a whole list already loaded can be re-sorted on the device
 * instead of fetched again. Random and the rating or runtime sorts cannot.
 */
fun sortsLikeServer(sortBy: String?): Boolean =
    (sortBy ?: "").split(",").first() in setOf("SortName", "Name", "DateCreated", "DatePlayed", "AlbumArtist", "Album", "PlayCount", "ProductionYear")

private val collator: Collator = Collator.getInstance(Locale.ROOT).apply { strength = Collator.SECONDARY }

/**
 * Text compared the way Apple's localizedStandardCompare does, which is what
 * CascadeKit and the Finder use: case-insensitive, and runs of digits as
 * numbers, so "Track 2" sorts before "Track 10".
 */
fun naturalCompare(a: String, b: String): Int {
    var i = 0
    var j = 0
    while (i < a.length && j < b.length) {
        val da = a[i].isDigit()
        val db = b[j].isDigit()
        val ei = run { var k = i; while (k < a.length && a[k].isDigit() == da) k++; k }
        val ej = run { var k = j; while (k < b.length && b[k].isDigit() == db) k++; k }
        val ca = a.substring(i, ei)
        val cb = b.substring(j, ej)
        val c = if (da && db) {
            val na = ca.trimStart('0')
            val nb = cb.trimStart('0')
            if (na.length != nb.length) na.length - nb.length else na.compareTo(nb)
        } else collator.compare(ca, cb)
        if (c != 0) return c
        i = ei
        j = ej
    }
    return (a.length - i) - (b.length - j)
}

/**
 * Puts results from several libraries back in the order one query would have
 * returned them in. Each library comes back sorted on its own and they are
 * joined library by library, so without this a second library's albums all
 * landed after the first's. Any sortBy it does not know (track order, search
 * relevance) keeps the order it was given. Stable: equal keys keep their order.
 */
fun sortedLikeServer(items: List<JfItem>, sortBy: String?, sortOrder: String? = null): List<JfItem> {
    val key = (sortBy ?: "").split(",").first()
    val descending = sortOrder == "Descending"
    val text: ((JfItem) -> String)? = when (key) {
        "SortName" -> { i -> i.sortName ?: i.name ?: "" }
        "Name" -> { i -> i.name ?: "" }
        "DateCreated" -> { i -> i.dateCreated ?: "" }
        "DatePlayed" -> { i -> i.userData?.lastPlayedDate ?: "" }
        "AlbumArtist" -> { i -> i.albumArtist ?: i.artists?.firstOrNull() ?: "" }
        "Album" -> { i -> i.album ?: "" }
        else -> null
    }
    val comparator: Comparator<JfItem> = when {
        key == "PlayCount" -> compareBy { it.userData?.playCount ?: 0 }
        key == "ProductionYear" -> compareBy { it.productionYear ?: 0 }
        text != null -> Comparator { a, b -> naturalCompare(text(a), text(b)) }
        else -> return items
    }
    // sortedWith is stable, so equal keys keep their order either way.
    return items.sortedWith(if (descending) comparator.reversed() else comparator)
}

private fun isBetter(a: JfItem, b: JfItem): Boolean =
    if (a.type == "MusicAlbum") (a.childCount ?: 0) > (b.childCount ?: 0)
    else (a.mediaSources?.firstOrNull()?.bitrate ?: 0) > (b.mediaSources?.firstOrNull()?.bitrate ?: 0)

private val droppedTypes = setOf(
    Character.CONNECTOR_PUNCTUATION, Character.DASH_PUNCTUATION, Character.START_PUNCTUATION, Character.END_PUNCTUATION,
    Character.INITIAL_QUOTE_PUNCTUATION, Character.FINAL_QUOTE_PUNCTUATION, Character.OTHER_PUNCTUATION,
    Character.MATH_SYMBOL, Character.CURRENCY_SYMBOL, Character.MODIFIER_SYMBOL, Character.OTHER_SYMBOL,
    Character.SPACE_SEPARATOR, Character.LINE_SEPARATOR, Character.PARAGRAPH_SEPARATOR,
).map { it.toInt() }.toSet()

/**
 * Lowercased, compatibility-normalized, and stripped of punctuation, symbols
 * and spaces, so "Mr. Brightside" and "mr brightside" compare equal.
 */
internal fun normalize(s: String?): String {
    val folded = Normalizer.normalize(s ?: "", Normalizer.Form.NFKC).lowercase()
    val out = StringBuilder()
    var i = 0
    while (i < folded.length) {
        val cp = folded.codePointAt(i)
        if (Character.getType(cp) !in droppedTypes && !Character.isWhitespace(cp)) out.appendCodePoint(cp)
        i += Character.charCount(cp)
    }
    return out.toString()
}

/** What makes two songs, albums or artists the same, or null for anything else. */
private fun contentKey(item: JfItem): String? {
    val name = normalize(item.name)
    if (name.isEmpty()) return null
    return when (item.type) {
        "Audio" -> "a|$name|${normalize(item.artists?.firstOrNull() ?: item.albumArtist)}"
        "MusicAlbum" -> "m|$name|${normalize(item.albumArtist ?: item.artists?.firstOrNull())}"
        "MusicArtist" -> "r|$name"
        else -> null
    }
}
