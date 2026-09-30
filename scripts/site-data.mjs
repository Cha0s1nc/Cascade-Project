// Writes the website's Cascade data into OUT_DIR:
//
//   releases.json   published stable releases and the files each one built,
//                   with download mirror links (src/core/site-data.ts)
//   changelog.json  CHANGELOG.md parsed (src/core/changelog.ts), keeping only
//                   versions that have a published release; the desktop's
//                   update window reads this
//
// Env: REPO (owner/name), GH_TOKEN (optional, for the rate limit), MIRROR_URL,
// OUT_DIR. Run by .github/workflows/publish.yml.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

// See scripts/changelog-section.mjs: only Node's harmless module-type warning
// is dropped, so it does not read like a failure in the CI log.
const printWarning = process.listeners('warning')
process.removeAllListeners('warning')
process.on('warning', w => {
  if (w.code !== 'MODULE_TYPELESS_PACKAGE_JSON') for (const print of printWarning) print(w)
})
const { PLATFORMS } = await import('../src/core/release-plan.ts')
const { siteReleases } = await import('../src/core/site-data.ts')
const { parseChangelog } = await import('../src/core/changelog.ts')

const { REPO, GH_TOKEN, MIRROR_URL, OUT_DIR } = process.env
if (!REPO || !MIRROR_URL || !OUT_DIR) throw new Error('REPO, MIRROR_URL and OUT_DIR are required')

const headers = { 'User-Agent': 'cascade-site-data', ...(GH_TOKEN ? { Authorization: `Bearer ${GH_TOKEN}` } : {}) }
const getJson = async (url, extra = {}) => {
  const res = await fetch(url, { headers: { ...headers, ...extra }, signal: AbortSignal.timeout(30_000) })
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`)
  return res.json()
}

// ponytail: one page of 100 releases; paginate when there are more.
const releases = (await getJson(`https://api.github.com/repos/${REPO}/releases?per_page=100`))
  .filter(r => !r.draft && !r.prerelease)

const versionsByTag = {}
for (const r of releases) {
  const asset = r.assets.find(a => a.name === 'versions.json')
  if (!asset) continue
  try { versionsByTag[r.tag_name] = await getJson(asset.browser_download_url) }
  catch (err) { console.error(`${r.tag_name}: versions.json unreadable, treated as missing (${err.message})`) }
}

// Caddy's file_server lists a folder as JSON when asked to.
const mirrorVersions = {}
for (const p of PLATFORMS) {
  try {
    const res = await fetch(`${MIRROR_URL}/${p}/`, { headers: { Accept: 'application/json' }, signal: AbortSignal.timeout(15_000) })
    mirrorVersions[p] = res.ok ? (await res.json()).filter(e => e.is_dir).map(e => e.name.replace(/\/$/, '')) : []
  } catch (err) {
    console.error(`mirror listing for ${p} failed, no mirror links (${err.message})`)
    mirrorVersions[p] = []
  }
}

const site = siteReleases({ releases, versionsByTag, mirrorUrl: MIRROR_URL, mirrorVersions })
const published = new Set(site.map(r => r.version))
const changelog = parseChangelog(readFileSync('CHANGELOG.md', 'utf8')).filter(e => published.has(e.version))

mkdirSync(OUT_DIR, { recursive: true })
writeFileSync(join(OUT_DIR, 'releases.json'), JSON.stringify({ mirror: MIRROR_URL, releases: site }, null, 1) + '\n')
writeFileSync(join(OUT_DIR, 'changelog.json'), JSON.stringify(changelog, null, 1) + '\n')
console.error(`Wrote ${site.length} releases and ${changelog.length} changelog entries to ${OUT_DIR}`)
