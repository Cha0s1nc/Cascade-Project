# Cascade's lyrics editor

This folder is a modified copy of [AMLL TTML Tool](https://github.com/amll-dev/amll-ttml-tool) by Steve Xiao and contributors, under the GNU GPL version 3 (see [LICENSE](LICENSE)). Its copyright notices stay as they are. Cascade's additional app-store permission does not cover it (see the repository's LICENSE).

**Upstream:** copied from commit `9b1e944a3ee38a3c05975d31e8798b6473df81fe` (2026-10-17), without `src-tauri/` (the desktop shell), `.github/` and `.vscode/`.

**What Cascade changes,** kept as small as it can be so upstream changes still merge:

- The Cascade Server plugin serves the built editor at `/CascadeServer/Editor/` and opens it on one song: it loads that song's lyrics and audio from the plugin and saves back to it (`src/cascade/`).
- No telemetry and no offline service worker: Sentry, Vercel Analytics and Speed Insights, and the PWA registration are removed. The page is served from a Jellyfin server, where a service worker could get in the way of Jellyfin's own web app.
- Cascade's look: its accent color, dark background and font.

The design is in [`docs/flutter-plan.md`](../../docs/flutter-plan.md) under Lyrics editor.

**Building:** `npx pnpm@10 install && npx pnpm@10 build` here makes `dist/`, which the plugin build embeds.
