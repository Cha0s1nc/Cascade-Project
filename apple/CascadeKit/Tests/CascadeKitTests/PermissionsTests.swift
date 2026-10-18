import Testing
import Foundation
@testable import CascadeKit

// The desktop's test/permissions.test.ts and test/context-menu.test.ts (the
// menu table half; native menus clamp themselves), ported.
struct PermissionsTests {
    @Test func anAdministratorCanDeleteWhateverTheFlagsSay() {
        #expect(Permissions.canDeleteMedia(policy: UserPolicy(isAdministrator: true)))
        #expect(Permissions.canDeleteMedia(policy: UserPolicy(isAdministrator: true, enableContentDeletion: false)))
    }

    @Test func aNonAdminWithTheGlobalDeletionFlagCanDelete() {
        #expect(Permissions.canDeleteMedia(policy: UserPolicy(isAdministrator: false, enableContentDeletion: true)))
    }

    @Test func aNonAdminGrantedOneFolderCanDelete() {
        #expect(Permissions.canDeleteMedia(policy: UserPolicy(isAdministrator: false, enableContentDeletionFromFolders: ["lib1"])))
    }

    @Test func aNonAdminWithNoDeletionRightsCannot() {
        #expect(!Permissions.canDeleteMedia(policy: UserPolicy(isAdministrator: false)))
        #expect(!Permissions.canDeleteMedia(policy: UserPolicy(isAdministrator: false, enableContentDeletion: false,
                                                               enableContentDeletionFromFolders: [])))
    }

    @Test func aMissingPolicyReadsAsNoRightsNotACrash() {
        #expect(!Permissions.canDeleteMedia(policy: nil))
        #expect(!Permissions.canDeleteMedia(policy: UserPolicy()))
        #expect(!Permissions.isAdmin(policy: nil))
        #expect(!Permissions.isAdmin(policy: UserPolicy(isAdministrator: false)))
        #expect(Permissions.isAdmin(policy: UserPolicy(isAdministrator: true)))
    }

    @Test func thePolicyReadsFromTheServersPascalCaseJson() throws {
        let json = #"{"Policy":{"IsAdministrator":false,"EnableContentDeletion":false,"EnableContentDeletionFromFolders":["a"]}}"#
        struct Envelope: Decodable { var policy: UserPolicy? }
        let policy = try JSON.decoder.decode(Envelope.self, from: Data(json.utf8)).policy
        #expect(policy == UserPolicy(isAdministrator: false, enableContentDeletion: false,
                                     enableContentDeletionFromFolders: ["a"]))
        #expect(Permissions.canDeleteMedia(policy: policy))
        #expect(!Permissions.isAdmin(policy: policy))
    }
}

struct ContextMenuKindTests {
    @Test func albumHasThePlayFamilyMetadataDownloadFavoriteAndGoToArtist() {
        let v = menuItems(for: .album)
        #expect(v.play && v.playNext && v.playLast && v.shuffle && v.instantMix)
        #expect(v.addPlaylist && v.download && v.favorite && v.goArtist && v.refreshMeta && v.editMeta)
        #expect(!v.rename && !v.deleteItem && !v.markPlayed)
    }

    @Test func artistHasPlayAllMixViewAndQueueActionsButNoDownload() {
        let v = menuItems(for: .artist)
        #expect(v.play && v.shuffle && v.instantMix && v.viewDetail && v.playNext && v.playLast && v.addPlaylist && v.favorite)
        #expect(!v.download && !v.refreshMeta)
    }

    @Test func aVideoShowsExactlyOneMarkPlayedRow() {
        let unplayed = menuItems(for: .video, isPlayed: false)
        #expect(unplayed.play && unplayed.viewDetail && unplayed.markPlayed && !unplayed.markUnplayed)
        let played = menuItems(for: .video, isPlayed: true)
        #expect(!played.markPlayed && played.markUnplayed)
    }

    @Test func anUnknownPlayedStateHidesBothMarkRows() {
        #expect(!menuItems(for: .video).markPlayed && !menuItems(for: .video).markUnplayed)
        #expect(!menuItems(for: .series).markPlayed && !menuItems(for: .series).markUnplayed)
    }

    @Test func aSeriesIsAContainerWithNothingToPlay() {
        let v = menuItems(for: .series, isPlayed: false)
        #expect(!v.play && v.viewDetail && v.markPlayed)
    }

    @Test func offlineTheRowsThatNeedTheServerGo() {
        let album = menuItems(for: .album, offline: true)
        #expect(album.play && album.shuffle && album.playNext && album.playLast && album.goArtist)
        #expect(!album.instantMix && !album.addPlaylist && !album.download)
        #expect(album.favorite, "a favorite made offline is queued")
        #expect(!album.refreshMeta && !album.editMeta)
        let playlist = menuItems(for: .playlist, offline: true)
        #expect(playlist.play && !playlist.rename && !playlist.deleteItem)
        // Your own smart playlist is local: still yours to edit and delete.
        let mine = menuItems(for: .userSmartPlaylist, offline: true)
        #expect(mine.rename && mine.deleteItem && !mine.addPlaylist)
        let video = menuItems(for: .video, isPlayed: false, offline: true)
        #expect(video.play && video.markPlayed, "queued too")
        #expect(menuItems(for: .album, offline: false) == menuItems(for: .album))
    }

    @Test func aPlaylistCanBeRenamedAndDeleted() {
        let v = menuItems(for: .playlist)
        #expect(v.play && v.shuffle && v.rename && v.deleteItem && v.playNext && v.playLast && v.addPlaylist)
        #expect(!v.viewDetail)
    }

    @Test func aBuiltInSmartPlaylistIsNotRealSoNothingToRenameOrDelete() {
        let v = menuItems(for: .smartPlaylist)
        #expect(v.play && v.shuffle && v.playNext && v.playLast && v.addPlaylist)
        #expect(!v.rename && !v.deleteItem)
    }

    @Test func aUserSmartPlaylistReusesRenameAndDeleteForItsOwnDefinition() {
        let v = menuItems(for: .userSmartPlaylist)
        #expect(v.play && v.shuffle && v.playNext && v.playLast && v.addPlaylist && v.rename && v.deleteItem)
        #expect(!v.viewDetail)
    }
}
