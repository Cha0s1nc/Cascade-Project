// Jellyfin HTTP client. No DOM, no Electron - uses only fetch and URL, both of
// which exist on webOS/Tizen and in React Native.

import type { JfItem, JfItemsResponse, JfAuthResult, JfParams, ServerConfig } from './types.ts'

const EMPTY_RESPONSE: JfItemsResponse = { Items: [], TotalRecordCount: 0 }

/**
 * Identifies this client to Jellyfin.
 *
 * `deviceId` must be unique per install. It used to be the constant
 * "cascade-app", which made every Cascade look like the same device: the server
 * could not tell two clients apart, so remote control could not target one of
 * them and two instances collided in the session list.
 */
export function authHeader(appVersion: string, deviceId: string): string {
  return `MediaBrowser Client="Cascade", Device="Cascade", DeviceId="${deviceId}", Version="${appVersion}"`
}

/** Default page size when a caller does not set params.Limit. */
const DEFAULT_PAGE_SIZE = 500

/**
 * Authenticate against a server. Standalone rather than a client method because
 * it runs before there is any config to construct a client with.
 */
export async function authenticate(
  serverUrl: string,
  username: string,
  password: string,
  appVersion: string,
  deviceId: string,
): Promise<JfAuthResult> {
  const res = await fetch(`${serverUrl}/Users/AuthenticateByName`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Emby-Authorization': authHeader(appVersion, deviceId),
    },
    body: JSON.stringify({ Username: username, Pw: password }),
  })
  if (!res.ok) {
    const txt = await res.text()
    throw new Error(txt || `${res.status}`)
  }
  return res.json() as Promise<JfAuthResult>
}

/** What the server hands back when a QuickConnect request is started. */
export interface QuickConnectStart {
  /** Shown to the user; they type it into Jellyfin on an already-signed-in device. */
  Code: string
  /** Opaque handle used to poll and then exchange for a token. Never shown. */
  Secret: string
}

interface QuickConnectState {
  Authenticated?: boolean
}

/** How often to ask the server whether the code has been approved. */
export const QUICK_CONNECT_POLL_MS = 2000

/** Give up after this long so a forgotten sign-in does not poll forever. */
export const QUICK_CONNECT_TIMEOUT_MS = 5 * 60 * 1000

/** Whether the server has QuickConnect switched on. Never throws - a server that
 *  404s this simply does not offer it. */
export async function quickConnectEnabled(serverUrl: string): Promise<boolean> {
  try {
    const res = await fetch(`${serverUrl}/QuickConnect/Enabled`)
    if (!res.ok) return false
    return await res.json() === true
  } catch {
    return false
  }
}

/**
 * Start a QuickConnect request and get the code to show the user.
 *
 * The device id matters here: Jellyfin ties the pending request to it, and it is
 * what the resulting token is bound to.
 */
