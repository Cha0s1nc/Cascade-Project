// Sending what happened offline. Pure: the app fetches and posts, this decides.
// Ported from desktop/src/core/offline-sync.ts; both pass shared/fixtures/
// offline-sync.json. Plays are history, replayed only when the server's history
// still matches the snapshot taken online. Positions, played marks and
// favorites are per item, coalesced, each sent only when the server's
// LastPlayedDate is older than the change.
//
// Changes, plays and updates are the JSON Maps the desktop stores. HistoryEntry
// and historyEntriesOf come from offline-index.ts, which is not ported as a
// whole; only what this file needs is here.
import 'jellyfin.dart' show Item;

/// A change made offline: `{itemId, userId, at, kind: 'position'|'played'|'favorite', ticks?, played?, favorite?, was?}`.
typedef UserDataChange = Map<String, dynamic>;

/// A play the server never heard about: `{itemId, userId, date}`.
typedef OfflinePlay = Map<String, dynamic>;

/// What one item's queued changes come to: `{itemId, userId, at, userData?: {...}, favorite?: bool}`.
typedef PendingUpdate = Map<String, Object?>;

/// One row of the server's play history.
typedef HistoryEntry = ({String id, String? lastPlayedDate, num playCount});

/// The history snapshot's entries as stored: `{Id, LastPlayedDate, PlayCount}` Maps.
typedef HistorySnapshot = Map<String, dynamic>;

/// How many history rows the snapshot keeps.
const maxHistoryEntries = 200;

final _safeId = RegExp(r'^[A-Za-z0-9]{1,64}$');

/// The history rows of a server answer: safe ids only, capped.
List<HistoryEntry> historyEntriesOf(List<Item> items) => [
      for (final i in items.where((i) => i['Id'] is String && _safeId.hasMatch(i['Id'])).take(maxHistoryEntries))
        (
          id: i['Id'] as String,
          lastPlayedDate: (i['UserData'] as Map?)?['LastPlayedDate'] is String ? (i['UserData'] as Map)['LastPlayedDate'] as String : null,
          playCount: (i['UserData'] as Map?)?['PlayCount'] is num && ((i['UserData'] as Map)['PlayCount'] as num).isFinite ? (i['UserData'] as Map)['PlayCount'] as num : 0,
        ),
    ];

/// The history the snapshot keeps, and the list reconnecting compares with.
const historyQuery = {
  'Filters': 'IsPlayed',
  'SortBy': 'DatePlayed',
  'SortOrder': 'Descending',
  'Recursive': 'true',
  'IncludeItemTypes': 'Audio,Movie,Episode',
  'Limit': '200',
};

int _ms(Object? iso) => iso is String ? (DateTime.tryParse(iso)?.millisecondsSinceEpoch ?? 0) : 0;

/// Each item's changes as one update, in the order items were first changed. Later changes win (only the last position matters); a favorite that ends where it started is no change.
List<PendingUpdate> coalesceChanges(List<UserDataChange> changes) {
  final out = <String, PendingUpdate>{};
  final firstWas = <String, bool>{};
  final indexed = [for (var i = 0; i < changes.length; i++) (changes[i], i)]..sort((a, b) {
      final c = _ms(a.$1['at']).compareTo(_ms(b.$1['at']));
      return c != 0 ? c : a.$2.compareTo(b.$2);
    });
  for (final (c, _) in indexed) {
    final key = '${c['userId']}/${c['itemId']}';
    final u = out.putIfAbsent(key, () => {'itemId': c['itemId'], 'userId': c['userId'], 'at': c['at']});
    u['at'] = c['at'];
    if (c['kind'] == 'favorite') {
      firstWas.putIfAbsent(key, () => c['was'] is bool ? c['was'] as bool : !(c['favorite'] == true));
      u['favorite'] = c['favorite'] == true;
      continue;
    }
    final ud = (u['userData'] ??= <String, Object?>{}) as Map<String, Object?>;
    if (c['kind'] == 'position') {
      ud['PlaybackPositionTicks'] = c['ticks'] ?? 0;
      ud['LastPlayedDate'] = c['at'];
    } else if (c['played'] == true) {
      ud['Played'] = true;
      ud['PlaybackPositionTicks'] = 0;
      ud['LastPlayedDate'] = c['at'];
    } else {
      ud['Played'] = false;
      ud['PlaybackPositionTicks'] = 0;
    }
  }
  final result = <PendingUpdate>[];
  for (final e in out.entries) {
    final u = e.value;
    if (u.containsKey('favorite') && u['favorite'] == firstWas[e.key]) u.remove('favorite');
    if (u.containsKey('userData') || u.containsKey('favorite')) result.add(u);
  }
  return result;
}

