import 'dart:convert';
import 'dart:io';

import 'package:cascade/core/jellyfin.dart';
import 'package:cascade/core/library.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('a server that was down at launch is tried again until it answers', (tester) async {
    SharedPreferences.setMockInitialValues({});
    var up = false, loaded = 0;
    final jf = Jellyfin(
      'https://jf.test',
      'D',
      token: 'T',
      userId: 'U',
      client: MockClient((req) async {
        if (!up) throw const SocketException('Connection refused');
        final body = switch (req.url.path) {
          '/UserViews' => {
            'Items': [
              {'Id': 'm', 'CollectionType': 'music'},
            ],
          },
          '/Users/U' => {'Policy': <String, Object>{}},
          _ => {'Items': <Object>[]},
        };
        return http.Response(jsonEncode(body), 200);
      }),
    );
    final lib = Library()..onLoaded = () => loaded++;
    await lib.use(jf);
    expect(lib.error, contains('trying again in 5 s'));
    expect(loaded, 0);

    up = true;
    await tester.pump(const Duration(seconds: 6));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(lib.error, isNull);
    expect(lib.musicLibs, hasLength(1));
    expect(loaded, 1);
    lib.dispose();
  });
}
