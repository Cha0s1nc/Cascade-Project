package xyz.chaosinc.cascade.core

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okhttp3.OkHttpClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// Ported case for case from the desktop's dedupeById tests, so the apps agree
// on what counts as a copy.

private fun song(id: String, name: String, artist: String, seconds: Double, library: Int, kbps: Long? = null) =
    JfItem(id, name, "Audio", runTimeTicks = (seconds * 10_000_000).toLong(), artists = listOf(artist),
        sourceLibrary = library, mediaSources = kbps?.let { listOf(JfMediaSourceRef(bitrate = it * 1000)) })

private fun album(id: String, name: String, albumArtist: String, library: Int, tracks: Int? = null) =
    JfItem(id, name, "MusicAlbum", albumArtist = albumArtist, childCount = tracks, sourceLibrary = library)

private fun ids(items: List<JfItem>) = items.map { it.id }

class LibraryMergeTest {
    @Test fun theSameSongInTwoLibrariesAppearsOnce() {
        val merged = mergeLibraryCopies(listOf(
            song("a1", "Mr. Brightside", "The Killers", 222.0, 0),
            song("a2", "Sober", "Letdown.", 216.0, 0),
            song("b1", "mr brightside", "the killers", 223.0, 1),         // same song: dropped
            song("b2", "Mr. Brightside (Live)", "The Killers", 240.0, 1), // a different cut: kept
            song("b3", "Sober", "Letdown.", 300.0, 1),                    // 84s longer: kept
        ))
        assertEquals(listOf("a1", "a2", "b2", "b3"), ids(merged))
    }

    @Test fun copiesInsideOneLibraryAreLeftAlone() {
        assertEquals(2, mergeLibraryCopies(listOf(song("1", "Home", "Phillip Phillips", 209.0, 0),
            song("2", "Home", "Phillip Phillips", 209.0, 0))).size)
    }

    @Test fun albumsMatchOnNameAndAlbumArtist() {
        val merged = mergeLibraryCopies(listOf(
            album("a", "A Fever You Can’t Sweat Out", "Panic! At The Disco", 0),
            album("b", "A Fever You Can't Sweat Out", "Panic! at the Disco", 1),
            album("c", "Pretty. Odd.", "Panic! At The Disco", 1),
        ))
        assertEquals(listOf("a", "c"), ids(merged))
    }

    @Test fun otherTypesOnlyMergeById() {
        val one = JfItem("1", "Road trip", "Playlist", sourceLibrary = 0)
        val two = JfItem("2", "Road trip", "Playlist", sourceLibrary = 1)
        assertEquals(2, mergeLibraryCopies(listOf(one, two, one)).size)
    }

    @Test fun theHigherBitrateCopyWinsInTheFirstCopysPlace() {
        val merged = mergeLibraryCopies(listOf(
            song("mp3", "Idol", "YOASOBI", 213.0, 0, 320),
            song("x", "Other", "Someone", 100.0, 0),
            song("flac", "Idol", "YOASOBI", 213.0, 1, 1100),
            song("aac", "Idol", "YOASOBI", 213.0, 2, 256),
        ))
        assertEquals(listOf("flac", "x"), ids(merged))
    }

    @Test fun ofTwoCopiesOfAnAlbumTheOneWithMoreTracksWins() {
        val partial = album("partial", "Night Drive", "Aurora Lane", 0, 1)
        val whole = album("whole", "Night Drive", "Aurora Lane", 1, 3)
        assertEquals(listOf("whole"), ids(mergeLibraryCopies(listOf(partial, whole))))
        assertEquals(listOf("whole"), ids(mergeLibraryCopies(listOf(whole.copy(sourceLibrary = 0), partial.copy(sourceLibrary = 1)))))
    }

    @Test fun anArtistInTwoLibrariesAppearsOnce() {
        // Jellyfin 12 gives the same artist a different id in every library.
        fun artist(id: String, name: String, library: Int) = JfItem(id, name, "MusicArtist", sourceLibrary = library)
        val merged = mergeLibraryCopies(listOf(artist("42585974", "Aurora Lane", 0), artist("98eed3bf", "aurora lane", 1),
            artist("d15fdbee", "Aurora Lane; Kite Echo", 1)))
        assertEquals(listOf("42585974", "d15fdbee"), ids(merged))
    }

