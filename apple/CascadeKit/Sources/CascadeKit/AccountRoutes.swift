import Foundation

// Account calls for Settings > Account. Shapes checked against Jellyfin
// 10.11.11's /api-docs/openapi.json:
//   POST /Users/Password?userId=  UpdateUserPassword {CurrentPw, NewPw, ResetPassword}  -> 204

/// The body of POST /Users/Password. `resetPassword` is never set: that clears
/// a password and is an admin tool, not what a change is.
struct UpdateUserPassword: Encodable {
    var currentPw: String
    var newPw: String
}

public extension JellyfinClient {
    /// Changes the signed-in user's password. The server checks the current
    /// one, so a wrong password is a 400/401 with its message, which is shown
    /// as is; a 2xx is the only success (CODEMAP rule 1).
    func changePassword(current: String, new: String) async throws {
        try await postRaw("/Users/Password", body: UpdateUserPassword(currentPw: current, newPw: new),
                          params: ["userId": currentConfig.userId])
    }
}
