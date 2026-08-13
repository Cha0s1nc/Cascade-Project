import { test } from 'node:test'
import assert from 'node:assert/strict'
import { RemoteControl, SUPPORTED_COMMANDS } from '../src/core/remote-control.ts'
import { JellyfinClient } from '../src/core/jellyfin.ts'
import type { RemoteHandlers } from '../src/core/remote-control.ts'
import type { ServerConfig } from '../src/core/types.ts'

const config: ServerConfig = {
  url: 'https://jf.test', token: 'TOK', userId: 'U1', deviceId: 'DEV-1',
}

/** Records every handler call so tests can assert on dispatch. */
function recorder() {
  const log: string[] = []
  const handlers: RemoteHandlers = {
    play: (ids, start, cmd) => { log.push(`play:${ids.join('+')}:${start}:${cmd}`) },
    playPause:     () => { log.push('playPause') },
    pause:         () => { log.push('pause') },
    unpause:       () => { log.push('unpause') },
    stop:          () => { log.push('stop') },
    nextTrack:     () => { log.push('next') },
    previousTrack: () => { log.push('prev') },
    seek:          t  => { log.push(`seek:${t}`) },
    setVolume:     v  => { log.push(`vol:${v}`) },
    volumeUp:      () => { log.push('volUp') },
    volumeDown:    () => { log.push('volDown') },
    toggleMute:    () => { log.push('toggleMute') },
    setMute:       m  => { log.push(`mute:${m}`) },
  }
  return { log, handlers }
}

const build = (gate: () => boolean = () => true) => {
  const { log, handlers } = recorder()
  const client = new JellyfinClient(() => config)
  return { log, remote: new RemoteControl(client, () => config, handlers, gate) }
}

test('dispatches PlayState commands', () => {
  const { log, remote } = build()
  for (const Command of ['PlayPause', 'Pause', 'Unpause', 'Stop', 'NextTrack', 'PreviousTrack']) {
    remote.handleMessage({ MessageType: 'PlayState', Data: { Command } })
  }
  assert.deepEqual(log, ['playPause', 'pause', 'unpause', 'stop', 'next', 'prev'])
})

test('accepts the "Playstate" spelling too', () => {
  // Jellyfin has shipped both casings; treating one as unknown drops commands.
  const { log, remote } = build()
  remote.handleMessage({ MessageType: 'Playstate', Data: { Command: 'Pause' } })
  assert.deepEqual(log, ['pause'])
})

test('seek passes ticks straight through', () => {
  const { log, remote } = build()
  remote.handleMessage({ MessageType: 'PlayState', Data: { Command: 'Seek', SeekPositionTicks: 12_345 } })
  assert.deepEqual(log, ['seek:12345'])
})

test('Play carries item ids, start index and command', () => {
  const { log, remote } = build()
  remote.handleMessage({
    MessageType: 'Play',
    Data: { ItemIds: ['a', 'b'], StartIndex: 1, PlayCommand: 'PlayNow' },
  })
  assert.deepEqual(log, ['play:a+b:1:PlayNow'])
})

test('Play defaults a missing start index and command', () => {
  const { log, remote } = build()
  remote.handleMessage({ MessageType: 'Play', Data: { ItemIds: ['a'] } })
  assert.deepEqual(log, ['play:a:0:PlayNow'])
})

test('GeneralCommand volume arrives as a string and is clamped', () => {
  const { log, remote } = build()
  remote.handleMessage({ MessageType: 'GeneralCommand', Data: { Name: 'SetVolume', Arguments: { Volume: '55' } } })
  remote.handleMessage({ MessageType: 'GeneralCommand', Data: { Name: 'SetVolume', Arguments: { Volume: '900' } } })
  remote.handleMessage({ MessageType: 'GeneralCommand', Data: { Name: 'SetVolume', Arguments: { Volume: '-5' } } })
  remote.handleMessage({ MessageType: 'GeneralCommand', Data: { Name: 'SetVolume', Arguments: { Volume: 'junk' } } })
  assert.deepEqual(log, ['vol:55', 'vol:100', 'vol:0', 'vol:0'])
})

test('mute and step-volume commands map to their own handlers', () => {
  const { log, remote } = build()
  for (const Name of ['ToggleMute', 'Mute', 'Unmute', 'VolumeUp', 'VolumeDown']) {
    remote.handleMessage({ MessageType: 'GeneralCommand', Data: { Name } })
  }
  assert.deepEqual(log, ['toggleMute', 'mute:true', 'mute:false', 'volUp', 'volDown'])
})

test('the gate refuses commands without invoking handlers', () => {
  // This is B4: in a Waterfall room every incoming cast command is dropped.
  const { log, remote } = build(() => false)
  remote.handleMessage({ MessageType: 'PlayState', Data: { Command: 'Pause' } })
  remote.handleMessage({ MessageType: 'Play', Data: { ItemIds: ['a'] } })
  remote.handleMessage({ MessageType: 'GeneralCommand', Data: { Name: 'SetVolume', Arguments: { Volume: '10' } } })
  assert.deepEqual(log, [], 'nothing should have run')
})

test('unknown messages and keepalives are ignored, not crashes', () => {
  const { log, remote } = build()
  remote.handleMessage({ MessageType: 'KeepAlive' })
  remote.handleMessage({ MessageType: 'Sessions', Data: {} })
  remote.handleMessage({})
  remote.handleMessage({ MessageType: 'PlayState', Data: { Command: 'Nonsense' } })
  remote.handleMessage({ MessageType: 'GeneralCommand', Data: { Name: 'Nonsense' } })
  assert.deepEqual(log, [])
})

test('stop() is safe before start()', () => {
  const { remote } = build()
  assert.doesNotThrow(() => remote.stop())
  assert.equal(remote.connected, false)
})

test('SupportedCommands contains no PlaystateCommand values', () => {
  // Regression guard. Jellyfin rejects the ENTIRE capabilities registration
  // with a 400 if this list contains anything that is not a GeneralCommandType,
  // which leaves the client invisible as a cast target with no other symptom.
  // Playstate commands still arrive over the socket; they are implied by
  // SupportsMediaControl and must not be declared here.
  const PLAYSTATE_ONLY = ['Pause', 'PlayPause', 'Stop', 'NextTrack', 'PreviousTrack', 'Seek']
  for (const bad of PLAYSTATE_ONLY) {
    assert.ok(
      !(SUPPORTED_COMMANDS as readonly string[]).includes(bad),
      `${bad} is a PlaystateCommand and will 400 the registration`,
    )
  }
})

test('every declared command has a handler', () => {
  // A declared command with no handler is a dead button in the controller UI.
  const { log, remote } = build()
  const generalOnly = (SUPPORTED_COMMANDS as readonly string[]).filter(c => c !== 'Play' && c !== 'PlayState')
  for (const Name of generalOnly) {
    remote.handleMessage({
      MessageType: 'GeneralCommand',
      Data: { Name, Arguments: { Volume: '50' } },
    })
  }
  assert.equal(log.length, generalOnly.length, `unhandled command among ${generalOnly.join(', ')}`)
})
