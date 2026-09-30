// What the desktop updater takes from a GitHub release: which desktop version
// it holds, and which of its files installs that version on this computer.
//
// A release is no longer one version of one app. From 2.3 on, a release named
// for the newest version of ANY platform carries the other platforms' files
// over from the release before, still named for their own versions, plus a
// `versions.json` asset saying which version each platform is at:
//
//   { "desktop": "2.3.1", "apple": "2.3.1", "android": "2.3.2" }
//
// Reading the tag alone would make release v2.3.2, holding the desktop 2.3.1
// installers, look like an update to 2.3.2 forever. So the desktop version
// comes from that file, and the tag is only a fallback for releases made
// before it existed.
//
// Pure on purpose, like everything in src/core: main.js does the fetching and
// knows the platform, this decides, so the decisions are testable. main.js
// loads it as build/update-release.js (see the build:main script).

/** The parts of a GitHub release asset this module reads. */
export interface ReleaseAsset {
  name: string
  browser_download_url?: string
  size?: number
  digest?: string | null
}

/** The parts of a GitHub release this module reads. */
export interface ReleaseLike {
  tag_name?: unknown
  assets?: unknown
}

/** Which installer this computer can run. `linuxKind` is null off Linux or when unknown. */
export interface InstallTarget {
  platform: string
  arch: string
  linuxKind: 'AppImage' | 'deb' | 'rpm' | null
}

export const VERSIONS_ASSET_NAME = 'versions.json'

// The real file is well under 100 bytes. Anything near this is not that file,
// and there is no reason to read a large download to find out.
export const VERSIONS_MAX_BYTES = 4096

// x.y.z, or a x.y.z-bN beta, each number at most 4 digits. Deliberately
// strict: the value decides whether an update is offered and ends up in the
// Mac installer's version check, so "2.3", "v2.3.1", "2.3.1 " and "999" are
// all refused rather than guessed at.
const VERSION_RE = /^(0|[1-9]\d{0,3})\.(0|[1-9]\d{0,3})\.(0|[1-9]\d{0,3})(-b[1-9]\d{0,3})?$/

export const isReleaseVersion = (v: unknown): v is string => typeof v === 'string' && VERSION_RE.test(v)

/**
 * [major, minor, patch, beta]. A release sorts above every `-bN` beta of the
 * same version (beta is Infinity for a release). Any other suffix is stripped,
 * so it compares equal to the release. Moved here unchanged from main.js.
 */
export function parseAppVersion(v: unknown): [number, number, number, number] {
  const s = String(v).replace(/^v/, '')
  const betaMatch = s.match(/-b(\d+)$/i)
  const betaNum = betaMatch ? parseInt(betaMatch[1], 10) : Infinity
  const [major, minor, patch] = s.replace(/[-+][a-zA-Z0-9._]*$/, '').split('.').map(n => parseInt(n, 10) || 0)
  return [major ?? 0, minor ?? 0, patch ?? 0, betaNum]
}

export function isNewerVersion(latest: unknown, current: unknown): boolean {
  const l = parseAppVersion(latest)
  const c = parseAppVersion(current)
  for (let i = 0; i < 4; i++) if (l[i] !== c[i]) return l[i] > c[i]
  return false
}

/** The release's assets, keeping only entries shaped like one. */
export function releaseAssets(release: ReleaseLike): ReleaseAsset[] {
  if (!Array.isArray(release.assets)) return []
  return release.assets.filter((a): a is ReleaseAsset => !!a && typeof a === 'object' && typeof a.name === 'string')
}

/** The release's versions.json asset, if it has one. The name must match exactly. */
export function findVersionsAsset(release: ReleaseLike): ReleaseAsset | undefined {
  return releaseAssets(release).find(a => a.name === VERSIONS_ASSET_NAME)
}

export type VersionsFile =
  | { ok: true, desktop: string | null }
  | { ok: false }

/**
 * Reads the text of a versions.json. Untrusted: it is a file anyone with
 * write access to the repo can upload. `desktop: null` means a well-formed
 * file with no desktop entry, which says the release holds no desktop build
 * (a beta for another platform, say). Anything else wrong with it, including
 * a desktop entry that is present but not a plain version, is `ok: false`.
 * Other platforms' entries are not this app's business and are not checked.
 */
export function parseVersionsFile(text: unknown): VersionsFile {
  if (typeof text !== 'string' || text.length > VERSIONS_MAX_BYTES) return { ok: false }
  let data: unknown
  try { data = JSON.parse(text) } catch { return { ok: false } }
  if (!data || typeof data !== 'object' || Array.isArray(data)) return { ok: false }
  if (!Object.prototype.hasOwnProperty.call(data, 'desktop')) return { ok: true, desktop: null }
  const desktop = (data as Record<string, unknown>).desktop
  return isReleaseVersion(desktop) ? { ok: true, desktop } : { ok: false }
}

