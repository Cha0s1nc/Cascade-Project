# Cascade telemetry

Opt-in usage counts: one ping a day per install with a random install id, the app version, edition and device kind, and how many songs played since the last ping. Nothing about the person, their Jellyfin server, or what they played. The Worker never reads the request's IP and D1 never stores it.

**Not deployed.** The clients are dormant until `TELEMETRY_URL` (`src/core/telemetry.ts`) and `Telemetry.url` (`apple/CascadeKit/Sources/CascadeKit/Telemetry.swift`) are set. While they are empty there is no wizard step, no Settings row, no counting and no request.

## Switching it on

1. From this folder: `npm install`, then `npx wrangler d1 create cascade-telemetry` and put the printed id in `wrangler.toml`.
2. `npx wrangler d1 execute cascade-telemetry --remote --file schema.sql`
3. `npx wrangler deploy`, and note the URL.
4. Set `TELEMETRY_URL` to `<url>/ping` in `src/core/telemetry.ts`, and `Telemetry.url` in Swift.
5. Bump `WIZARD_REVISION` in `renderer.js` and `SetupWizard.revision` in Swift to 5, the revision the `telemetry` step already has on both sides. Without this, existing installs are never asked. If another wizard step lands first and takes 5, move telemetry to the next number on both sides: the native Mac app imports the desktop's revision, so they share one numbering.
6. Flip the dormant assertion in `test/telemetry.test.ts`.
7. Say what is collected in the README, and link `<url>/stats`.

## Endpoints

- `POST /ping`: `{installId, version, edition, device, songs}`. Anything malformed is a 400. One row per install per UTC day; a second ping that day adds its songs (capped) instead of counting a second install.
- `GET /stats`: aggregates only (installs and songs per day for 30 days, versions/editions/devices for 7). Public on purpose.

"Installs" are installs, not people: someone with a Mac and an iPhone counts twice. The endpoint has no key (any key in an open-source client is public), so the numbers are approximate by design.
