// What a Jellyfin server says to people outside playback: a DisplayMessage an
// admin sends from the dashboard, and the login disclaimer from Branding. Both
// are plain text. Pure. Ported from desktop/src/core/server-messages.ts (the
// fetch of the disclaimer is not ported; hand its LoginDisclaimer to
// loginDisclaimerText).

/// A message to show: [timeoutMs] is null when it stays until closed.
typedef ServerMessage = ({String header, String text, int? timeoutMs});

const _maxHeader = 120;
const _maxText = 2000;

final _controlChars = RegExp(r'[\u0000-\u0008\u000b-\u001f\u007f]');

String _cap(String s, int max) => s.length > max ? s.substring(0, max) : s;

/// Text for display: control characters out, trimmed, capped. Anything not a string is ''.
String cleanText(Object? v, int max) => v is String ? _cap(v.replaceAll(_controlChars, '').trim(), max) : '';

/// A DisplayMessage command's arguments, or null when there is nothing to show.
ServerMessage? parseDisplayMessage(Object? args) {
  final a = args is Map ? args : const {};
  final header = cleanText(a['Header'], _maxHeader);
  final text = cleanText(a['Text'], _maxText);
  if (header.isEmpty && text.isEmpty) return null;
  final t = a['TimeoutMs'];
  final ms = t is num ? t.toDouble() : (t is String ? double.tryParse(t.trim()) : null);
  return (
    header: header.isEmpty ? 'Message from your server' : header,
    text: text,
    timeoutMs: ms != null && ms.isFinite && ms > 0 ? (ms < 600000 ? ms : 600000).round() : null,
  );
}

const _entities = {'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': ' '};

/// The Branding LoginDisclaimer as plain text: line breaks kept, tags dropped, common entities decoded.
String loginDisclaimerText(Object? raw) {
  if (raw is! String) return '';
  var s = raw
      .replaceAll(RegExp(r'<\s*br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<\/\s*(p|div|li|h[1-6])\s*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAllMapped(RegExp(r'&(#\d+|#x[0-9a-f]+|[a-z]+);', caseSensitive: false), (m) {
        final e = m[1]!;
        if (e[0] == '#') {
          final n = e[1].toLowerCase() == 'x' ? int.tryParse(e.substring(2), radix: 16) : int.tryParse(e.substring(1));
          return n != null && n > 31 && n < 0x110000 ? String.fromCharCode(n) : '';
        }
        return _entities[e.toLowerCase()] ?? m[0]!;
      });
  s = s.split('\n').map((l) => l.replaceAll(RegExp(r'[ \t]+'), ' ').trim()).join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  return _cap(s, _maxText);
}
