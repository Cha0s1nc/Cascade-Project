// Ported from desktop/test/remote-control.test.ts (the socket lifecycle test is not ported).
import 'package:cascade/core/remote_control.dart';
import 'package:flutter_test/flutter_test.dart';

({List<String> log, RemoteDispatcher remote}) build([bool Function()? gate]) {
  final log = <String>[];
  final handlers = RemoteHandlers(
    play: (ids, start, cmd) => log.add('play:${ids.join('+')}:$start:$cmd'),
    playPause: () => log.add('playPause'),
    pause: () => log.add('pause'),
    unpause: () => log.add('unpause'),
    stop: () => log.add('stop'),
    nextTrack: () => log.add('next'),
    previousTrack: () => log.add('prev'),
    seek: (t) => log.add('seek:${t.toInt()}'),
    setVolume: (v) => log.add('vol:${v.toInt()}'),
    volumeUp: () => log.add('volUp'),
    volumeDown: () => log.add('volDown'),
    toggleMute: () => log.add('toggleMute'),
    setMute: (m) => log.add('mute:$m'),
    showMessage: (m) => log.add('message:${m.header}:${m.text}:${m.timeoutMs}'),
  );
  return (log: log, remote: gate == null ? RemoteDispatcher(handlers) : RemoteDispatcher(handlers, gate));
}

void main() {
  test('dispatches PlayState commands', () {
    final b = build();
    for (final c in ['PlayPause', 'Pause', 'Unpause', 'Stop', 'NextTrack', 'PreviousTrack']) {
      b.remote.handleMessage({'MessageType': 'PlayState', 'Data': {'Command': c}});
    }
    expect(b.log, ['playPause', 'pause', 'unpause', 'stop', 'next', 'prev']);
  });

  test('accepts the "Playstate" spelling too', () {
    final b = build();
    b.remote.handleMessage({'MessageType': 'Playstate', 'Data': {'Command': 'Pause'}});
    expect(b.log, ['pause']);
  });

  test('seek passes ticks straight through', () {
    final b = build();
    b.remote.handleMessage({'MessageType': 'PlayState', 'Data': {'Command': 'Seek', 'SeekPositionTicks': 12345}});
    expect(b.log, ['seek:12345']);
  });

  test('Play carries item ids, start index and command, and defaults the missing ones', () {
    final b = build();
    b.remote.handleMessage({'MessageType': 'Play', 'Data': {'ItemIds': ['a', 'b'], 'StartIndex': 1, 'PlayCommand': 'PlayNow'}});
    b.remote.handleMessage({'MessageType': 'Play', 'Data': {'ItemIds': ['a']}});
    expect(b.log, ['play:a+b:1:PlayNow', 'play:a:0:PlayNow']);
  });

  test('GeneralCommand volume arrives as a string and is clamped', () {
    final b = build();
    for (final v in ['55', '900', '-5', 'junk']) {
      b.remote.handleMessage({'MessageType': 'GeneralCommand', 'Data': {'Name': 'SetVolume', 'Arguments': {'Volume': v}}});
    }
    expect(b.log, ['vol:55', 'vol:100', 'vol:0', 'vol:0']);
  });

  test('mute and step-volume commands map to their own handlers', () {
    final b = build();
    for (final n in ['ToggleMute', 'Mute', 'Unmute', 'VolumeUp', 'VolumeDown']) {
      b.remote.handleMessage({'MessageType': 'GeneralCommand', 'Data': {'Name': n}});
    }
    expect(b.log, ['toggleMute', 'mute:true', 'mute:false', 'volUp', 'volDown']);
  });

  test('the gate refuses commands without invoking handlers', () {
    final b = build(() => false);
    b.remote.handleMessage({'MessageType': 'PlayState', 'Data': {'Command': 'Pause'}});
    b.remote.handleMessage({'MessageType': 'Play', 'Data': {'ItemIds': ['a']}});
    b.remote.handleMessage({'MessageType': 'GeneralCommand', 'Data': {'Name': 'SetVolume', 'Arguments': {'Volume': '10'}}});
    expect(b.log, isEmpty);
  });

  test('unknown messages and keepalives are ignored, not crashes', () {
    final b = build();
    b.remote.handleMessage({'MessageType': 'KeepAlive'});
    b.remote.handleMessage({'MessageType': 'Sessions', 'Data': {}});
    b.remote.handleMessage({});
    b.remote.handleMessage({'MessageType': 'PlayState', 'Data': {'Command': 'Nonsense'}});
    b.remote.handleMessage({'MessageType': 'GeneralCommand', 'Data': {'Name': 'Nonsense'}});
    expect(b.log, isEmpty);
  });

  test('SupportedCommands contains no PlaystateCommand values', () {
    for (final bad in ['Pause', 'PlayPause', 'Stop', 'NextTrack', 'PreviousTrack', 'Seek']) {
      expect(supportedCommands.contains(bad), isFalse, reason: '$bad is a PlaystateCommand and will 400 the registration');
    }
  });

  test('every declared command has a handler', () {
    final b = build();
    final generalOnly = supportedCommands.where((c) => c != 'Play' && c != 'PlayState');
    for (final n in generalOnly) {
      b.remote.handleMessage({'MessageType': 'GeneralCommand', 'Data': {'Name': n, 'Arguments': {'Volume': '50', 'Header': 'H', 'Text': 'T'}}});
    }
    expect(b.log.length, generalOnly.length);
  });

  test('a dashboard message shows even when commands are gated', () {
    final b = build(() => false);
    b.remote.handleMessage({'MessageType': 'GeneralCommand', 'Data': {'Name': 'DisplayMessage', 'Arguments': {'Header': 'Hi', 'Text': 'Restart at 2', 'TimeoutMs': '4000'}}});
    b.remote.handleMessage({'MessageType': 'GeneralCommand', 'Data': {'Name': 'DisplayMessage', 'Arguments': {}}});
    b.remote.handleMessage({'MessageType': 'GeneralCommand', 'Data': {'Name': 'Mute', 'Arguments': {}}});
    expect(b.log, ['message:Hi:Restart at 2:4000']);
  });

  test('capabilities body, socket URL and keepalive interval', () {
    expect(remoteCapabilitiesBody()['SupportsMediaControl'], true);
    expect(remoteSocketUrl('https://jf.test', 'TOK', 'DEV 1'), 'wss://jf.test/socket?ApiKey=TOK&deviceId=DEV%201');
    expect(remoteSocketUrl('http://h:8096', 't', null), 'ws://h:8096/socket?ApiKey=t&deviceId=');
    expect(forceKeepAliveIntervalMs(60), 30000);
    expect(forceKeepAliveIntervalMs('junk'), 30000);
    expect(forceKeepAliveIntervalMs(0.2), 500);
  });
}
