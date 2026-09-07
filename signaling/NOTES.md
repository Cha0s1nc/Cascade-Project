# Waterfall signaling relay

The Cloudflare Worker + Durable Object that Cascade's Waterfall rooms run
through. It carries no audio, only small JSON control messages: room
create/join, the roster, and the relay of everything `waterfall.js` sends.
One Durable Object per room code.

Deployed and live at
`https://cascade-waterfall-signaling.cha0s-netw0rks.workers.dev`, which is the
default `WF_DEFAULT_RELAY` in `waterfall.js`. Anyone can point Settings >
Waterfall at their own deployment instead.

Deploy from this folder:

    npm install && npx wrangler deploy

The client side lives in `waterfall.js` (DOM and session UI) and
`src/core/waterfall-protocol.ts` (wire format and sync maths).
