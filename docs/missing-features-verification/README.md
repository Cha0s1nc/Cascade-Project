# Verification scripts for the missing features work

These drive the real Electron app (not mocks) against small fake Jellyfin servers, and are what the claims in `docs/missing-features-report.md` about the desktop items rest on. They are evidence for an audit, not part of the test suite: delete this folder if you do not want it in the repo.

Run from the repo root after `npm run build:ts`, with `npm i --no-save playwright-core`: `node docs/missing-features-verification/<script>.mjs` on macOS, or under `xvfb-run -a` on a headless Linux box. All six passed on macOS on 2026-09-30. Each prints what it observed. They create throwaway profiles under `/tmp` and listen on random local ports.

- `headers-injection.mjs`: reverse proxy headers reach fetch, image and audio requests to the server's origin and no other host or port, and Authorization and Host are refused.
- `headers-signin.mjs`: the sign-in screen against a server that rejects any request without the header, including the Quick Connect probe and everything after sign-in.
- `offline-main-process.mjs`: downloads (success, a stream cut halfway, a 403), the cover, the slim index, playback through the `cascade-offline` protocol with seeking and a readable Web Audio graph, path escapes refused, a shared track surviving one removal, and the queued play validation.
- `offline-ui-and-offline-mode.mjs`: the Downloads view, then a relaunch with the server down (offline mode), playing from disk, a play queued offline and replayed when the server returns.
- `offline-reconcile.mjs`: launch deletes unfinished and unlisted files and sends a missing or escaping path's track back to pending.
- `miniplayer-volume.mjs`: the miniplayer opens, and its volume slider sets the main window's volume.
