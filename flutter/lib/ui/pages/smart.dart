// Smart playlists: a row of them on Playlists, their page (the songs that
// match right now), and the editor for their rules. The rules and their
// checks are core/smart_playlist.dart, shared with the desktop's format.
import 'dart:math';

import 'package:flutter/material.dart';

import 'package:cascade/core/data.dart';
import 'package:cascade/core/nav.dart';
import 'package:cascade/core/smart_playlist.dart';
import 'package:cascade/ui/pages/common.dart';
import 'package:cascade/ui/pages/detail.dart';
import 'package:cascade/ui/scopes.dart';
import 'package:cascade/ui/widgets.dart';

String _newId() => 'user:${List.generate(4, (_) => Random.secure().nextInt(1 << 32).toRadixString(16).padLeft(8, '0')).join('-')}';

/// The smart playlists, as a strip of cards with New at the end.
class SmartPlaylistsRow extends StatelessWidget {
  const SmartPlaylistsRow({super.key});

  @override
  Widget build(BuildContext context) {
    final lib = LibraryScope.of(context);
    if (lib.demo) return const SizedBox.shrink();
    return FutureBuilder<List<SmartPlaylistDef>>(
      future: lib.smartPlaylists(),
      builder: (context, snap) {
        final defs = snap.data ?? const [];
        return Padding(
          padding: const EdgeInsets.only(bottom: 22),
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final d in defs)
                Hover(
                  onTap: () => openPage(context, PageKind.smart, [d['id']]),
                  builder: (_, on) => Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(color: on ? K.surface2 : K.surface, borderRadius: BorderRadius.circular(12)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.auto_awesome_motion_rounded, size: 18, color: K.accent),
                        const SizedBox(width: 8),
                        Text('${d['name']}', style: ts(13, w: FontWeight.w500)),
                      ],
                    ),
                  ),
                ),
              Pill('New smart playlist', icon: Icons.add_rounded, primary: false, onTap: () => editSmartPlaylist(context, null)),
            ],
          ),
        );
      },
    );
  }
}

class SmartPlaylistPage extends StatefulWidget {
  const SmartPlaylistPage(this.id, {super.key});
  final String id;

  @override
  State<SmartPlaylistPage> createState() => _SmartPlaylistPageState();
}

class _SmartPlaylistPageState extends State<SmartPlaylistPage> {
  late Future<(SmartPlaylistDef, List<Song>)> _data = _load();

  Future<(SmartPlaylistDef, List<Song>)> _load() async {
    final lib = LibraryScope.read(context);
    final def = (await lib.smartPlaylists()).firstWhere((d) => d['id'] == widget.id, orElse: () => throw StateError('This smart playlist is gone.'));
    return (def, await lib.smartSongs(def));
  }

  @override
  Widget build(BuildContext context) => Loading<(SmartPlaylistDef, List<Song>)>(
    future: _data,
    sliver: false,
    onRetry: () => setState(() => _data = _load()),
    builder: (context, d) {
      final (def, songs) = d;
      return PageScroll(
        slivers: [
          SliverToBoxAdapter(
            child: DetailHeader(
              label: 'Smart playlist',
              title: '${def['name']}',
              art: songs.firstOrNull?.art ?? artFor(widget.id),
              image: songs.firstOrNull?.image,
              meta:
                  '${songs.length} ${songs.length == 1 ? 'song' : 'songs'} match ${def['match'] == 'any' ? 'any' : 'all'} of ${(def['rules'] as List).length} rules',
              voice: 'It fills itself as your library changes.',
              actions: [
                ...playButtons(context, songs, '${def['name']}'),
                Pill(
                  'Edit',
                  primary: false,
                  onTap: () async {
                    await editSmartPlaylist(context, def);
                    if (mounted) setState(() => _data = _load());
                  },
                ),
                RoundBtn(Icons.delete_outline_rounded, 'Delete', () async {
                  if (!await confirm(context, 'Delete ${def['name']}?', 'Only the rules go; the songs stay.', 'Delete')) return;
                  if (!context.mounted) return;
                  final lib = LibraryScope.read(context);
                  await lib.saveSmartPlaylists([
                    for (final x in await lib.smartPlaylists())
                      if (x['id'] != def['id']) x,
                  ]);
                  if (context.mounted) NavScope.read(context).forget(PageKind.smart, def['id']);
                }),
              ],
            ),
          ),
          if (songs.isEmpty)
            const SliverToBoxAdapter(child: Empty('Nothing matches these rules yet.', icon: Icons.auto_awesome_motion_rounded))
          else
            SliverList.builder(
              itemCount: songs.length,
              itemBuilder: (c, i) => TrackRow(songs[i], index: i + 1, queue: songs, cols: TrackCols.playlist, showArt: true, source: '${def['name']}'),
            ),
        ],
      );
    },
  );
}