const INSTALLER_RE = /\.(exe|dmg|AppImage|deb|rpm)$/i

/** A desktop installer, as opposed to versions.json, an .ipa, an .apk, a blockmap. */
export const isDesktopInstaller = (name: string): boolean => INSTALLER_RE.test(name)

const escapeRegExp = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

/**
 * Whether a file name carries exactly this version, as electron-builder names
 * them: `Cascade-2.3.1-arm64.dmg`, `Cascade.Setup.2.3.1.exe` (GitHub turns
 * the space into a dot), `cascade_2.3.1_amd64.deb`, `Cascade-2.3.1-b2.AppImage`.
 * A whole version only: 2.3.1 is not in 12.3.1, 2.3.10, 1.2.3.1 or 2.3.1-b2.
 */
export function nameCarriesVersion(name: string, version: string): boolean {
  if (!version) return false
  const re = new RegExp(`(?<!\\d)(?<!\\d\\.)${escapeRegExp(version)}(?!\\d|\\.\\d|-b)`)
  return re.test(name)
}

export interface DesktopBuild {
  version: string
  /** Where the version came from, for the log. */
  source: 'versions.json' | 'tag'
}

/**
 * The desktop version a release holds, or null if it holds none.
 *
 * `versionsText` is the downloaded versions.json, or null when the release has
 * none or it could not be read. Without a usable file the tag is used, which
 * is what every release before 2.3 needs.
 *
 * Either way, at least one desktop installer in the release must carry the
 * version in its name. That is what stops a bad file from causing an update
 * offer on its own: a file claiming 9.9.9, or a tag used because the file was
 * unreadable, offers nothing unless the release really contains that build.
 * (A release carrying over desktop 2.3.1 as v2.3.2 has no 2.3.2 installers.)
 * It checks every platform's installers, not only this one's, so a computer
 * with no installer of its own (an Intel Mac) is still told about the update
 * and sent to the release page, as before.
 */
export function desktopBuildOf(release: ReleaseLike, versionsText: string | null): DesktopBuild | null {
  let pick: DesktopBuild | null = null
  const file = versionsText == null ? null : parseVersionsFile(versionsText)
  if (file?.ok) {
    if (file.desktop === null) return null
    pick = { version: file.desktop, source: 'versions.json' }
  } else if (typeof release.tag_name === 'string') {
    // Looser than isReleaseVersion on purpose (old betas were tagged
    // v1.1.1-b), but still only letters, digits, dots and dashes: the version
    // ends up in a file name in mac-update.js.
    const tag = release.tag_name.replace(/^v/, '')
    if (/^\d+\.\d+\.\d+(-[A-Za-z0-9.]*)?$/.test(tag)) pick = { version: tag, source: 'tag' }
  }
  if (!pick) return null
  const version = pick.version
  const built = releaseAssets(release).some(a => isDesktopInstaller(a.name) && nameCarriesVersion(a.name, version))
  return built ? pick : null
}

/**
 * The installer for this computer, carrying `version` in its name, or
 * undefined. Deliberately no "close enough" fallback: handing someone an
 * installer that cannot run on their machine, or one of a different version
 * (the Mac installer refuses those anyway), is worse than sending them to the
 * release page.
 */
export function pickInstaller(release: ReleaseLike, version: string, target: InstallTarget): ReleaseAsset | undefined {
  const assets = releaseAssets(release).filter(a => nameCarriesVersion(a.name, version))
  const byExt = (re: RegExp) => assets.filter(a => re.test(a.name))

  if (target.platform === 'win32') return byExt(/\.exe$/i)[0]

  // Apple Silicon only. An Intel Mac gets undefined and is sent to the release
  // page rather than handed a build it cannot run. The arm64 build carries its
  // arch in the filename, so the match stays explicit even though it is now the
  // only dmg published; older releases still have an unsuffixed x64 one.
  if (target.platform === 'darwin') {
    return target.arch === 'arm64' ? byExt(/\.dmg$/i).find(a => /arm64/i.test(a.name)) : undefined
  }

  // x64 only: no arm64 Linux build is published, and handing an arm64
  // machine the amd64 package only fails at install time.
  if (target.platform === 'linux') {
    if (target.arch !== 'x64') return undefined
    if (target.linuxKind === 'AppImage') return byExt(/\.AppImage$/i)[0]
    if (target.linuxKind === 'deb')      return byExt(/\.deb$/i)[0]
    if (target.linuxKind === 'rpm')      return byExt(/\.rpm$/i)[0]
  }

  return undefined
}
