import Foundation

public extension JellyfinClient {
    /// The album's video cover from Cascade Server (the `animated-art`
    /// capability), as a URL a player can open: the key rides in the query,
    /// since a player sends no headers. `pending` is TIDAL still being asked,
    /// which is worth asking about again later; no video otherwise.
    func coverVideo(albumId: String) async -> (url: URL?, pending: Bool) {
        struct Reply: Decodable { var source: String?; var url: String?; var pending: Bool? }
        guard let reply: Reply = try? await get("/CascadeServer/AnimatedArt/\(albumId)") else { return (nil, false) }
        guard reply.source != nil, let path = reply.url, path.hasPrefix("/"),
              var c = URLComponents(string: currentConfig.url + path) else { return (nil, reply.pending == true) }
        c.queryItems = [URLQueryItem(name: "api_key", value: currentConfig.token)]
        return (c.url, false)
    }
}
