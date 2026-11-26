import 'package:cascade/core/electron_import.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('switching back keeps the desktop file\'s own types and keys', () async {
    SharedPreferences.setMockInitialValues({
      'crossfadeEnabled': true,
      'volume': 0.4,
      'libraryIds': ['a', 'b'],
      'repeatMode': 'all',
      'server': 'https://jf.example',
      'token': 'tok',
      'userId': 'u1',
      'userName': 'me',
      'deviceId': 'd1',
      'shuffle': true,
    });
    final p = await SharedPreferences.getInstance();
    final config = {'crossfadeEnabled': 'false', 'volume': 1.0, 'libraryIds': '["x"]', 'theme': {'mode': 'dark'}, 'windowState': 1};
    final out = electronExport(p, config);
    expect(out['crossfadeEnabled'], 'true'); // the desktop kept it as a string
    expect(out['volume'], 0.4);
    expect(out['libraryIds'], '["a","b"]'); // and this as JSON text
    expect(out.containsKey('repeatMode'), isFalse); // not in the file: the desktop's default stays
    expect(out.containsKey('shuffle'), isFalse);
    expect(out['theme'], {'mode': 'dark'});
    expect(out['windowState'], 1);
    expect([out['serverUrl'], out['token'], out['userId'], out['username'], out['deviceId']], ['https://jf.example', 'tok', 'u1', 'me', 'd1']);
  });
}
