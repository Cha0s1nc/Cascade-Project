package xyz.chaosinc.cascade.core

import kotlinx.coroutines.runBlocking
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.OkHttpClient
import okhttp3.Request
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProxyHeadersTest {
    private fun h(n: String, v: String) = ProxyHeader(n, v)

    @Test fun namesMustBeTokens() {
        assertNull(ProxyHeaders.nameProblem("CF-Access-Client-Id"))
        assertNull(ProxyHeaders.nameProblem("X_Custom.1~"))
        for (bad in listOf("", "Has Space", "colon:", "new\nline", "ünï", "(x)", "a/b")) {
            assertNotNull("$bad should be refused", ProxyHeaders.nameProblem(bad))
        }
    }

    @Test fun authorizationHostAndContentLengthCannotBeOverridden() {
        for (n in listOf("Authorization", "AUTHORIZATION", "host", "Host", "Content-Length", "X-Emby-Authorization", "Transfer-Encoding")) {
            assertTrue(n, ProxyHeaders.nameProblem(n)!!.contains("cannot be overridden"))
        }
        assertNull(ProxyHeaders.nameProblem("Authorization-Extra"))
    }

    @Test fun valuesArePresentBoundedAndClean() {
        assertNull(ProxyHeaders.valueProblem("abc123"))
        assertNull(ProxyHeaders.valueProblem("a b\tc"))
        assertNotNull(ProxyHeaders.valueProblem(""))
        assertNotNull(ProxyHeaders.valueProblem("x\r\nInjected: 1"))
        assertNotNull(ProxyHeaders.valueProblem("x\u0000y"))
        assertNotNull(ProxyHeaders.valueProblem("x".repeat(5000)))
    }

    @Test fun parsesNameValueLines() {
        val r = ProxyHeaders.parse("CF-Access-Client-Id: abc.access\r\n\n# a note\nCF-Access-Client-Secret:  s3cret:with:colons  ")
        assertTrue(r.errors.isEmpty())
        assertEquals(listOf(h("CF-Access-Client-Id", "abc.access"), h("CF-Access-Client-Secret", "s3cret:with:colons")), r.headers)
    }

    @Test fun reportsEveryBadLineAndKeepsTheGoodOnes() {
        val r = ProxyHeaders.parse("Good: 1\nno colon here\nAuthorization: Bearer x\nBad Name: 1\nX-Empty:\ngood: 2")
        assertEquals(listOf(h("Good", "1")), r.headers)
        assertEquals(5, r.errors.size)
        assertTrue(r.errors[0].startsWith("Line 2:"))
        assertTrue(r.errors[1].startsWith("Line 3: Authorization cannot be overridden"))
        assertTrue(r.errors[4].startsWith("Line 6: good is already listed"))
    }

    @Test fun capsTheList() {
        val text = (0 until ProxyHeaders.MAX_COUNT + 3).joinToString("\n") { "X-H$it: v" }
        val r = ProxyHeaders.parse(text)
        assertEquals(ProxyHeaders.MAX_COUNT, r.headers.size)
        assertEquals(3, r.errors.size)
    }

    @Test fun formatRoundTripsThroughParse() {
        val list = listOf(h("A", "1"), h("B-C", "x: y"))
        assertEquals(list, ProxyHeaders.parse(ProxyHeaders.format(list)).headers)
        assertEquals("", ProxyHeaders.format(emptyList()))
    }

    @Test fun sanitizedDropsWhatIsNotTrustworthy() {
        val out = ProxyHeaders.sanitized(listOf(h("A", "1"), h("a", "2"), h("Host", "evil"), h("B", "x\ny"), h("", "x"), h("D", "ok")))
        assertEquals(listOf(h("A", "1"), h("D", "ok")), out)
    }

    @Test fun originNormalizesDefaultPortsAndWebSockets() {
        fun o(s: String) = ProxyHeaders.origin(s)
        assertEquals("https://jf.example.com", o("https://jf.example.com/web/index.html"))
        assertEquals("https://jf.example.com", o("https://jf.example.com:443/x"))
        assertEquals("http://192.168.1.10:8096", o("http://192.168.1.10:8096/x"))
        assertEquals("http://host", o("http://host:80"))
        assertEquals("https://jf.example.com", o("wss://jf.example.com/socket"))
        assertEquals("http://h:8096", o("ws://h:8096/socket"))
        assertEquals("https://jf.example.com", o("HTTPS://JF.Example.COM/"))
        assertNull(o("file:///x"))
        assertNull(o("ftp://h/x"))
    }

    @Test fun headersOnlyReachTheServerOrigin() {
        val hs = listOf(h("X-Token", "t"))
        val server = "https://jf.example.com/jellyfin"
        fun f(s: String) = ProxyHeaders.headersFor(s, server, hs)
        assertEquals(hs, f("https://jf.example.com/Items/1/Images/Primary"))
        assertEquals(hs, f("wss://jf.example.com/socket"))
        for (other in listOf("https://lrclib.net/api/get", "https://jf.example.com.evil.net/", "https://other.example.com/",
            "http://jf.example.com/", "https://jf.example.com:8443/", "https://jf.example.com@evil.net/")) {
            assertTrue(other, f(other).isEmpty())
        }
        assertTrue(ProxyHeaders.headersFor(server, null, hs).isEmpty())
        assertTrue(ProxyHeaders.headersFor(server, server, emptyList()).isEmpty())
    }

    @Test fun redirectsKeepTheHeadersOnlyOnTheSameOrigin() {
        fun keeps(a: String, b: String) = ProxyHeaders.redirectKeepsHeaders(a, b)
        assertTrue(keeps("https://jf.example.com/x", "https://JF.example.com/y"))
        assertTrue("the upgrade of the same address", keeps("http://jf.example.com/x", "https://jf.example.com/x"))
        assertTrue("another port is another service", !keeps("https://jf.example.com/", "https://jf.example.com:8443/"))
        assertTrue("no downgrade", !keeps("https://jf.example.com/", "http://jf.example.com/"))
        assertTrue(!keeps("https://jf.example.com/", "https://login.example.net/"))
    }

    @Test fun theConnectionFollowsTheServerAndDropsBlockedNames() {
        val c = ProxyConnection()
        c.headers = listOf(h("X-A", "1"), h("Authorization", "refused"))
        assertTrue("no server set yet", c.headersToSend("https://jf.example.com/x").isEmpty())
        c.server = "https://jf.example.com"
        assertEquals(listOf(h("X-A", "1")), c.headersToSend("https://jf.example.com/x"))
        assertTrue(c.headersToSend("https://lrclib.net/api/get").isEmpty())
    }

    @Test fun theInterceptorAddsThemOnTheWire() = runBlocking {
        val server = MockWebServer()
        server.start()
        server.enqueue(MockResponse.Builder().body("ok").build())
        val c = ProxyConnection()
        c.server = server.url("/").toString()
        c.headers = listOf(h("CF-Access-Client-Id", "id"))
        val http = OkHttpClient.Builder().addNetworkInterceptor(c).build()
        http.newCall(Request.Builder().url(server.url("/x")).build()).await().close()
        assertEquals("id", server.takeRequest().headers["CF-Access-Client-Id"])
        server.close()
    }
}

