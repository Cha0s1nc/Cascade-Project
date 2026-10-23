package xyz.chaosinc.cascade.core

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.OkHttpClient
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

val testIdentity = ClientIdentity(ClientIdentity.ANDROID_EDITION, "Pixel 9", "1.0")

class JsonTest {
    @Test fun readsPascalCaseIntoKotlinNames() {
        val item = CascadeJson.decodeFromString(JfItem.serializer(),
            """{"Id":"a","Name":"Song","Type":"Audio","RunTimeTicks":3000000000,"UserData":{"IsFavorite":true,"PlayCount":3},"Unknown":1}""")
        assertEquals("a", item.id)
        assertEquals("Audio", item.type)
        // Past Int: ticks must be Long.
        assertEquals(3_000_000_000L, item.runTimeTicks)
        assertTrue(item.isFavorite)
        assertEquals(3, item.userData?.playCount)
    }

    @Test fun writesPascalCaseAndLeavesNullsOut() {
        val text = CascadeJson.encodeToString(JfUserData.serializer(), JfUserData(playCount = 2))
        assertEquals("""{"PlayCount":2}""", text)
    }

    @Test fun aTrackShowsItsAlbumsArt() {
        assertEquals("alb", JfItem(id = "t", type = "Audio", albumId = "alb").artItemId)
        assertEquals("t", JfItem(id = "t", type = "Audio").artItemId)
        assertEquals("x", JfItem(id = "x", type = "MusicAlbum", albumId = "y").artItemId)
    }
}

class AuthHeaderTest {
    @Test fun carriesTheTokenOnlyWhenGiven() {
        // Jellyfin 12 accepts a token only in this header (or ApiKey in a URL).
        assertFalse(authHeader(testIdentity, "d").contains("Token="))
        assertTrue(authHeader(testIdentity, "d", "T").endsWith(", Token=\"T\""))
        assertFalse(authHeader(testIdentity, "d", "").contains("Token="))
    }

    @Test fun namesTheEdition() {
        // The server's Devices screen tells the editions apart by Client.
        assertEquals("MediaBrowser Client=\"Cascade Android\", Device=\"Pixel 9\", DeviceId=\"d\", Version=\"1.0\"",
            authHeader(testIdentity, "d"))
    }

    @Test fun aDeviceNameCannotBreakTheQuotedValue() {
        assertEquals("Pixel 9 Pro", ClientIdentity.sanitizedDevice("Pixel \"9\" Pro"))
        assertEquals("Galaxy", ClientIdentity.sanitizedDevice("Galaxyé\n"))
        assertEquals("Android", ClientIdentity.sanitizedDevice(""))
        assertEquals("Android", ClientIdentity.sanitizedDevice(null))
    }
}

class ErrorMessageTest {
    @Test fun keepsShortPlainText() {
        assertEquals("Bad password", errorMessage(400, "text/plain", "Bad password"))
    }

    @Test fun fallsBackToTheStatusLineForHtml() {
        // A proxy in front of a dead server answers with a whole error page.
        val msg = errorMessage(502, "text/html", "<html><body>502 Bad Gateway</body></html>")
        assertTrue(msg.startsWith("502"))
        assertFalse(msg.contains("<"))
        assertEquals("404 Not Found", errorMessage(404, null, "  "))
    }

    @Test fun capsAVeryLongBody() {
        assertTrue(errorMessage(500, "text/plain", "a".repeat(5000)).length <= 301)
    }
}

class ServerConfigTest {
    @Test fun trailingSlashIsDropped() {
        // Otherwise every path becomes a double slash, which some proxies
        // answer with a redirect that drops the auth header.
        assertEquals("https://s", ServerConfig("https://s/", "T", "U", deviceId = "D").url)
    }
}

class ClientHttpTest {
    private lateinit var server: MockWebServer
    private lateinit var client: JellyfinClient
    private val http = OkHttpClient()

    @Before fun start() {
        server = MockWebServer()
        server.start()
        client = JellyfinClient(ServerConfig(server.url("/").toString(), "TOK", "U", deviceId = "dev"), http, testIdentity)
    }

    @After fun stop() { server.close() }

    @Test fun everyRequestCarriesTheAuthHeaderWithTheToken() = runBlocking {
        server.enqueue(MockResponse.Builder().body("""{"Items":[{"Id":"1"}],"TotalRecordCount":1}""").build())
        val r: JfItemsResponse = client.get("/Items", mapOf("b" to "2", "a" to "1", "skip" to null))
        assertEquals("1", r.items?.single()?.id)
        val req = server.takeRequest()
        assertEquals("/Items?a=1&b=2", req.target)
        assertTrue(req.headers["Authorization"]!!.endsWith("Token=\"TOK\""))
        assertNull(req.headers["X-Emby-Token"])
    }

