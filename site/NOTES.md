# cascade.chaosinc.xyz

The project's site, as one Cloudflare Worker (`cascade-site`):

- `cascade.chaosinc.xyz` serves `public/` (a placeholder until the landing page moves here), the maintainer login at `/login`, and the announcements panel at `/admin/announcements`.
- `announcements.cascade.chaosinc.xyz` serves only the feed, which every Cascade app fetches at launch. It is `announcements.json` in the `cascade-plugins` R2 bucket, so `plugins.chaosinc.xyz/announcements.json` is the same file.

Login is GitHub OAuth. Only the logins in `ALLOWED_LOGINS` (`wrangler.toml`) get in, checked on every request, so removing a name locks that person out at once. Each saved announcement records the GitHub login that last changed it as `author`. The apps ignore that field. Every save is checked by `validateFeed` (`src/announcements.js`, tested in `desktop/test/announcements.test.ts`), so a malformed entry never reaches anyone.

## Setting it up

1. Create a GitHub OAuth App (github.com/settings/developers, OAuth Apps, New):
   - Homepage URL: `https://cascade.chaosinc.xyz`
   - Authorization callback URL: `https://cascade.chaosinc.xyz/login/callback`, wildcard matching off
   - Generate a client secret.
2. From this folder, set the three secrets (each prompts for the value):

       npx wrangler secret put GITHUB_CLIENT_ID
       npx wrangler secret put GITHUB_CLIENT_SECRET
       npx wrangler secret put SESSION_SECRET

   For `SESSION_SECRET`, paste the output of `openssl rand -hex 32`. Changing it signs everyone out.
3. Deploy: `npx wrangler deploy`. The two custom domains, their DNS records and certificates are created on the first deploy.

## Running it locally

`npx wrangler dev` runs it at `http://localhost:8787` with a local, empty R2 bucket, never the real one. It reads secrets from `.dev.vars` (gitignored). To sign in locally, add `http://localhost:8787/login/callback` as a second callback URL on the OAuth App.

## Later

- A second maintainer: add their GitHub login to `ALLOWED_LOGINS` and deploy. If the project moves to a GitHub org, switch `allowed()` in `src/index.js` to a team membership check (that needs the `read:org` scope).
- Saves are last-write-wins. Fine for one or two people. Add an R2 etag check (`onlyIf`) if two people ever edit at the same time.
