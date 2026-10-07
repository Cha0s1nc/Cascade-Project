import Foundation
import Testing
@testable import CascadeKit

// The desktop's playlistDetailsRoute and sniffImageType cases.
@Suite("Playlist details")
struct PlaylistDetailsTests {
    @Test func thePluginIsPreferredEvenForAnAdmin() {
        #expect(PlaylistDetails.route(capabilities: ["playlist-edit"], pluginPresent: true, isAdmin: true) == .plugin)
        #expect(PlaylistDetails.route(capabilities: ["playlist-edit"], pluginPresent: true, isAdmin: false) == .plugin)
    }

    @Test func withoutThePluginOnlyAnAdminCan() {
        #expect(PlaylistDetails.route(capabilities: [], pluginPresent: true, isAdmin: true) == .admin)
        #expect(PlaylistDetails.route(capabilities: ["playlist-edit"], pluginPresent: false, isAdmin: true) == .admin)
        #expect(PlaylistDetails.route(capabilities: [], pluginPresent: false, isAdmin: false) == nil)
    }

    @Test func imagesAreKnownByTheirFirstBytes() {
        #expect(PlaylistDetails.imageType(Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0])) == "image/jpeg")
        #expect(PlaylistDetails.imageType(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0])) == "image/png")
        #expect(PlaylistDetails.imageType(Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8)) == "image/webp")
        #expect(PlaylistDetails.imageType(Data("GIF89a".utf8)) == nil)
        #expect(PlaylistDetails.imageType(Data()) == nil)
        #expect(PlaylistDetails.imageType(Data("RIFF\u{0}\u{0}\u{0}\u{0}WAVE".utf8)) == nil)
    }
}