    @Test fun aRefusedWriteThrowsWithTheStatus() = runBlocking {
        server.enqueue(MockResponse.Builder().code(403).body("Forbidden for you").build())
        try {
            client.postRaw("/UserFavoriteItems/x")
            fail("a 403 must not read as success")
        } catch (e: JellyfinException) {
            assertEquals(403, e.status)
            assertEquals("Forbidden for you", e.message)
        }
    }

    @Test fun imageUrlsUseApiKeyNeverApiUnderscoreKey() {
        val url = client.imageUrl("abc", 300)
        assertTrue(url.contains("ApiKey=TOK"))
        assertFalse(url.contains("api_key"))
    }

    @Test fun passwordSignInPostsTheLiteralKeys() = runBlocking {
        server.enqueue(MockResponse.Builder().body("""{"AccessToken":"tok","User":{"Id":"u1","Name":"me"}}""").build())
        val result = authenticate(http, testIdentity, server.url("/").toString(), "me", "pw", "dev")
        assertEquals("tok", result.accessToken)
        assertEquals("u1", result.user.id)
        val req = server.takeRequest()
        assertEquals("/Users/AuthenticateByName", req.target)
        val body = Json.parseToJsonElement(req.body!!.utf8()).jsonObject
        assertEquals("me", body["Username"]!!.jsonPrimitive.content)
        assertEquals("pw", body["Pw"]!!.jsonPrimitive.content)
        assertFalse(req.headers["Authorization"]!!.contains("Token="))
    }
}

// Offline: the request shapes, checked against the 10.11.11 spec, and the
// decode of what the server sends back. A real sign-in needs a person to
// approve the code, so there is no live test of the full flow.
class QuickConnectTest {
    @Test fun initiateIsAnAuthenticatedPostWithThisDevice() {
        val r = QuickConnect.initiateRequest("https://jf.example/", testIdentity, "dev-1")
        assertEquals("https://jf.example/QuickConnect/Initiate", r.url.toString())
        assertEquals("POST", r.method)
        assertTrue(r.header("Authorization")!!.contains("DeviceId=\"dev-1\""))
    }

    @Test fun connectPassesTheSecretEscaped() {
        val r = QuickConnect.connectRequest("https://jf.example", "a b&c")
        assertEquals("https://jf.example/QuickConnect/Connect?secret=a%20b%26c", r.url.toString())
        assertEquals("GET", r.method)
    }

    @Test fun authenticateSendsOnlyTheSecret() {
        val r = QuickConnect.authenticateRequest("https://jf.example", "s3", testIdentity, "dev-1")
        assertEquals("https://jf.example/Users/AuthenticateWithQuickConnect", r.url.toString())
        val buffer = okio.Buffer()
        r.body!!.writeTo(buffer)
        assertEquals("""{"Secret":"s3"}""", buffer.readUtf8())
    }

    @Test fun decodesTheServersPascalCaseResult() {
        val s = CascadeJson.decodeFromString(QuickConnectState.serializer(),
            """{"Authenticated":false,"Secret":"abc","Code":"123456","DeviceId":"d","AppName":"Cascade"}""")
        assertEquals(QuickConnectState("abc", "123456", false), s)
    }

    @Test fun aBadAddressIsAnErrorNotACrash() {
        for (bad in listOf("", "jf.example", "ftp://x")) {
            try { QuickConnect.initiateRequest(bad, testIdentity, "d"); fail(bad) } catch (_: JellyfinException) {}
        }
    }

    @Test fun codesAreSixDigitsWithSpacingForgiven() {
        assertEquals("123456", QuickConnect.normalizedCode("123456"))
        assertEquals("123456", QuickConnect.normalizedCode(" 123 456 "))
        assertEquals("123456", QuickConnect.normalizedCode("123-456"))
        assertNull(QuickConnect.normalizedCode("12345"))
        assertNull(QuickConnect.normalizedCode("1234567"))
        assertNull(QuickConnect.normalizedCode("12a456"))
        // Non-ASCII digits are digits to Kotlin and not to the server.
        assertNull(QuickConnect.normalizedCode("١٢٣٤٥٦"))
        assertNull(QuickConnect.normalizedCode(""))
    }
}
