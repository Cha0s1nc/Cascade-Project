// Picking the right installer out of a GitHub release.
//
// Lifted out of apps/desktop/main.js's pickAsset so it can be tested. That
// matters more than it used to: releases now carry mobile binaries as well
// (.apk, .aab, .ipa) alongside the desktop ones, and this is the code standing
// between a Mac and a download it cannot possibly run. Getting it wrong is not
// a crash, it is a user downloading 140MB and finding it useless - so it gets a
// test rather than a reading.

/** Just the fields this needs; a real GitHub asset has many more. */
export interface ReleaseAsset {
  name: string
  browser_download_url?: string
}

export type DesktopPlatform = 'win32' | 'darwin' | 'linux'
export type LinuxPackageKind = 'AppImage' | 'deb' | 'rpm' | null

export interface AssetTarget {
  platform: DesktopPlatform | string
  /** process.arch. Only darwin distinguishes builds by it. */
  arch?: string
  /** Which format this Linux install came from; see main.js linuxPackageKind. */
  linuxKind?: LinuxPackageKind
}

/**
 * The asset matching this exact platform/arch/format, or undefined.
 *
 * Deliberately no "close enough" fallback: handing someone an installer that
 * cannot run on their machine is worse than sending them to the releases page.
 *
 * Mobile artefacts are excluded by construction rather than by a blocklist -
 * each branch matches one desktop extension, and .apk/.aab/.ipa match none of
 * them. A blocklist would need updating every time a new artefact type appears;
 * this cannot rot the same way.
 */
export function pickReleaseAsset(
  assets: ReleaseAsset[] = [],
  target: AssetTarget,
): ReleaseAsset | undefined {
  const byExt = (re: RegExp) => assets.filter(a => re.test(a.name))

  if (target.platform === 'win32') return byExt(/\.exe$/i)[0]

  if (target.platform === 'darwin') {
    // Only the arm64 build carries its arch in the filename; the unsuffixed
    // .dmg is the x64 one. Matching on arch alone silently handed Intel Macs
    // the arm64 build.
    const dmgs = byExt(/\.dmg$/i)
    return target.arch === 'arm64'
      ? dmgs.find(a => /arm64/i.test(a.name))
      : dmgs.find(a => !/arm64/i.test(a.name))
  }

  if (target.platform === 'linux') {
    if (target.linuxKind === 'AppImage') return byExt(/\.AppImage$/i)[0]
    if (target.linuxKind === 'deb') return byExt(/\.deb$/i)[0]
    if (target.linuxKind === 'rpm') return byExt(/\.rpm$/i)[0]
  }

  return undefined
}
