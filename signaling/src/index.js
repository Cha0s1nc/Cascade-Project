// Waterfall signaling relay — room roster + WebRTC offer/answer/ICE relay.
// Carries no audio, only small JSON control messages. One Durable Object
// instance per room code holds the roster and forwards messages between
// members over the WebSocket Hibernation API.

const CODE_CHARS = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789' // no 0/O/1/I/L ambiguity
const CODE_LEN = 6
const MAX_MEMBERS = 10

function randomCode() {
  let s = ''
  for (let i = 0; i < CODE_LEN; i++) s += CODE_CHARS[Math.floor(Math.random() * CODE_CHARS.length)]
  return s
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url)

    if (url.pathname === '/create' && request.method === 'POST') {
      for (let attempt = 0; attempt < 5; attempt++) {
        const code = randomCode()
        const stub = env.ROOMS.get(env.ROOMS.idFromName(code))
        const res = await stub.fetch('https://room/claim')
        if (res.ok) {
          return Response.json({ code })
        }
      }
      return Response.json({ error: 'could-not-allocate-room' }, { status: 500 })
    }

    const match = url.pathname.match(/^\/room\/([A-Z0-9]{6})$/)
    if (match) {
      const stub = env.ROOMS.get(env.ROOMS.idFromName(match[1]))
      return stub.fetch(request)
    }

    return new Response('Not found', { status: 404 })
  },
}

export class Room {
  constructor(ctx, env) {
    this.ctx = ctx
    this.claimed = false
    this.members = new Map() // memberId -> { name }
    ctx.blockConcurrencyWhile(async () => {
      this.claimed = (await ctx.storage.get('claimed')) ?? false
    })
  }

  async fetch(request) {
    const url = new URL(request.url)

    if (url.pathname === '/claim') {
      if (this.claimed) return new Response('taken', { status: 409 })
      this.claimed = true
      await this.ctx.storage.put('claimed', true)
      return new Response('ok')
    }

    if (request.headers.get('Upgrade') !== 'websocket') {
      return new Response('expected websocket', { status: 400 })
    }
    if (!this.claimed) return this._denyUpgrade('not-found')
    if (this.members.size >= MAX_MEMBERS) return this._denyUpgrade('room-full')

    const { 0: client, 1: server } = new WebSocketPair()
    const name = (url.searchParams.get('name') || 'Listener').slice(0, 40)
    const memberId = crypto.randomUUID()

    this.ctx.acceptWebSocket(server, [memberId])
    this.members.set(memberId, { name })

    server.send(JSON.stringify({ type: 'joined', memberId, roster: this._roster() }))
    this._broadcastRoster()

    return new Response(null, { status: 101, webSocket: client })
  }

  // WebSocket upgrades must return status 101 with a socket either way —
  // briefly accept, tell the client why, then close.
  _denyUpgrade(reason) {
    const { 0: client, 1: server } = new WebSocketPair()
    server.accept()
    server.send(JSON.stringify({ type: 'join-denied', reason }))
    server.close(1008, reason)
    return new Response(null, { status: 101, webSocket: client })
  }

  _roster() {
    return [...this.members.entries()].map(([id, m]) => ({ id, name: m.name }))
  }

  _broadcastRoster() {
    const msg = JSON.stringify({ type: 'roster', members: this._roster() })
    for (const ws of this.ctx.getWebSockets()) ws.send(msg)
  }

  async webSocketMessage(ws, raw) {
    let msg
    try { msg = JSON.parse(raw) } catch { return }
    if (msg.type !== 'relay') return

    const [senderId] = this.ctx.getTags(ws)
    const out = JSON.stringify({ type: 'relay', from: senderId, payload: msg.payload })

    if (msg.to) {
      for (const target of this.ctx.getWebSockets(msg.to)) target.send(out)
    } else {
      for (const target of this.ctx.getWebSockets()) if (target !== ws) target.send(out)
    }
  }

  async webSocketClose(ws) {
    const [memberId] = this.ctx.getTags(ws)
    this.members.delete(memberId)
    this._broadcastRoster()
    if (this.members.size === 0) {
      this.claimed = false
      await this.ctx.storage.delete('claimed')
    }
  }

  async webSocketError(ws) {
    await this.webSocketClose(ws)
  }
}
