// Top Songs shelf for the artist page. Ported from desktop/src/core/artist-page.ts.
import 'jellyfin.dart' show Item;

/// How many of the artist's own tracks the Top Songs shelf shows.
const artistTopSongsMax = 10;

int _plays(Item i) => ((i['UserData'] as Map?)?['PlayCount'] as num?)?.toInt() ?? 0;

/// The artist's played tracks by this user's PlayCount, ties alphabetical. Unplayed tracks are left out. Input is not mutated.
List<Item> topSongsOf(List<Item> songs, [int max = artistTopSongsMax]) {
  final played = songs.where((i) => _plays(i) > 0).toList();
  played.sort((a, b) {
    final c = _plays(b).compareTo(_plays(a));
    // ponytail: code-unit compare on lowercased names, not locale collation
    return c != 0 ? c : ('${a['Name'] ?? ''}'.toLowerCase()).compareTo('${b['Name'] ?? ''}'.toLowerCase());
  });
  return played.take(max).toList();
}
