// Deriving Cascade's own permission flags from the Jellyfin user Policy
// object that connect() already fetches for free from /Users/{id}. Media
// deletion is its own right, separate from admin: a non-admin can be granted
// it, and an admin has it implicitly. Gating the delete button on isAdmin
// alone is wrong in both directions, so this reads the actual fields the
// server checks.

/** The subset of Jellyfin's UserPolicy this file cares about. Untyped fields
 *  on the real response are ignored; missing/undefined ones read as "no". */
export interface JellyfinPolicy {
  IsAdministrator?: boolean
  EnableContentDeletion?: boolean
  EnableContentDeletionFromFolders?: string[]
}

/**
 * Whether this user can delete media on at least one library.
 *
 * EnableContentDeletionFromFolders is per-library - a user can have deletion
 * rights on some libraries and not others - but resolving which library owns
 * the item under the cursor everywhere delete is offered is a lot of plumbing
 * for a context menu action. This collapses it to one global "can delete
 * anything" check: true if content deletion is on for all libraries, or the
 * per-folder list names at least one. An admin always has it implicitly.
 *
 * Limitation: a user granted deletion on only some libraries sees the delete
 * option enabled everywhere, and a delete on a library they were not granted
 * still gets refused by the server (a 403, handled at the call site). This
 * only decides whether to offer the control at all, not whether every delete
 * will succeed.
 */
export function canDeleteMedia(policy: JellyfinPolicy | null | undefined): boolean {
  if (!policy) return false
  if (policy.IsAdministrator) return true
  if (policy.EnableContentDeletion) return true
  return !!policy.EnableContentDeletionFromFolders?.length
}
