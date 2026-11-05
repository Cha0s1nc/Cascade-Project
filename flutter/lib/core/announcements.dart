// Announcements from the Cascade project and from a Cascade Server plugin, and
// the inbox over them. Pure, text only. Ported from
// desktop/src/core/announcements.ts. `kind` comes from where an entry was
// read, never from its contents, so a server cannot dress up as the project.
import 'server_messages.dart';
import 'update_release.dart';

/// One inbox entry. [kind] is 'official' or 'server'; [source] names the server for its entries.
typedef Announcement = ({String id, String date, String title, String body, String? link, String kind, String? source});

const _maxId = 80;
const _maxTitle = 120;
const _maxBody = 4000;
const _maxEntries = 50;
const _maxSource = 120;
final _dateRe = RegExp(r'^\d{4}-\d{2}-\d{2}$');

bool _isDate(Object? v) => v is String && _dateRe.hasMatch(v) && DateTime.tryParse(v) != null;

/// The entries for this app and version that have not expired, newest first. [nowMs] is epoch millis (default now).
List<Announcement> parseAnnouncements(Object? raw, String platform, String version, {int? nowMs, String kind = 'official'}) {
  if (raw is! List) return [];
  final today = DateTime.fromMillisecondsSinceEpoch(nowMs ?? DateTime.now().millisecondsSinceEpoch, isUtc: true).toIso8601String().substring(0, 10);
  final out = <Announcement>[];
  final ids = <String>{};
  for (final e in raw) {
    if (e is! Map) continue;
    final id = cleanText(e['id'], _maxId);
    final title = cleanText(e['title'], _maxTitle);
    if (id.isEmpty || title.isEmpty || !_isDate(e['date']) || ids.contains(id)) continue;
    final platforms = e['platforms'];
    if (platforms is List && !platforms.contains(platform)) continue;
    if (e['minVersion'] is String && isNewerVersion(e['minVersion'], version)) continue;
    if (e['maxVersion'] is String && isNewerVersion(version, e['maxVersion'])) continue;
    if (_isDate(e['expires']) && (e['expires'] as String).compareTo(today) < 0) continue;
    ids.add(id);
    final l = e['link'];
    final link = l is String && RegExp(r'^https://[^\s]+$', caseSensitive: false).hasMatch(l) ? l : null;
    final source = cleanText(e['source'], _maxSource);
    out.add((id: id, date: e['date'] as String, title: title, body: cleanText(e['body'], _maxBody), link: link, kind: kind, source: source.isEmpty ? null : source));
  }
  // Stable newest-first: Dart's sort is not stable, so break date ties by position.
  final pos = {for (var i = 0; i < out.length; i++) out[i].id: i};
  out.sort((x, y) {
    final c = y.date.compareTo(x.date);
    return c != 0 ? c : pos[x.id]!.compareTo(pos[y.id]!);
  });
  return out.take(_maxEntries).toList();
}

/// A Cascade Server plugin's posts, ids namespaced per server and labeled with its name; none when the answer is not shaped like one.
List<Announcement> parseServerAnnouncements(Object? raw, String platform, String version, {int? nowMs}) {
  final r = raw is Map ? raw : const {};
  final server = r['server'] is Map ? r['server'] as Map : const {};
  final serverId = cleanText(server['id'], 64);
  if (serverId.isEmpty) return [];
  final name = cleanText(server['name'], _maxSource);
  final source = name.isEmpty ? 'Your server' : name;
  return [
    for (final a in parseAnnouncements(r['items'], platform, version, nowMs: nowMs, kind: 'server'))
      (id: 'server:$serverId:${a.id}', date: a.date, title: a.title, body: a.body, link: a.link, kind: a.kind, source: source),
  ];
}

/// The stored dashboard messages with this one first, as the store keeps them (read back with parseAnnouncements, kind 'server'). The oldest fall off.
List<Object?> addServerMessage(Object? stored, ServerMessage message, String serverName, {int? nowMs}) {
  final ms = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final date = '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  final name = cleanText(serverName, _maxSource);
  final entry = {'id': 'message:${ms.toRadixString(36)}', 'date': date, 'title': message.header, 'body': message.text, 'source': name.isEmpty ? 'Your server' : name};
  return [entry, if (stored is List) ...stored].take(_maxEntries).toList();
}

/// Stored id lists are untrusted: anything that is not a list of strings is empty.
List<String> idList(Object? v) => v is List ? v.whereType<String>().toList() : [];

/// What the inbox shows, and how many of those are new since it was last opened.
({List<Announcement> items, int unseen}) announcementInbox(List<Announcement> list, Object? dismissed, Object? seen) {
  final gone = idList(dismissed).toSet();
  final old = idList(seen).toSet();
  final items = list.where((a) => !gone.contains(a.id)).toList();
  return (items: items, unseen: items.where((a) => !old.contains(a.id)).length);
}
