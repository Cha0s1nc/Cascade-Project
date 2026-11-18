// What Now Playing covers waits until it has slid all the way down.
import 'package:cascade/ui/now_playing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('showing stays on through the slide down, then clears', (tester) async {
    final np = NowPlaying()..show(NpPanel.lyrics);
    expect(np.showing, isTrue);
    np.close();
    expect((np.open, np.showing), (false, true), reason: 'still sliding down');
    np.settled();
    expect(np.showing, isFalse);

    np
      ..show(NpPanel.lyrics)
      ..close();
    await tester.pump(const Duration(seconds: 1));
    expect(np.showing, isFalse, reason: 'the fallback clears it if no animation reports');
  });
}
