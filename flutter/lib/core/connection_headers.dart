// The reverse proxy headers in use, kept under the desktop's `customHeaders`
// store key. Jellyfin.headers adds them to every request to the server, and
// only there (lyrics providers, the Waterfall relay and the site never see
// them). The rules themselves are in custom_headers.dart.
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:cascade/core/custom_headers.dart';

List<CustomHeader> connectionHeaders = [];

Future<void> loadConnectionHeaders() async {
  final raw = (await SharedPreferences.getInstance()).getString('customHeaders');
  try {
    connectionHeaders = raw == null ? [] : sanitizeCustomHeaders(jsonDecode(raw));
  } on FormatException {
    connectionHeaders = [];
  }
}

Future<void> saveConnectionHeaders(List<CustomHeader> headers) async {
  final list = [
    for (final h in headers) {'name': h.name, 'value': h.value},
  ];
  connectionHeaders = sanitizeCustomHeaders(list);
  final p = await SharedPreferences.getInstance();
  if (connectionHeaders.isEmpty) {
    await p.remove('customHeaders');
  } else {
    await p.setString(
      'customHeaders',
      jsonEncode([
        for (final h in connectionHeaders) {'name': h.name, 'value': h.value},
      ]),
    );
  }
}