/// Make a smart playlist, or change [def].
Future<void> editSmartPlaylist(BuildContext context, SmartPlaylistDef? def) async {
  final lib = LibraryScope.read(context);
  final saved = await showDialog<SmartPlaylistDef>(
    context: context,
    builder: (_) => _Editor(def: def),
  );
  if (saved == null) return;
  final all = await lib.smartPlaylists();
  final i = all.indexWhere((d) => d['id'] == saved['id']);
  await lib.saveSmartPlaylists(i < 0 ? [...all, saved] : ([...all]..[i] = saved));
}

const _fields = {
  'genre': 'Genre is',
  'genreNot': 'Genre is not',
  'artist': 'Artist is',
  'year': 'Year between',
  'addedWithinDays': 'Added in the last (days)',
  'played': 'Played',
  'playCount': 'Played at least (times)',
  'favorite': 'Liked',
};

class _Editor extends StatefulWidget {
  const _Editor({this.def});
  final SmartPlaylistDef? def;

  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late final _name = TextEditingController(text: '${widget.def?['name'] ?? ''}');
  late String _match = '${widget.def?['match'] ?? 'all'}';
  late String _sortBy = '${widget.def?['sortBy'] ?? 'name'}';
  late String _sortDir = '${widget.def?['sortDir'] ?? 'asc'}';
  late int _limit = widget.def?['limit'] as int? ?? 100;
  late final List<Map<String, Object?>> _rules = [for (final r in (widget.def?['rules'] as List? ?? const [])) Map<String, Object?>.from(r as Map)];

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String _kind(Map<String, Object?> r) => r['field'] == 'genre' && r['op'] == 'isNot' ? 'genreNot' : '${r['field']}';

  Map<String, Object?> _blank(String kind) => switch (kind) {
    'genre' => {'field': 'genre', 'op': 'is', 'value': ''},
    'genreNot' => {'field': 'genre', 'op': 'isNot', 'value': ''},
    'artist' => {'field': 'artist', 'op': 'is', 'value': ''},
    'year' => {'field': 'year', 'op': 'between', 'min': 1990, 'max': 1999},
    'addedWithinDays' => {'field': 'addedWithinDays', 'op': 'lte', 'days': 30},
    'played' => {'field': 'played', 'op': 'is', 'value': false},
    'playCount' => {'field': 'playCount', 'op': 'gte', 'value': 5},
    _ => {'field': 'favorite', 'op': 'is', 'value': true},
  };

  Widget _num(Object? v, ValueChanged<int> set, {double w = 70}) => SizedBox(
    width: w,
    child: TextFormField(
      initialValue: '$v',
      keyboardType: TextInputType.number,
      style: ts(13),
      decoration: const InputDecoration(isDense: true),
      onChanged: (t) => int.tryParse(t) == null ? null : set(int.parse(t)),
    ),
  );