    @Test fun mergingTwiceChangesNothing() {
        val items = listOf(song("mp3", "Idol", "YOASOBI", 213.0, 0, 320), song("flac", "Idol", "YOASOBI", 213.0, 1, 1100))
        assertEquals(ids(mergeLibraryCopies(items)), ids(mergeLibraryCopies(mergeLibraryCopies(items))))
    }

    @Test fun librariesArePutBackInOneOrder() {
        fun named(id: String, name: String, sortName: String? = null, library: Int) =
            JfItem(id, name, "MusicAlbum", sortName = sortName, sourceLibrary = library)
        val joined = listOf(named("1", "Daybreak", library = 0), named("2", "Night Drive", library = 0),
            named("3", "Only Here", library = 1), named("4", "The Album", "Album", 1))
        assertEquals(listOf("4", "1", "2", "3"), ids(sortedLikeServer(joined, "SortName")))
        assertEquals(listOf("3", "2", "1", "4"), ids(sortedLikeServer(joined, "SortName", "Descending")))
    }

    @Test fun anOrderItCannotReproduceIsLeftAlone() {
        val items = listOf(JfItem("b", "B"), JfItem("a", "A"))
        assertEquals(listOf("b", "a"), ids(sortedLikeServer(items, "ParentIndexNumber,IndexNumber")))
        assertEquals(listOf("b", "a"), ids(sortedLikeServer(items, null)))
    }

    @Test fun newestFirstByDateCreated() {
        val items = listOf(JfItem("old", dateCreated = "2026-01-01T00:00:00Z"), JfItem("new", dateCreated = "2026-09-01T00:00:00Z"))
        assertEquals(listOf("new", "old"), ids(sortedLikeServer(items, "DateCreated", "Descending")))
    }

    @Test fun sortsLikeServerKnowsItsKeys() {
        assertTrue(sortsLikeServer("SortName,AlbumArtist,Album"))
        assertTrue(sortsLikeServer("DateCreated"))
        assertTrue(sortsLikeServer("PlayCount"))
        assertFalse(sortsLikeServer("Random"))
        assertFalse(sortsLikeServer("CommunityRating"))
        assertFalse(sortsLikeServer(null))
    }

    @Test fun nameIgnoresTheTrackNumberInSortName() {
        // A song's SortName starts with its track number, so a Title sort must read Name.
        val zoom = JfItem("z", "Zoom", sortName = "0001 - Zoom")
        val alpha = JfItem("a", "Alpha", sortName = "0002 - Alpha")
        assertEquals(listOf("a", "z"), ids(sortedLikeServer(listOf(zoom, alpha), "Name")))
        assertEquals(listOf("z", "a"), ids(sortedLikeServer(listOf(alpha, zoom), "SortName")))
        assertEquals("Name", SongSortField.Name.serverSortBy)
    }

    @Test fun naturalCompareReadsNumbersAsNumbersAndIgnoresCase() {
        assertTrue(naturalCompare("Track 2", "Track 10") < 0)
        assertTrue(naturalCompare("apple", "Banana") < 0)
        assertEquals(0, naturalCompare("Abc", "abc"))
    }
}

/** An item that sorts after rank - 1 and before rank + 1 on every key the browsing screens use. */
private fun ranked(id: String, rank: Int, albumId: String? = null) = JfItem(id, "Name $rank", "Audio",
    sortName = "name $rank", albumArtist = "Artist $rank", album = "Album $rank", productionYear = 2000 + rank,
    dateCreated = "2026-0$rank-01T00:00:00Z", userData = JfUserData(lastPlayedDate = "2026-0$rank-02T00:00:00Z"), albumId = albumId)

class BrowseSortTest {
    // A server sort that sortedLikeServer does not know leaves two libraries
    // concatenated instead of interleaved, silently.
    @Test fun everyServerSortCanBeReproducedAcrossLibraries() {
        val keys = SongSortField.entries.map { it.serverSortBy } + AlbumSortField.entries.mapNotNull { it.serverSortBy } +
            PlaylistSortField.entries.map { it.serverSortBy } + ArtistSortField.entries.map { it.serverSortBy }
        for (key in keys) {
            val joined = listOf(ranked("second", 2), ranked("first", 1))
            assertEquals(key, listOf("first", "second"), ids(sortedLikeServer(joined, key)))
            assertEquals(key, listOf("second", "first"), ids(sortedLikeServer(joined, key, "Descending")))
        }
    }

