# Security policy

## Reporting a vulnerability

Please report security problems privately, not in a public issue: **[Report a vulnerability](https://github.com/Cha0s1nc/Cascade-Project/security/advisories/new)** (the Security tab, then "Report a vulnerability"). Only the maintainer sees the report, and you can follow and discuss it there.

Include what you found, how to reproduce it, and which version and platform you tested. A proof of concept helps but isn't required.

Cascade is maintained by one person, so this is best effort: expect an answer within a week, and a fix in the next release, sooner for anything serious. You'll be credited in the advisory unless you'd rather not be.

## Supported versions

Only the newest stable release gets security fixes, on each platform. Betas are fixed by the next beta. The updater installs new releases, so staying current is the fix.

## Scope

In scope: the Cascade apps in this repository (desktop, and the iOS and tvOS app), their updater, and the release and website data this repository publishes.

Report these elsewhere:

- **Jellyfin itself:** the [Jellyfin project](https://github.com/jellyfin/jellyfin/security).
- **The CascadeServer plugin:** [its repository](https://github.com/Cha0s1nc/CascadeServer).

Cascade signs in to your Jellyfin server and keeps a session token for it, so anything that could leak that token, run code from a server or release it shouldn't, or install an update that wasn't published here, is exactly what this policy is for.
