// Ported from desktop/test/server-messages.test.ts (the fetch test is not ported).
import 'package:cascade/core/server_messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a dashboard message reads its header, text and timeout', () {
    expect(parseDisplayMessage({'Header': 'Maintenance', 'Text': 'Restarting at 2', 'TimeoutMs': '5000'}), (
      header: 'Maintenance',
      text: 'Restarting at 2',
      timeoutMs: 5000,
    ));
    expect(parseDisplayMessage({'Text': 'hi'}), (header: 'Message from your server', text: 'hi', timeoutMs: null));
    expect(parseDisplayMessage({}), isNull);
    expect(parseDisplayMessage(null), isNull);
    expect(parseDisplayMessage({'Header': 'x', 'TimeoutMs': 'soon'})?.timeoutMs, isNull);
    expect(parseDisplayMessage({'Header': 'x', 'TimeoutMs': '9999999'})?.timeoutMs, 600000);
  });

  test('the login disclaimer comes out as plain text', () {
    expect(loginDisclaimerText('<p>Welcome to <b>Chaos</b> &amp; friends.</p><p>Be nice.<br>Thanks</p>'), 'Welcome to Chaos & friends.\nBe nice.\nThanks');
    expect(loginDisclaimerText('<script>alert(1)</script>ok'), 'alert(1)ok');
    expect(loginDisclaimerText(42), '');
    expect(loginDisclaimerText('caf&#233; &#x2014;'), 'café \u2014');
  });
}