export async function quickConnectInitiate(
  serverUrl: string,
  appVersion: string,
  deviceId: string,
): Promise<QuickConnectStart> {
  const res = await fetch(`${serverUrl}/QuickConnect/Initiate`, {
    method: 'POST',
    headers: { 'X-Emby-Authorization': authHeader(appVersion, deviceId) },
  })
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`)
  return res.json() as Promise<QuickConnectStart>
}

/** True once the user has approved the code on another device. */
export async function quickConnectApproved(serverUrl: string, secret: string): Promise<boolean> {
  const res = await fetch(`${serverUrl}/QuickConnect/Connect?secret=${encodeURIComponent(secret)}`)
  // 404 means the request expired or was cancelled server-side - treat as
  // still-pending rather than throwing, and let the timeout end it.
  if (!res.ok) return false
  const state = await res.json() as QuickConnectState
  return state?.Authenticated === true
}

/** Exchange an approved secret for a real access token. */
export async function quickConnectAuthenticate(
  serverUrl: string,
  secret: string,
  appVersion: string,
  deviceId: string,
): Promise<JfAuthResult> {
  const res = await fetch(`${serverUrl}/Users/AuthenticateWithQuickConnect`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Emby-Authorization': authHeader(appVersion, deviceId),
    },
    body: JSON.stringify({ Secret: secret }),
  })
  if (!res.ok) {
    const txt = await res.text()
    throw new Error(txt || `${res.status}`)
  }
  return res.json() as Promise<JfAuthResult>
}

export class JellyfinClient {
  // Written out longhand rather than as a constructor parameter property:
  // Node's strip-only TypeScript mode (what `npm test` uses) rejects those,
  // since they emit code instead of only removing types.
  private readonly getConfig: () => ServerConfig

  /**
   * Takes a *getter* rather than a config object because the renderer replaces
   * its `jf` object wholesale on connect (`jf = { ... }`). Holding a reference
   * to the old object would silently keep using stale credentials.
   */
  constructor(getConfig: () => ServerConfig) {
    this.getConfig = getConfig
  }

  private get config(): ServerConfig {
    return this.getConfig()
  }

  async get<T = JfItemsResponse>(path: string, params: JfParams = {}): Promise<T> {
    const { url, token } = this.config
    const target = new URL(`${url}${path}`)

    for (const [k, v] of Object.entries(params)) {
      // Skipping undefined rather than letting URLSearchParams stringify it to
      // the literal "undefined", which is never what a caller means.
      if (v === undefined) continue
      target.searchParams.set(k, String(v))
    }

    const res = await fetch(target, { headers: { 'X-Emby-Token': token } })
    if (!res.ok) throw new Error(`${res.status} ${res.statusText}`)
    return res.json() as Promise<T>
  }

  async post<T>(path: string, body: unknown, params: JfParams = {}): Promise<T> {
    const { url, token } = this.config
    const target = new URL(`${url}${path}`)
    for (const [k, v] of Object.entries(params)) {
      if (v === undefined) continue
      target.searchParams.set(k, String(v))
    }

    const res = await fetch(target, {
      method: 'POST',
      headers: { 'X-Emby-Token': token, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })
    if (!res.ok) throw new Error(`${res.status} ${res.statusText}`)
    return res.json() as Promise<T>
  }

  /**
   * Run the query against each selected library and merge, de-duplicating by Id.
   * With no libraries selected this is a plain `get`.
   *
   * Respects params.Limit per library - use `getAllPaged` when you need
   * everything.
   */
  async getMerged(path: string, params: JfParams = {}): Promise<JfItemsResponse> {
    const ids = this.config.libraryIds || []
    if (!ids.length) return this.get<JfItemsResponse>(path, params)

    const results = await Promise.all(ids.map(libId =>
      this.get<JfItemsResponse>(path, { ...params, ParentId: libId })
        .catch(() => EMPTY_RESPONSE)
    ))

    return dedupeById(results.map(r => r.Items || []))
  }

  /**
   * Like `getMerged`, but paginates each library until every matching item is
   * fetched instead of stopping at params.Limit. Pages within a library are
   * fetched in parallel once the first page reveals TotalRecordCount.
   */
  async getAllPaged(path: string, params: JfParams = {}): Promise<JfItemsResponse> {
    const configured = this.config.libraryIds
    const ids: (string | null)[] = configured?.length ? configured : [null]
    const pageSize = Number(params.Limit) || DEFAULT_PAGE_SIZE

    const perLibrary = await Promise.all(ids.map(async libId => {
      const baseParams = libId ? { ...params, ParentId: libId } : params

      const first = await this.get<JfItemsResponse>(path, { ...baseParams, StartIndex: 0 })
        .catch(() => EMPTY_RESPONSE)

      const items = [...(first.Items || [])]
      const total = first.TotalRecordCount ?? items.length

      if (total > items.length) {
        const starts: number[] = []
        for (let start = items.length; start < total; start += pageSize) starts.push(start)

        const pages = await Promise.all(starts.map(start =>
          this.get<JfItemsResponse>(path, { ...baseParams, StartIndex: start })
            .catch(() => EMPTY_RESPONSE)
        ))
        for (const p of pages) items.push(...(p.Items || []))
      }

      return items
    }))

    return dedupeById(perLibrary)
  }

  /** Primary image URL for an item. No tag means no art, so no URL. */
  artUrl(itemId: string, tag: string | undefined | null): string | null {
    if (!tag) return null
    return this.imageUrl(itemId)
  }

  /** Artists always render a placeholder, so this has no tag guard. */
  artistArtUrl(itemId: string): string {
    return this.imageUrl(itemId)
  }

  private imageUrl(itemId: string): string {
    const { url, token } = this.config
    return `${url}/Items/${itemId}/Images/Primary?fillHeight=600&fillWidth=600&quality=90&api_key=${token}`
  }
}

/** Flatten item lists, keeping the first occurrence of each Id. */
function dedupeById(lists: JfItem[][]): JfItemsResponse {
  const seen = new Set<string>()
  const items: JfItem[] = []
  for (const list of lists) {
    for (const item of list) {
      if (seen.has(item.Id)) continue
      seen.add(item.Id)
      items.push(item)
    }
  }
  return { Items: items, TotalRecordCount: items.length }
}