/// What to send for one update, given the item as the server has it now (null: the server no longer has it, so nothing). The change wins only when the server's LastPlayedDate is older. Fields the server already holds are left out; null when nothing is left.
Map<String, Object?>? updateToSend(PendingUpdate update, Item? server) {
  if (server == null) return null;
  final sud = server['UserData'] is Map ? server['UserData'] as Map : const {};
  final serverAt = sud['LastPlayedDate'] is String ? DateTime.tryParse(sud['LastPlayedDate'] as String)?.millisecondsSinceEpoch : null;
  if (serverAt != null && serverAt >= _ms(update['at'])) return null;
  final out = <String, Object?>{};
  final uu = update['userData'];
  if (uu is Map) {
    final ud = Map<String, Object?>.from(uu);
    if (ud.containsKey('Played') && ud['Played'] == (sud['Played'] == true)) ud.remove('Played');
    if (ud.containsKey('PlaybackPositionTicks') && ud['PlaybackPositionTicks'] == (sud['PlaybackPositionTicks'] ?? 0) && !ud.containsKey('Played')) ud.remove('PlaybackPositionTicks');
    // A date alone changes nothing a person sees.
    if (ud.containsKey('Played') || ud.containsKey('PlaybackPositionTicks')) out['userData'] = ud;
  }
  if (update.containsKey('favorite') && update['favorite'] != (sud['IsFavorite'] == true)) out['favorite'] = update['favorite'];
  return out.containsKey('userData') || out.containsKey('favorite') ? out : null;
}

List<HistoryEntry> _ordered(List<HistoryEntry> entries) => [...entries]..sort((a, b) {
    final da = a.lastPlayedDate ?? '', db = b.lastPlayedDate ?? '';
    if (da != db) return da.compareTo(db) < 0 ? 1 : -1;
    return a.id.compareTo(b.id);
  });

/// Whether the server's history ([historyQuery]'s answer) is the snapshot's: same items, dates and counts in the same order. No snapshot never matches.
bool snapshotMatches(HistorySnapshot? snapshot, List<Item> serverItems) {
  if (snapshot == null) return false;
  final entries = snapshot['entries'] is List ? snapshot['entries'] as List : const [];
  final a = _ordered([
    for (final e in entries.whereType<Map>())
      (id: '${e['Id']}', lastPlayedDate: e['LastPlayedDate'] as String?, playCount: (e['PlayCount'] as num?) ?? 0),
  ]);
  final b = _ordered(historyEntriesOf(serverItems));
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].id != b[i].id || a[i].lastPlayedDate != b[i].lastPlayedDate || a[i].playCount != b[i].playCount) return false;
  }
  return true;
}

/// What to do with the plays queued offline, back online: 'none', 'replay' or 'hold' (already held, or someone played on this account elsewhere meanwhile).
String playsCatchUp(List<OfflinePlay> plays, HistorySnapshot? history, bool playsHeld, List<Item> serverItems) {
  if (plays.isEmpty) return 'none';
  if (playsHeld) return 'hold';
  return snapshotMatches(history, serverItems) ? 'replay' : 'hold';
}

/// The order plays are replayed in, so the server's history reads as if they had happened online. Ties keep queue order.
List<OfflinePlay> playsOldestFirst(List<OfflinePlay> plays) {
  final indexed = [for (var i = 0; i < plays.length; i++) (plays[i], i)]..sort((a, b) {
      final c = _ms(a.$1['date']).compareTo(_ms(b.$1['date']));
      return c != 0 ? c : a.$2.compareTo(b.$2);
    });
  return [for (final (p, _) in indexed) p];
}