    @Test fun yearsCompareAsNumbersNotText() {
        assertEquals(listOf("old", "new"), ids(sortedLikeServer(listOf(JfItem("new", productionYear = 2024), JfItem("old", productionYear = 999)), "ProductionYear,SortName")))
    }

    @Test fun recentlyPlayedAlbumsFollowTheirNewestTrack() {
        val played = listOf(ranked("t1", 1, "B"), ranked("t2", 2, "A"), ranked("t3", 3, "A"), ranked("t4", 4, "C"))
        assertEquals(listOf("B", "A", "C"), recentlyPlayedAlbumIds(played))
        val albums = listOf(JfItem("A"), JfItem("C"), JfItem("never"), JfItem("B"))
        assertEquals(listOf("B", "A", "C"), ids(albumsByRecentPlay(played, albums)))
    }

    @Test fun tiebreakers() {
        assertEquals("SortName,AlbumArtist,Album", withTiebreakers("SortName"))
        assertEquals("DateCreated,SortName,AlbumArtist,Album", withTiebreakers("DateCreated"))
        assertEquals("AlbumArtist,SortName,Album", withTiebreakers("AlbumArtist,SortName"))
        assertEquals("Random", withTiebreakers("Random"))
    }

    @Test fun directionMapsToTheServersWords() {
        assertEquals("Ascending", SortDirection.Ascending.serverValue)
        assertEquals("Descending", SortDirection.Descending.serverValue)
    }
}

class BrowseFilterTest {
    @Test fun noFilterSendsNothing() {
        assertTrue(BrowseFilter().params.isEmpty())
        assertFalse(BrowseFilter().isActive)
    }

    @Test fun eachFilterBecomesItsParameter() {
        val f = BrowseFilter(true, "Rock", 1990, BrowseFilter.Played.Unplayed)
        assertEquals(mapOf("isFavorite" to "true", "genres" to "Rock",
            "years" to "1990,1991,1992,1993,1994,1995,1996,1997,1998,1999", "isPlayed" to "false"), f.params)
        assertEquals(mapOf("isPlayed" to "true"), BrowseFilter(played = BrowseFilter.Played.Played).params)
    }

    @Test fun aFilterOverridesButNeverClearsTheScreensOwnParameters() {
        val params = mapOf<String, String?>("isFavorite" to "true", "sortBy" to "SortName")
        assertEquals(params, params.applying(BrowseFilter()))
        assertEquals(params + ("genres" to "g"), params.applying(BrowseFilter(genre = "g")))
    }

    @Test fun decadesAreTheOnesPresentNewestFirst() {
        assertEquals(listOf(2020, 2010, 2000, 1990, 1980, 1970), BrowseFilter.decades(listOf(1975, 1982, 1998, 2004, 2011, 2019, 2020, 2023, 0)))
        assertTrue(BrowseFilter.decades(emptyList()).isEmpty())
    }

    @Test fun storedFormRoundTripsAndJunkIsNoFilter() {
        val f = BrowseFilter(true, "Rock", 1990, BrowseFilter.Played.Played)
        assertEquals(f, BrowseFilter.fromRaw(f.rawValue))
        assertEquals(BrowseFilter(), BrowseFilter.fromRaw(BrowseFilter().rawValue))
        assertNull(BrowseFilter.fromRaw("junk"))
        assertNull(BrowseFilter.fromRaw("1|g|1990|sideways"))
    }
}

// Ported from test/library-browse.test.ts (normalizeLibraryPrefs).
class LibraryPrefsTest {
    @Test fun corruptedStoreValuesFallBackToDefaultsNeverGarbage() {
        assertNull(LibraryPrefs.fromStored(null))
        assertNull(LibraryPrefs.fromStored("not json"))
        assertNull(LibraryPrefs.fromStored("[1,2,3]"))
        assertEquals(AlbumSortField.Name, AlbumSortField.of(LibraryPrefs.fromStored("""{"field":"bogus"}""")?.field))
        assertEquals(SortDirection.Ascending, LibraryPrefs.fromStored("""{"dir":"sideways"}""")?.direction)
        assertNull(LibraryPrefs.fromStored("""{"decade":"1990"}""")?.filter?.decade)
        assertNull(LibraryPrefs.fromStored("""{"decade":true}""")?.filter?.decade)
        assertEquals(BrowseFilter.Played.Any, LibraryPrefs.fromStored("""{"played":"maybe"}""")?.filter?.played)
        assertNull(LibraryPrefs.fromStored("""{"genre":"a|b"}""")?.filter?.genre)
    }

