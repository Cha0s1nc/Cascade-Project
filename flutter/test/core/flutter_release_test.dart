import 'package:cascade/core/update_release.dart';
import 'package:flutter_test/flutter_test.dart';

ReleaseLike release(List<String> names) => {
  'tag_name': 'v2.5.0',
  'assets': [for (final n in names) {'name': n, 'browser_download_url': 'https://example.invalid/$n'}],
};

void main() {
  final both = release(['Cascade-Flutter-Setup-x64.exe', 'Cascade-Flutter-linux-x64.tar.gz', 'versions.json']);

  test('a Flutter build needs the flutter entry and this computer\'s file', () {
    expect(flutterBuildOf(both, '{"desktop":"2.4.1","flutter":"2.5.0"}', 'windows', 'x64')?.asset['name'], 'Cascade-Flutter-Setup-x64.exe');
    expect(flutterBuildOf(both, '{"flutter":"2.5.0-b2"}', 'linux', 'x64')?.version, '2.5.0-b2');
    expect(flutterBuildOf(both, '{"desktop":"2.4.1"}', 'windows', 'x64'), isNull);
    expect(flutterBuildOf(release(['Cascade-Flutter-Setup-x64.exe']), '{"flutter":"2.5.0"}', 'linux', 'x64'), isNull);
    expect(flutterBuildOf(both, '{"flutter":"2.5.0"}', 'linux', 'arm64'), isNull);
    expect(flutterBuildOf(both, '{"flutter":"2.5.0"}', 'macos', 'arm64'), isNull);
  });

  test('a bad flutter entry is no entry', () {
    for (final t in ['{"flutter":"v2.5.0"}', '{"flutter":2.5}', '[]', 'nope', null]) {
      expect(flutterVersionOf(t), isNull, reason: '$t');
    }
  });
}
