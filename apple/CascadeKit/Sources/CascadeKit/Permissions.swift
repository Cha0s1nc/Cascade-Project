import Foundation

/// The user's Jellyfin Policy, the part Cascade reads: it comes back inside
/// GET /Users/{id}. Anything missing reads as "no".
public struct UserPolicy: Decodable, Sendable, Equatable {
    public var isAdministrator: Bool?
    public var enableContentDeletion: Bool?
    public var enableContentDeletionFromFolders: [String]?

    public init(isAdministrator: Bool? = nil, enableContentDeletion: Bool? = nil,
                enableContentDeletionFromFolders: [String]? = nil) {
        self.isAdministrator = isAdministrator
        self.enableContentDeletion = enableContentDeletion
        self.enableContentDeletionFromFolders = enableContentDeletionFromFolders
    }
}

/// Cascade's own permission flags, worked out from the Policy
/// (src/core/permissions.ts). Media deletion is its own right, separate from
/// admin: a non-admin can be granted it and an admin has it implicitly, so
/// gating Delete on isAdmin alone is wrong in both directions.
public enum Permissions {
    /// Whether this user can delete media on at least one library. The
    /// per-folder list is per library, but resolving which library owns the
    /// item under the cursor everywhere Delete is offered is a lot of
    /// plumbing for a menu entry, so this is one global "can delete anything".
    /// A user granted only some libraries sees Delete everywhere and the
    /// server still refuses the others (a 403, shown by the caller); this
    /// only decides whether to offer the control.
    public static func canDeleteMedia(policy: UserPolicy?) -> Bool {
        guard let policy else { return false }
        if policy.isAdministrator == true { return true }
        if policy.enableContentDeletion == true { return true }
        return !(policy.enableContentDeletionFromFolders ?? []).isEmpty
    }

    public static func isAdmin(policy: UserPolicy?) -> Bool { policy?.isAdministrator == true }
}

private struct UserEnvelope: Decodable {
    var policy: UserPolicy?
}

public extension JellyfinClient {
    /// The signed-in user's Policy, for the admin and delete gating. Nil only
    /// when the server sent none; a failed request throws.
    func userPolicy() async throws -> UserPolicy? {
        let user: UserEnvelope = try await get("/Users/\(currentConfig.userId)")
        return user.policy
    }
}
