#!/usr/bin/env node
/**
 * Stamp the root package.json version into every app that ships a binary.
 *
 * The repo has one version. Xcode and Gradle each keep their own copy of it, so
 * without this they drift - and they had: the root said 1.2.0 while both mobile
 * apps still said 1.0, which would have shipped a "1.3.0" release containing
 * apps that call themselves 1.0.
 *
 * Run from the release workflow, before building anything:
 *   node scripts/sync-version.js          # apply
 *   node scripts/sync-version.js --check  # verify only, non-zero if stale
 *
 * --check is what CI wants: it fails the build when someone bumps the root
 * version and forgets to run this, rather than letting a mislabelled binary out.
 *
 * ponytail: string surgery, not a config plugin. Two file formats, four files,
 * and a bump happens a handful of times a year.
 */
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const check = process.argv.includes('--check');

const version = require(path.join(root, 'package.json')).version;
if (!/^\d+\.\d+\.\d+(-.+)?$/.test(version)) {
  console.error(`refusing to sync a version that is not semver: ${version}`);
  process.exit(1);
}

/**
 * Android's versionCode must be an integer that only ever increases, and it is
 * what Play actually orders releases by - the name is just a label. Derived so
 * it cannot be forgotten: 1.2.0 -> 10200, 1.10.3 -> 11003.
 *
 * A prerelease suffix is deliberately ignored here: 1.3.0-b1 and 1.3.0 share a
 * code, so a beta must not be uploaded to the same Play track as its release.
 */
const [major, minor, patch] = version.replace(/-.*$/, '').split('.').map(Number);
const versionCode = major * 10000 + minor * 100 + patch;

/** Every file that carries a copy of the version, and how to rewrite it. */
const targets = [
  ...['tv', 'mobile'].flatMap(app => [
    {
      file: `apps/${app}/ios/CascadeMobile.xcodeproj/project.pbxproj`,
      edits: [
        [/MARKETING_VERSION = [^;]+;/g, `MARKETING_VERSION = ${version};`],
        // Xcode's build number. Kept equal to versionCode so a TestFlight build
        // and a Play build of the same release are traceable to each other.
        [/CURRENT_PROJECT_VERSION = [^;]+;/g, `CURRENT_PROJECT_VERSION = ${versionCode};`],
      ],
    },
    {
      file: `apps/${app}/android/app/build.gradle`,
      edits: [
        [/versionName "[^"]*"/g, `versionName "${version}"`],
        [/versionCode \d+/g, `versionCode ${versionCode}`],
      ],
    },
    {
      file: `apps/${app}/package.json`,
      edits: [[/("version":\s*)"[^"]*"/, `$1"${version}"`]],
    },
  ]),
  { file: 'apps/desktop/package.json', edits: [[/("version":\s*)"[^"]*"/, `$1"${version}"`]] },
  { file: 'packages/core/package.json', edits: [[/("version":\s*)"[^"]*"/, `$1"${version}"`]] },
  { file: 'packages/app/package.json', edits: [[/("version":\s*)"[^"]*"/, `$1"${version}"`]] },
];

let stale = 0;
let written = 0;

for (const { file, edits } of targets) {
  const full = path.join(root, file);
  if (!fs.existsSync(full)) {
    console.error(`missing: ${file}`);
    process.exit(1);
  }

  const before = fs.readFileSync(full, 'utf8');
  let after = before;
  for (const [pattern, replacement] of edits) {
    if (!pattern.test(after)) {
      // A target that no longer contains what we came to replace means the file
      // moved on without this script. Failing loudly beats silently shipping a
      // stale version, which is the whole thing this exists to prevent.
      console.error(`no match for ${pattern} in ${file}`);
      process.exit(1);
    }
    pattern.lastIndex = 0;
    after = after.replace(pattern, replacement);
  }

  if (after === before) continue;
  stale++;
  if (check) {
    console.error(`stale: ${file}`);
  } else {
    fs.writeFileSync(full, after);
    written++;
    console.log(`updated: ${file}`);
  }
}

if (check) {
  if (stale) {
    console.error(`\n${stale} file(s) do not match version ${version}. Run: node scripts/sync-version.js`);
    process.exit(1);
  }
  console.log(`all targets already at ${version} (versionCode ${versionCode})`);
} else {
  console.log(`\nversion ${version}, versionCode ${versionCode} - ${written} file(s) updated`);
}