// The desktop's test/server-messages.test.ts cases.
class ServerMessageTest {
    @Test fun aDashboardMessageReadsItsParts() {
        assertEquals(ServerMessage("Maintenance", "Restarting at 2", 5.0),
            ServerMessage.parse(mapOf("Header" to "Maintenance", "Text" to "Restarting at 2", "TimeoutMs" to "5000")))
        assertEquals(ServerMessage("Message from your server", "hi", null), ServerMessage.parse(mapOf("Text" to "hi")))
        assertNull(ServerMessage.parse(emptyMap()))
        assertNull(ServerMessage.parse(mapOf("Header" to "x", "TimeoutMs" to "soon"))?.timeoutSeconds)
    }

    @Test fun theDisclaimerComesOutAsPlainText() {
        assertEquals("Welcome to Chaos & friends.\nBe nice.\nThanks",
            ServerMessage.loginDisclaimerText("<p>Welcome to <b>Chaos</b> &amp; friends.</p><p>Be nice.<br>Thanks</p>"))
        assertEquals("alert(1)ok", ServerMessage.loginDisclaimerText("<script>alert(1)</script>ok"))
        assertEquals("", ServerMessage.loginDisclaimerText(null))
        assertEquals("café —", ServerMessage.loginDisclaimerText("caf&#233; &#x2014;"))
    }
}