  Widget _value(Map<String, Object?> r) => switch (r['field']) {
    'genre' || 'artist' => Expanded(
      child: TextFormField(initialValue: '${r['value']}', style: ts(13), decoration: const InputDecoration(isDense: true), onChanged: (t) => r['value'] = t),
    ),
    'year' => Row(
      children: [
        _num(r['min'], (v) => r['min'] = v),
        Text('  and  ', style: ts(13, c: K.text3)),
        _num(r['max'], (v) => r['max'] = v),
      ],
    ),
    'addedWithinDays' => _num(r['days'], (v) => r['days'] = v),
    'playCount' => _num(r['value'], (v) => r['value'] = v),
    _ => Switch(value: r['value'] == true, onChanged: (v) => setState(() => r['value'] = v)),
  };

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: K.panel,
    title: Text(widget.def == null ? 'New smart playlist' : 'Edit smart playlist', style: Txt.section()),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              style: ts(14),
              decoration: InputDecoration(
                hintText: 'Name',
                hintStyle: ts(14, c: K.text3),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Text('Songs that match ', style: ts(13, c: K.text2)),
                DropdownButton<String>(
                  value: _match,
                  dropdownColor: K.surface2,
                  style: ts(13),
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(value: 'all', child: Text('all')),
                    DropdownMenuItem(value: 'any', child: Text('any')),
                  ],
                  onChanged: (v) => setState(() => _match = v!),
                ),
                Text(' of these', style: ts(13, c: K.text2)),
              ],
            ),
            for (final (i, r) in _rules.indexed)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    DropdownButton<String>(
                      value: _kind(r),
                      dropdownColor: K.surface2,
                      style: ts(13),
                      underline: const SizedBox.shrink(),
                      items: [for (final e in _fields.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                      onChanged: (k) => setState(() => _rules[i] = _blank(k!)),
                    ),
                    const SizedBox(width: 10),
                    _value(r),
                    const Spacer(),
                    IconBtn(Icons.close_rounded, 'Remove rule', () => setState(() => _rules.removeAt(i)), size: 16),
                  ],
                ),
              ),
            TextButton.icon(
              onPressed: () => setState(() => _rules.add(_blank('genre'))),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text('Add a rule', style: ts(13, c: K.accent)),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text('Sort by ', style: ts(13, c: K.text2)),
                DropdownButton<String>(
                  value: _sortBy,
                  dropdownColor: K.surface2,
                  style: ts(13),
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(value: 'name', child: Text('Title')),
                    DropdownMenuItem(value: 'artist', child: Text('Artist')),
                    DropdownMenuItem(value: 'album', child: Text('Album')),
                    DropdownMenuItem(value: 'dateAdded', child: Text('Date added')),
                    DropdownMenuItem(value: 'playCount', child: Text('Plays')),
                  ],
                  onChanged: (v) => setState(() => _sortBy = v!),
                ),
                IconBtn(
                  _sortDir == 'asc' ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                  'Direction',
                  () => setState(() => _sortDir = _sortDir == 'asc' ? 'desc' : 'asc'),
                ),
                const Spacer(),
                Text('Up to ', style: ts(13, c: K.text2)),
                _num(_limit, (v) => _limit = v),
                Text(' songs', style: ts(13, c: K.text2)),
              ],
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      TextButton(
        onPressed: () {
          final name = _name.text.trim();
          if (name.isEmpty) return;
          // Through the parser, so the saved definition is what the rules accept.
          final def = parseSmartPlaylists(
            serializeSmartPlaylists([
              {'id': widget.def?['id'] ?? _newId(), 'name': name, 'match': _match, 'rules': _rules, 'sortBy': _sortBy, 'sortDir': _sortDir, 'limit': _limit},
            ]),
          ).firstOrNull;
          Navigator.pop(context, def);
        },
        child: Text(
          'Save',
          style: ts(13, w: FontWeight.w600, c: K.accent),
        ),
      ),
    ],
  );
}
