import Foundation
import AlbumSyncCore
import AlbumsFeature

/// `AlbumSyncCore.AlbumSyncRemoteAlbumOps` over the album write service + the bridge's decrypted
/// album listing. Thin translation only - if Proton's SDK gains album-write APIs, this adapter is
/// the single type to swap.
struct ProtonAlbumSyncRemoteOps: AlbumSyncRemoteAlbumOps {
    let service: ProtonAlbumWriteService
    /// The bridge's album listing (ids + decrypted titles) - shared with the sidebar/repository.
    let listProvider: @Sendable () async throws -> [AlbumSummary]

    func listAlbums() async throws -> [AlbumSyncRemoteAlbum] {
        try await listProvider().map { AlbumSyncRemoteAlbum(id: $0.id, title: $0.title) }
    }

    func createAlbum(name: String) async throws -> String {
        try await service.createAlbum(name: name)
    }

    func childMainLinkIDs(albumID: String) async throws -> Set<String> {
        try await service.childMainLinkIDs(albumID: albumID)
    }

    func attach(_ photos: [AlbumSyncAttachCandidate], albumID: String) async throws -> AlbumSyncAttachResult {
        let result = try await service.attach(
            photos.map { AlbumAttachRequestItem(uid: $0.uid, sha1Hex: $0.sha1Hex) },
            albumID: albumID
        )
        return AlbumSyncAttachResult(
            attached: result.attachedCount,
            alreadyMember: result.alreadyMemberCount,
            failed: result.failedCount,
            firstFailureMessage: result.firstFailureMessage
        )
    }
}
