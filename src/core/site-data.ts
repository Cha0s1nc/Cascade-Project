// releases.json for the website's Cascade releases page, from the GitHub
// releases, their versions.json files and what the download mirror holds.
// Pure; scripts/site-data.mjs does the fetching.
//
// Every published release is listed, betas included, with its GitHub release
// notes word for word. A release lists only the platforms it built. Files carried over from an
// older release (see docs/release-pipeline-plan.md) are left out: they are
// listed under the release that built them, so nothing appears twice.

import { PLATFORMS, platformOfFile } from './release-plan.ts'
import { isNewerVersion } from './update-release.ts'
import type { Platform } from './release-plan.ts'

export interface GhRelease {
  tag_name: string
  html_url: string
  published_at: string | null
  draft: boolean
  prerelease: boolean
  body?: string | null
  assets: { name: string, size: number, browser_download_url: string }[]
}

export interface SiteFile {
  name: string
  size: number
  url: string
  mirror: string | null
  /**
   * What to call a Mac download, since two ship side by side: "Mac (native)"
   * and "Mac (Electron)". null for every other file, which the site labels
   * by its extension as before.
   */
  label: string | null
}

const fileLabel = (name: string): string | null =>
  platformOfFile(name) === 'mac' ? 'Mac (native)' : /\.dmg$/i.test(name) ? 'Mac (Electron)' : null

export interface SiteRelease {
  version: string
  tag: string
  /** YYYY-MM-DD */
  date: string
  url: string
  prerelease: boolean
  /** The GitHub release notes, verbatim Markdown. */
  notes: string
  platforms: Partial<Record<Platform, SiteFile[]>>
}

// x.y.z, or a beta: x.y.z-bN (early betas were tagged with a bare -b).
const VERSION_RE = /^\d+\.\d+\.\d+(-b\d*)?$/

export interface SiteInput {
  releases: readonly GhRelease[]
  /** Each tag's versions.json, parsed; missing for releases made before it existed. */
  versionsByTag: Readonly<Record<string, unknown>>
  mirrorUrl: string
  /** The version folders the mirror holds, per platform. */
  mirrorVersions: Partial<Record<Platform, readonly string[]>>
}

/** Published releases, betas included, newest first, each with the files it built. */
export function siteReleases(input: SiteInput): SiteRelease[] {
  const out: SiteRelease[] = []
  for (const r of input.releases) {
    const version = r.tag_name.replace(/^v/, '')
    if (r.draft || !VERSION_RE.test(version)) continue
    const versions = input.versionsByTag[r.tag_name]
    // Before versions.json, a release was the desktop app alone.
    const builtHere = (p: Platform) => versions && typeof versions === 'object'
      ? (versions as Record<string, unknown>)[p] === version
      : p === 'desktop'
    const platforms: SiteRelease['platforms'] = {}
    for (const p of PLATFORMS) {
      if (!builtHere(p)) continue
      const files = r.assets
        .filter(a => platformOfFile(a.name) === p)
        .map(a => ({
          name: a.name,
          size: a.size,
          url: a.browser_download_url,
          mirror: input.mirrorVersions[p]?.includes(version)
            ? `${input.mirrorUrl}/${p}/${version}/${encodeURIComponent(a.name)}`
            : null,
          label: fileLabel(a.name),
        }))
        .sort((a, b) => a.name.localeCompare(b.name))
      if (files.length) platforms[p] = files
    }
    out.push({
      version, tag: r.tag_name, date: (r.published_at ?? '').slice(0, 10), url: r.html_url,
      prerelease: r.prerelease, notes: typeof r.body === 'string' ? r.body : '', platforms,
    })
  }
  // A beta sorts below the release it leads up to.
  return out.sort((a, b) => (isNewerVersion(a.version, b.version) ? -1 : isNewerVersion(b.version, a.version) ? 1 : 0))
}
