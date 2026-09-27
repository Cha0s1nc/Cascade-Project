import Foundation
import Testing
@testable import CascadeKit

// Offline: the request shapes, checked against the 10.11.11 spec, and the
// decode of what the server sends back. Signing in for real needs a person to
// approve the code, so there is no live test for the full flow.
struct QuickConnectTests {
    @Test func initiateIsAnAuthenticatedPostWithThisDevice() throws {
        let r = try QuickConnect.initiateRequest(serverUrl: "https://jf.example/", appVersion: "1.0", deviceId: "dev-1")
        #expect(r.url?.absoluteString == "https://jf.example/QuickConnect/Initiate")
        #expect(r.httpMethod == "POST")
        #expect(r.value(forHTTPHeaderField: "Authorization")?.contains("DeviceId=\"dev-1\"") == true)
    }

    @Test func connectPassesTheSecretEscaped() throws {
        let r = try QuickConnect.connectRequest(serverUrl: "https://jf.example", secret: "a b&c")
        #expect(r.url?.absoluteString == "https://jf.example/QuickConnect/Connect?secret=a%20b%26c")
        #expect(r.httpMethod == "GET")
    }

    @Test func authenticateSendsOnlyTheSecret() throws {
        let r = try QuickConnect.authenticateRequest(serverUrl: "https://jf.example", secret: "s3", appVersion: "1.0", deviceId: "dev-1")
        #expect(r.url?.absoluteString == "https://jf.example/Users/AuthenticateWithQuickConnect")
        #expect(r.httpMethod == "POST")
        let body = try JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: String]
        #expect(body == ["Secret": "s3"])
        #expect(r.value(forHTTPHeaderField: "Authorization") != nil)
    }

    @Test func decodesTheServersPascalCaseResult() throws {
        let json = #"{"Authenticated":false,"Secret":"abc","Code":"123456","DeviceId":"d","AppName":"Cascade"}"#
        let s = try JSON.decoder.decode(QuickConnectState.self, from: Data(json.utf8))
        #expect(s == QuickConnectState(secret: "abc", code: "123456", authenticated: false))
    }

    @Test func aBadAddressIsAnErrorNotACrash() {
        #expect(throws: JellyfinError.self) { try QuickConnect.initiateRequest(serverUrl: "", appVersion: "1", deviceId: "d") }
    }
}

@Test func authHeaderCarriesTheTokenOnlyWhenGiven() {
    // Jellyfin 12 accepts a token only in this header (or ApiKey in a URL).
    #expect(!authHeader(appVersion: "1.0", deviceId: "d").contains("Token="))
    #expect(authHeader(appVersion: "1.0", deviceId: "d", token: "T").hasSuffix(", Token=\"T\""))
}

struct QuickConnectApprovalTests {
    @Test func codesAreSixDigitsWithSpacingForgiven() {
        #expect(QuickConnect.normalizedCode("123456") == "123456")
        #expect(QuickConnect.normalizedCode(" 123 456 ") == "123456")
        #expect(QuickConnect.normalizedCode("123-456") == "123456")
        #expect(QuickConnect.normalizedCode("12345") == nil)
        #expect(QuickConnect.normalizedCode("1234567") == nil)
        #expect(QuickConnect.normalizedCode("12a456") == nil)
        // Non-ASCII digits are numbers to Swift and not to the server.
        #expect(QuickConnect.normalizedCode("١٢٣٤٥٦") == nil)
        #expect(QuickConnect.normalizedCode("") == nil)
    }
}
