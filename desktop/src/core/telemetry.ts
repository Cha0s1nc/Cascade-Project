// Opt-in usage telemetry: one ping a day with a random install id, the app
// version and edition, and how many songs played since the last ping that
// landed. Nothing about the user, the server or the songs themselves.
//
// DORMANT while TELEMETRY_URL is empty: no wizard step, no Settings row, no
// counting, nothing stored, nothing sent. To switch it on:
//   1. Deploy telemetry/ (see telemetry/NOTES.md) and create its D1 database.
//   2. Set TELEMETRY_URL here and Telemetry.url in apple/CascadeKit's Telemetry.swift.
//   3. Bump WIZARD_REVISION in renderer.js and SetupWizard.revision in Swift
//      to 5, the revision `telemetry` already has on both sides, so existing
//      installs are asked once. The two share one numbering: the native Mac
//      app imports the desktop's wizardSeenRevision.
// ElectronSettingsImport already carries telemetryOptIn and telemetryInstallId
// to the native Mac app, so switching apps is not a new install.

export const TELEMETRY_URL = ''

export const TELEMETRY_INTERVAL_MS = 24 * 60 * 60 * 1000

/** The Worker drops anything above this, so a corrupt counter cannot poison a day. */
export const TELEMETRY_MAX_SONGS = 5000

export function telemetryAvailable(url: string = TELEMETRY_URL): boolean {
  return url !== ''
}

/** Never sent (or a corrupt stamp) counts as due, so opting in is counted that day. */
export function telemetryDue(lastSentMs: unknown, nowMs: number): boolean {
  const last = Number(lastSentMs)
  return !Number.isFinite(last) || last <= 0 || nowMs - last >= TELEMETRY_INTERVAL_MS
}

export interface TelemetryPing {
  installId: string
  version: string
  edition: string
  device: string
  songs: number
}

/** Stored values are untrusted: a missing or broken count is sent as 0. */
export function telemetryPing(installId: string, version: string, edition: string, device: string, songs: unknown): TelemetryPing {
  const n = Math.floor(Number(songs))
  return { installId, version, edition, device, songs: Number.isFinite(n) && n > 0 ? Math.min(n, TELEMETRY_MAX_SONGS) : 0 }
}
