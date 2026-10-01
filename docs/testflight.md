# TestFlight uploads (ready, switched off)

The `testflight` job in `.github/workflows/build.yml` uploads every published beta (a `[BETA]` commit pushed to `dev`) to TestFlight, for iOS and tvOS. It does nothing until the repository variable `TESTFLIGHT` is `true`, and that needs the paid Apple Developer Program. This is the list for that day.

It has never run: it can't until the account exists. Expect one shakedown run, and read its log before trusting it.

## Decide first (can't be changed later)

1. **One bundle ID or two.** Today iOS is `xyz.chaosinc.cascade.ios` and tvOS is `xyz.chaosinc.cascade.tvos`: two separate apps in App Store Connect, with separate TestFlight testers and store pages. Sharing one bundle ID (say `xyz.chaosinc.cascade`) makes one app on both platforms ("universal purchase"): one listing, one set of testers. Once a build is uploaded under a bundle ID, that app record keeps it forever. Changing it later means a new app. Changing it now means the sideloaded app reinstalls as a new app on your devices (signed out, downloads gone). If you change it, change `project.yml` and the two `BUNDLE=` lines in the job.
2. **App icons.** There is no asset catalog yet, and App Store Connect rejects an upload without icons. iOS needs a 1024 by 1024 `AppIcon`. tvOS needs an `App Icon & Top Shelf Image` brand asset: layered icons at 400 by 240 and 1280 by 768, plus a 1920 by 720 and a 2320 by 720 Top Shelf image. The project already points at those names. The art is under `assets/LICENSE`, not the GPL, so ask the artist before deriving tvOS layers from it.

## In the Apple Developer account

3. Note your **Team ID** (Membership details). It is not the free personal team `8SF895GF9C` in `project.yml`; update that too, for local builds.
4. **Identifiers:** register an App ID for each bundle ID. No capabilities are needed (background audio is an Info.plist key, not an entitlement).
5. **Certificate:** Xcode, Settings, Accounts, Manage Certificates, +, Apple Distribution. Then in Keychain Access, export it with its private key as a `.p12`, with a password.
6. **Profiles:** one "App Store Connect" distribution profile per bundle ID, using that certificate. Download both. Keep the names plain (letters, digits, spaces), e.g. `Cascade iOS App Store`.

## In App Store Connect

7. **Apps:** create the app record(s) with the same bundle IDs. An upload for a bundle ID with no record fails.
8. **API key:** Users and Access, Integrations, App Store Connect API, Team Keys, +, role **App Manager**. Download the `.p8` (only possible once) and note the Key ID and the Issuer ID.
9. **TestFlight:** make an internal testing group with automatic distribution, so each upload reaches it without clicks. External testers also work, but each new version goes through Beta App Review first.

## Secrets and variables

Run from the repo (or ask Claude to):

```bash
base64 -i dist.p12 | gh secret set APPLE_DIST_CERT_P12
gh secret set APPLE_DIST_CERT_PASSWORD
base64 -i Cascade_iOS_App_Store.mobileprovision | gh secret set APPLE_PROFILE_IOS
base64 -i Cascade_tvOS_App_Store.mobileprovision | gh secret set APPLE_PROFILE_TVOS
gh secret set ASC_API_KEY_P8 < AuthKey_XXXXXXXXXX.p8
gh variable set APPLE_TEAM_ID --body XXXXXXXXXX
gh variable set ASC_API_KEY_ID --body XXXXXXXXXX
gh variable set ASC_API_ISSUER_ID --body xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
gh variable set TESTFLIGHT --body true
```

`gh secret set` with no value prompts for it, so the password never lands in shell history. Delete the local `.p12` and `.p8` copies afterward, or keep them in a password manager.

## How it works

- Runs on the `xcode-27` image, after `setup`, beside `build-apple`. It archives again with signing rather than reusing the unsigned archive.
- Version: the beta's `x.y.z` without `-bN`, so TestFlight groups every beta of 2.3.1 under 2.3.1. Build number: the workflow run number, same as the sideload `.ipa` from that run.
- Signing is manual from the secrets, in a throwaway keychain that is deleted at the end. The profile names reach the two app targets through `CASCADE_PROFILE_IOS` and `CASCADE_PROFILE_TVOS` (see `project.yml`), because a profile passed to `xcodebuild` directly also lands on the CascadeKit package, which rejects it.
- `xcodebuild -exportArchive` with `destination: upload` sends each build straight to App Store Connect with the API key. Processing then takes a few minutes before testers see it.
- `ITSAppUsesNonExemptEncryption` is `false` in both Info.plists (standard HTTPS only), so no export compliance question per build.
- Manual beta runs (Actions, Run workflow, beta box) are drafts and are not uploaded, matching the rule that a manual run never publishes.

## Upkeep and gotchas

- The certificate and profiles **expire after a year**. Renew the certificate, regenerate both profiles against it, and reset the three secrets. Uploads fail with a signing error until then.
- **Re-running** a run reuses its run number, and TestFlight refuses a build number it already has. If iOS uploaded and tvOS failed, push a new beta rather than re-running.
- **Stable releases** are not uploaded. To send them too (for App Store submission, which stays manual), change the job's condition to `(mode == 'beta' && publish == 'true') || mode == 'release'`.
- "What to Test" notes are not filled in; add them in App Store Connect, or extend the job with the App Store Connect API later.
