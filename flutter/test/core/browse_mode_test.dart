// Ported from desktop/test/browse-mode.test.ts (sectionMode is tested against nav.dart).
import 'package:cascade/core/browse_mode.dart';
import 'package:cascade/core/nav.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sectionMode classifies music and video views correctly', () {
    for (final v in ['albums', 'artists', 'songs', 'playlists', 'genres', 'history', 'radio']) {
      expect(sectionMode(v), 'music');
    }
    expect(sectionMode('movies'), 'video');
    expect(sectionMode('shows'), 'video');
  });

  test('sectionMode returns null for views shown in every mode', () {
    expect(sectionMode('home'), isNull);
    expect(sectionMode('settings'), isNull);
  });

  test('a fresh install with a video library defaults to music', () {
    expect(resolveBrowseMode(null, true), 'music');
  });

  test('a saved video choice sticks when a video library exists', () {
    expect(resolveBrowseMode('video', true), 'video');
  });

  test('a saved music choice, or anything unrecognized, resolves to music', () {
    expect(resolveBrowseMode('music', true), 'music');
    expect(resolveBrowseMode('garbage', true), 'music');
  });

  test('no video library forces music regardless of what was saved', () {
    expect(resolveBrowseMode('video', false), 'music');
    expect(resolveBrowseMode('music', false), 'music');
    expect(resolveBrowseMode(null, false), 'music');
  });
}
