// Mobile host implementation of the Platform contract. Implements the
// required `Platform` interface and deliberately omits every
// `DesktopCapabilities` member - see packages/core/src/platform/index.ts.
import { Platform as RNPlatform } from 'react-native'
import DeviceInfo from 'react-native-device-info'
import * as Keychain from 'react-native-keychain'
import { MMKV } from 'react-native-mmkv'

import type { Platform, PlatformStorage } from '@cascade/core'

// Same key strings apps/desktop/renderer.js uses via window.cascade.store, so
// a future settings sync is a straight copy. 'token' and 'password' are the
// only two the desktop app treats as secrets; everything else is a plain
// setting.
const CREDENTIAL_KEYS = new Set(['token', 'password'])

const mmkv = new MMKV({ id: 'cascade' })

// MMKV.set only accepts boolean | string | number | ArrayBuffer, not the
// schemaless `unknown` PlatformStorage.set takes. Round-tripping every value
// through JSON keeps `get` returning exactly what was passed to `set`
// (electron-store's behavior on desktop), whether that's a bare boolean, a
// number, or a caller-pre-stringified JSON blob like the 'theme' key.
const mmkvStorage: PlatformStorage = {
  async get(key) {
    const raw = mmkv.getString(key)
    if (raw === undefined) return undefined
    try {
      return JSON.parse(raw)
    } catch {
      // Anything this adapter wrote is valid JSON, so reaching here means a
      // value from somewhere else - a migration, a hand-edited store. Returning
      // it raw beats throwing: a settings read must not be able to take the app
      // down, and a plain string is what the caller most likely wanted anyway.
      return raw
    }
  },
  async set(key, value) {
    mmkv.set(key, JSON.stringify(value))
  },
  async delete(key) {
    mmkv.delete(key)
  },
}

// One keychain "service" per credential key, so 'token' and 'password' don't
// collide. The username field is unused; the secret lives in `password`.
const keychainStorage: PlatformStorage = {
  async get(key) {
    const result = await Keychain.getGenericPassword({ service: key })
    return result === false ? undefined : result.password
  },
  async set(key, value) {
    await Keychain.setGenericPassword(key, String(value), { service: key })
  },
  async delete(key) {
    await Keychain.resetGenericPassword({ service: key })
  },
}

const store: PlatformStorage = {
  get: (key) => (CREDENTIAL_KEYS.has(key) ? keychainStorage : mmkvStorage).get(key),
  set: (key, value) => (CREDENTIAL_KEYS.has(key) ? keychainStorage : mmkvStorage).set(key, value),
  delete: (key) => (CREDENTIAL_KEYS.has(key) ? keychainStorage : mmkvStorage).delete(key),
}

export const platform: Platform = {
  store,
  platform: RNPlatform.OS,
  getVersion: () => Promise.resolve(DeviceInfo.getVersion()),
}