    @Test fun aValidValueRoundTrips() {
        val prefs = LibraryPrefs.fromStored("""{"field":"year","dir":"desc","favorite":true,"genre":"Jazz","decade":1990,"played":"played"}""")
        assertEquals(LibraryPrefs("year", SortDirection.Descending, BrowseFilter(true, "Jazz", 1990, BrowseFilter.Played.Played)), prefs)
        assertEquals(prefs, LibraryPrefs.fromStored(prefs!!.stored))
    }

    @Test fun writtenInTheDesktopsShapeWithNulls() {
        val o = PlainJson.parseToJsonElement(LibraryPrefs().stored) as JsonObject
        assertEquals("name", o["field"]!!.jsonPrimitive.content)
        assertEquals("asc", o["dir"]!!.jsonPrimitive.content)
        assertEquals("false", o["favorite"]!!.jsonPrimitive.content)
        assertEquals(JsonNull, o["genre"])
        assertEquals(JsonNull, o["decade"])
        assertEquals(JsonNull, o["played"])
    }

    @Test fun aFieldTheScreenDoesNotOfferReadsAsItsDefault() {
        assertEquals(AlbumSortField.Name, AlbumSortField.of(LibraryPrefs(field = "count").field))
        assertEquals(ArtistSortField.Added, ArtistSortField.of(LibraryPrefs(field = "added").field))
    }
}

// Ported from the desktop's test for topSongsOf.
class ArtistPageTest {
    private fun s(name: String, plays: Int?) = JfItem(name, name, "Audio", userData = plays?.let { JfUserData(playCount = it) })

    @Test fun mostPlayedFirstTiesByNameUnplayedLeftOut() {
        val songs = listOf(s("b", 3), s("a", 3), s("c", 9), s("never", 0), s("unknown", null))
        assertEquals(listOf("c", "a", "b"), ArtistPage.topSongs(songs).map { it.name })
    }

    @Test fun capsAtTen() {
        val songs = (1..15).map { s("s$it", it) }
        assertEquals(10, ArtistPage.topSongs(songs).size)
        assertEquals("s15", ArtistPage.topSongs(songs).first().name)
        assertTrue(ArtistPage.topSongs(listOf(s("a", 0), s("b", null))).isEmpty())
    }
}

class AcrossLibrariesTest {
    @Test fun eachLibraryIsAskedAndCopiesMergeInServerOrder() = runBlocking {
        val server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val parent = request.url.queryParameter("parentId")
                val body = when (parent) {
                    "L1" -> """{"Items":[{"Id":"a","Name":"Daybreak","Type":"MusicAlbum","AlbumArtist":"X","ChildCount":1},{"Id":"c","Name":"Night","Type":"MusicAlbum","AlbumArtist":"X"}]}"""
                    "L2" -> """{"Items":[{"Id":"b","Name":"Daybreak","Type":"MusicAlbum","AlbumArtist":"X","ChildCount":9},{"Id":"d","Name":"Alpha","Type":"MusicAlbum","AlbumArtist":"Y"}]}"""
                    else -> "{}"
                }
                return MockResponse.Builder().body(body).build()
            }
        }
        server.start()
        val client = JellyfinClient(ServerConfig(server.url("/").toString(), "T", "U", listOf("L1", "L2"), "D"), OkHttpClient(), testIdentity)
        val albums = client.albums(sortBy = "SortName")
        // The fuller copy of Daybreak wins, and the two libraries interleave.
        assertEquals(listOf("d", "b", "c"), albums.map { it.id })
        val first = server.takeRequest()
        assertEquals("MusicAlbum", first.url.queryParameter("includeItemTypes"))
        assertEquals("SortName,AlbumArtist,Album", first.url.queryParameter("sortBy"))
        assertTrue(first.url.queryParameter("fields")!!.contains("ChildCount"))
        assertNull("off means absent, never false", first.url.queryParameter("isFavorite"))
        server.close()
    }
}
