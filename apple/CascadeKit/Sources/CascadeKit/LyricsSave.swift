import Foundation

public extension JellyfinClient {
    /// Saves Enhanced LRC to the Cascade Server plugin, which stores it as an .slrc shared by
    /// everyone on the server (lyrics-editor.html's save). The body is exactly `{"lrc": "..."}`:
    /// a hand-built request, since JSON.encoder would rewrite the key to "Lrc". Throws on any
    /// non-2xx, so a refused save never reads as a saved one.
    func saveLyrics(itemId: String, api: CascadePluginApi, lrc: String, session: URLSession = .shared) async throws {
        let config = currentConfig
        guard let url = URL(string: config.url + CascadePlugin.lyricsPath(api, itemId: itemId)) else {
            throw JellyfinError(status: 0, message: "Bad URL for the lyrics route")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader(appVersion: cascadeAppVersion, deviceId: config.deviceId, token: config.token),
                         forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["lrc": lrc])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw JellyfinError(status: 0, message: "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JellyfinError(status: http.statusCode, message: errorMessage(response: http, body: data))
        }
    }
}
