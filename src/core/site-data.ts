// releases.json for the website's Cascade releases page, from the GitHub
// releases, their versions.json files and what the download mirror holds.
// Pure; scripts/site-data.mjs does the fetching.
//
// A release lists only the platforms it built. Files carried over from an
// older release (see docs/release-pipeline-plan.md) are left out: they are
// listed under the release that built them, so nothing appears twice.

import { PLATFORMS, platformOfFile } from './release-plan.ts'
import type { Platform } from './release-plan.ts'

export interface GhRelease {
  tag_name: string
  html_url: string
  published_at: string | null
  draft: boolean
  prerelease: boolean
  assets: { name: string, size: number, browser_download_url: string }[]
}

export interface SiteFile { name: string, size: number, url: string, mirror: string | null }

export interface SiteRelease {
  version: string
  tag: string
  /** YYYY-MM-DD */
  date: string
  url: string
  platforms: Partial<Record<Platform, SiteFile[]>>
}

const VERSION_RE = /^\d+\.\d+\.\d+$/

export interface SiteInput {
  releases: readonly GhRelease[]
  /** Each tag's versions.json, parsed; missing for releases made before it existed. */
  versionsByTag: Readonly<Record<string, unknown>>
  mirrorUrl: string
  /** The version folders the mirror holds, per platform. */
  mirrorVersions: Partial<Record<Platform, readonly string[]>>
}

/** Published stable releases, newest first, each with the files it built. */
export function siteReleases(input: SiteInput): SiteRelease[] {
  const out: SiteRelease[] = []
  for (const r of input.releases) {
    const version = r.tag_name.replace(/^v/, '')
    if (r.draft || r.prerelease || !VERSION_RE.test(version)) continue
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
        }))
        .sort((a, b) => a.name.localeCompare(b.name))
      if (files.length) platforms[p] = files
    }
    out.push({ version, tag: r.tag_name, date: (r.published_at ?? '').slice(0, 10), url: r.html_url, platforms })
  }
  return out.sort((a, b) => {
    const [x, y] = [a.version, b.version].map(v => v.split('.').map(Number))
    return y[0] - x[0] || y[1] - x[1] || y[2] - x[2]
  })
}
