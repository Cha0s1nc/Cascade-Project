import 'package:flutter_test/flutter_test.dart';

import 'package:cascade/core/electron_import.dart';

void main() {
  test('the desktop\'s types become typed settings', () {
    final s = electronSettings({
      'crossfadeEnabled': true,
      'discordRpcEnabled': 'true', // the desktop kept this one as a string
      'crossfadeSeconds': 8,
      'maxStreamingBitrate': '320000',
      'volume': 0.5,
      'repeatMode': 'all',
      'libraryIds': ['a', 'b', 3],
      'movieLibraryIds': '["m"]',
      'eqMusic': {
        'enabled': true,
        'bands': [1, 2, 3, 4, 5],
      },
      'smartPlaylists': '[]',
      'token': 'secret',
      'serverUrl': 'https://example.test',
    });
    expect(s['crossfadeEnabled'], true);
    expect(s['discordRpcEnabled'], true);
    expect(s['crossfadeSeconds'], 8);
    expect(s['maxStreamingBitrate'], 320000);
    expect(s['volume'], 0.5);
    expect(s['repeatMode'], 'all');
    expect(s['libraryIds'], ['a', 'b']);
    expect(s['movieLibraryIds'], ['m']);
    expect(s['eqMusic'], '{"enabled":true,"bands":[1,2,3,4,5]}');
    expect(s['smartPlaylists'], '[]');
    expect(s.containsKey('token'), isFalse); // the sign-in stays with the desktop
    expect(s.containsKey('serverUrl'), isFalse);
  });

  test('garbage is left out, not guessed', () {
    final s = electronSettings({'crossfadeEnabled': 'yes', 'volume': 'loud', 'libraryIds': 7, 'repeatMode': ''});
    expect(s, isEmpty);
  });
}
