// Ported from desktop/test/announcements.test.ts (the site Worker tests are not ported).
import 'package:cascade/core/announcements.dart';
import 'package:cascade/core/server_messages.dart';
import 'package:flutter_test/flutter_test.dart';

final now = DateTime.parse('2026-11-10T12:00:00Z').millisecondsSinceEpoch;
const base = {'id': 'a', 'date': '2026-11-01', 'title': 'Hello'};
Map<String, Object?> e([Map<String, Object?> over = const {}]) => {...base, ...over};
List<Announcement> parse(Object? raw, {String v = '2.3.0', int? n, String kind = 'official'}) =>
    parseAnnouncements(raw, 'desktop', v, nowMs: n ?? now, kind: kind);

void main() {
  test('a well formed entry comes through as text, with defaults', () {
    final out = parse([
      e({'body': ' Hi\u0007 ', 'link': 'https://example.com/x', 'extra': 1}),
    ]);
    expect(out, [(id: 'a', date: '2026-11-01', title: 'Hello', body: 'Hi', link: 'https://example.com/x', kind: 'official', source: null)]);
    expect(parse([base])[0].body, '');
  });

  test('broken entries are dropped one at a time, not the whole file', () {
    final list = parse([
      null,
      7,
      e({'id': ''}),
      e({'title': 3}),
      e({'date': 'soon'}),
      e({'id': 'ok'}),
      e({'id': 'ok', 'title': 'dupe'}),
    ]);
    expect(list.map((a) => a.id), ['ok']);
    expect(list[0].title, 'Hello');
    expect(parse({'not': 'a list'}), isEmpty);
  });

  test('only https links are kept', () {
    for (final link in ['http://example.com', 'javascript:alert(1)', 'file:///etc/passwd', 'https://a b', 42]) {
      expect(
        parse([
          e({'link': link}),
        ])[0].link,
        isNull,
        reason: '$link',
      );
    }
  });

  test('platforms, the version window and expiry filter', () {
    int p(Map<String, Object?> o, [String v = '2.3.0']) => parse([e(o)], v: v).length;
    expect(
      p({
        'platforms': ['ios', 'tvos'],
      }),
      0,
    );
    expect(
      p({
        'platforms': ['desktop'],
      }),
      1,
    );
    expect(p({'minVersion': '2.3.0', 'maxVersion': '2.3.0'}), 1);
    expect(p({'minVersion': '2.3.1'}), 0);
    expect(p({'maxVersion': '2.2.9'}), 0);
    expect(p({'maxVersion': '2.3.0'}, '2.3.0-b2'), 1);
    expect(p({'expires': '2026-11-10'}), 1);
    expect(p({'expires': '2026-11-09'}), 0);
  });

  test('newest first', () {
    final list = parse([
      e({'id': 'old', 'date': '2026-01-01'}),
      e({'id': 'new', 'date': '2026-10-01'}),
    ]);
    expect(list.map((a) => a.id), ['new', 'old']);
  });

  test('the inbox leaves out dismissed entries and counts the unseen rest', () {
    final list = parse([
      e({'id': 'a'}),
      e({'id': 'b'}),
      e({'id': 'c'}),
    ]);
    final inbox = announcementInbox(list, ['b'], ['a']);
    expect(inbox.items.map((a) => a.id), ['a', 'c']);
    expect(inbox.unseen, 1);
    expect(announcementInbox(list, 'junk', {'a': 1}).items.length, 3);
    expect(idList(['x', 2, null, 'y']), ['x', 'y']);
  });

  test("a server's posts keep their ids apart per server and carry its name", () {
    final raw = {
      'server': {'id': 'abc', 'name': 'Chaos'},
      'items': [
        e({'body': '', 'link': '', 'source': 'Cascade', 'kind': 'official'}),
      ],
    };
    expect(parseServerAnnouncements(raw, 'desktop', '2.3.0', nowMs: now), [
      (id: 'server:abc:a', date: '2026-11-01', title: 'Hello', body: '', link: null, kind: 'server', source: 'Chaos'),
    ]);
    expect(
      parseServerAnnouncements(
        {
          ...raw,
          'server': {'id': 'abc'},
        },
        'desktop',
        '2.3.0',
        nowMs: now,
      )[0].source,
      'Your server',
    );
    expect(parseServerAnnouncements({'items': raw['items']}, 'desktop', '2.3.0', nowMs: now), isEmpty);
    expect(parseServerAnnouncements(null, 'desktop', '2.3.0', nowMs: now), isEmpty);
  });

  test('a dashboard message is kept as a server entry, newest first, capped', () {
    const ServerMessage msg = (header: 'Maintenance', text: 'Restarting at 2', timeoutMs: null);
    var stored = addServerMessage(null, msg, 'Chaos', nowMs: now);
    stored = addServerMessage(stored, (header: 'Back', text: msg.text, timeoutMs: null), '', nowMs: now + 1000);
    final list = parse(stored, kind: 'server');
    expect(list.map((a) => [a.title, a.kind, a.source]), [
      ['Back', 'server', 'Your server'],
      ['Maintenance', 'server', 'Chaos'],
    ]);
    expect(list[0].id, startsWith('message:'));
    expect(list[0].id, isNot(list[1].id));
    for (var i = 0; i < 60; i++) {
      stored = addServerMessage(stored, msg, 'Chaos', nowMs: now + i * 2000);
    }
    expect(stored.length, 50);
    expect(addServerMessage('junk', msg, 'Chaos', nowMs: now).length, 1);
  });
}
