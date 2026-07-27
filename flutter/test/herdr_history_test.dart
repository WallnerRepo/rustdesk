import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/pages/herdr/herdr_fuzzy.dart';
import 'package:flutter_hbb/mobile/pages/herdr/herdr_history.dart';

HerdrHistoryEntry entry(
  String id, {
  HerdrHistoryKind kind = HerdrHistoryKind.agent,
  required int at,
  bool pinned = false,
  String label = '',
}) =>
    HerdrHistoryEntry(
      kind: kind,
      id: id,
      label: label.isEmpty ? id : label,
      lastOpenedAt: at,
      pinned: pinned,
    );

/// 2026-07-27 12:00 local, the reference "now" for grouping tests.
final DateTime now = DateTime(2026, 7, 27, 12);
int daysAgo(int n) =>
    now.subtract(Duration(days: n)).millisecondsSinceEpoch;

void main() {
  group('HerdrHistory.record', () {
    test('re-opening the same entry refreshes it instead of duplicating', () {
      final h = HerdrHistory();
      h.record(entry('api', at: 1000));
      h.record(entry('api', at: 2000));

      expect(h.entries.length, 1);
      expect(h.entries.single.lastOpenedAt, 2000);
      expect(h.entries.single.openCount, 2);
    });

    test('same id under a different kind is a different entry', () {
      final h = HerdrHistory();
      h.record(entry('api', at: 1000));
      h.record(entry('api', kind: HerdrHistoryKind.workspace, at: 1000));
      expect(h.entries.length, 2);
    });

    test('orders pinned first, then most recent', () {
      final h = HerdrHistory();
      h.record(entry('old', at: 1000));
      h.record(entry('new', at: 3000));
      h.record(entry('pinned', at: 2000, pinned: true));

      expect(h.entries.map((e) => e.id), ['pinned', 'new', 'old']);
    });

    test('re-opening keeps an existing pin', () {
      final h = HerdrHistory();
      h.record(entry('api', at: 1000, pinned: true));
      h.record(entry('api', at: 2000));
      expect(h.entries.single.pinned, isTrue);
    });
  });

  group('HerdrHistory pruning', () {
    test('drops the oldest unpinned entries past the cap', () {
      final h = HerdrHistory(maxEntries: 3);
      for (var i = 0; i < 6; i++) {
        h.record(entry('a$i', at: 1000 + i));
      }
      expect(h.entries.length, 3);
      expect(h.entries.map((e) => e.id), ['a5', 'a4', 'a3']);
    });

    test('never drops pinned entries, even beyond the cap', () {
      final h = HerdrHistory(maxEntries: 2);
      h.record(entry('p1', at: 1, pinned: true));
      h.record(entry('p2', at: 2, pinned: true));
      h.record(entry('p3', at: 3, pinned: true));
      for (var i = 0; i < 5; i++) {
        h.record(entry('u$i', at: 100 + i));
      }
      final pinned = h.entries.where((e) => e.pinned).map((e) => e.id);
      expect(pinned, ['p3', 'p2', 'p1']);
      expect(h.entries.where((e) => !e.pinned).length, 2);
    });
  });

  group('HerdrHistory pin / remove / clear', () {
    test('togglePin flips state and re-sorts', () {
      final h = HerdrHistory();
      h.record(entry('old', at: 1000));
      h.record(entry('new', at: 3000));

      expect(h.togglePin('agent:old'), isTrue);
      expect(h.entries.first.id, 'old');
      expect(h.togglePin('agent:old'), isFalse);
      expect(h.entries.first.id, 'new');
    });

    test('togglePin on a missing key returns null', () {
      expect(HerdrHistory().togglePin('agent:nope'), isNull);
    });

    test('remove reports whether anything was removed', () {
      final h = HerdrHistory();
      h.record(entry('api', at: 1));
      expect(h.remove('agent:api'), isTrue);
      expect(h.remove('agent:api'), isFalse);
      expect(h.isEmpty, isTrue);
    });

    test('clear keeps pinned entries by default', () {
      final h = HerdrHistory();
      h.record(entry('keep', at: 1, pinned: true));
      h.record(entry('drop', at: 2));

      h.clear();
      expect(h.entries.map((e) => e.id), ['keep']);

      h.clear(keepPinned: false);
      expect(h.isEmpty, isTrue);
    });
  });

  group('HerdrHistory.grouped', () {
    test('buckets by age and lifts pinned into their own group', () {
      final h = HerdrHistory();
      h.record(entry('today', at: daysAgo(0)));
      h.record(entry('yesterday', at: daysAgo(1)));
      h.record(entry('week', at: daysAgo(3)));
      h.record(entry('month', at: daysAgo(10)));
      h.record(entry('ancient', at: daysAgo(90)));
      h.record(entry('fav', at: daysAgo(45), pinned: true));

      final groups = h.grouped(now);
      expect(groups.map((g) => g.title), [
        'Fijados',
        'Hoy',
        'Ayer',
        'Esta semana',
        'Este mes',
        'Hace tiempo',
      ]);
      expect(groups.first.entries.single.id, 'fav');
      expect(groups[1].entries.single.id, 'today');
    });

    test('omits empty buckets', () {
      final h = HerdrHistory();
      h.record(entry('today', at: daysAgo(0)));
      expect(h.grouped(now).map((g) => g.title), ['Hoy']);
    });

    test('an entry earlier today still counts as Hoy', () {
      final h = HerdrHistory();
      h.record(entry('dawn', at: DateTime(2026, 7, 27, 0, 5).millisecondsSinceEpoch));
      expect(h.grouped(now).single.title, 'Hoy');
    });
  });

  group('HerdrHistory encode / decode', () {
    test('round-trips every field', () {
      final h = HerdrHistory();
      h.record(HerdrHistoryEntry(
        kind: HerdrHistoryKind.workspace,
        id: 'wM',
        label: 'MAN_PC',
        subtitle: 'claude',
        cwd: '/home/hyt/Desktop/MAN_PC',
        workspaceId: 'wM',
        lastOpenedAt: 1785000000000,
        pinned: true,
      ));

      final back = HerdrHistory.decode(h.encode()).entries.single;
      expect(back.kind, HerdrHistoryKind.workspace);
      expect(back.id, 'wM');
      expect(back.label, 'MAN_PC');
      expect(back.subtitle, 'claude');
      expect(back.cwd, '/home/hyt/Desktop/MAN_PC');
      expect(back.workspaceId, 'wM');
      expect(back.lastOpenedAt, 1785000000000);
      expect(back.pinned, isTrue);
    });

    test('garbage, empty and foreign payloads decode to an empty history', () {
      expect(HerdrHistory.decode(null).isEmpty, isTrue);
      expect(HerdrHistory.decode('').isEmpty, isTrue);
      expect(HerdrHistory.decode('not json{').isEmpty, isTrue);
      expect(HerdrHistory.decode('[1,2,3]').isEmpty, isTrue);
      expect(HerdrHistory.decode('{"v":99,"entries":[]}').isEmpty, isTrue);
    });

    test('one corrupt row does not discard the good ones', () {
      const raw = '{"v":1,"entries":['
          '{"kind":"agent","id":"ok","label":"ok","at":5},'
          '{"kind":"agent","id":"","label":"no id","at":5},'
          '{"kind":"nope","id":"x","label":"bad kind","at":5},'
          '{"kind":"agent","id":"y","label":"no timestamp"},'
          '"just a string"'
          ']}';
      expect(HerdrHistory.decode(raw).entries.map((e) => e.id), ['ok']);
    });
  });

  group('fuzzy typo tolerance', () {
    test('strict mode is unchanged: a typo does not match', () {
      expect(herdrFuzzyScore('hedrr', 'herdr'), isNull);
    });

    test('tolerates a transposition, an extra char and a wrong char', () {
      for (final typo in ['hedrr', 'herrdr', 'herdz']) {
        expect(herdrFuzzyScore(typo, 'herdr', allowTypo: true), isNotNull,
            reason: typo);
      }
    });

    test('an exact match always outranks a typo match', () {
      final exact = herdrFuzzyScore('herdr', 'herdr', allowTypo: true)!;
      final typo = herdrFuzzyScore('herdz', 'herdr', allowTypo: true)!;
      expect(exact, greaterThan(typo));
    });

    test('short queries stay strict to avoid matching everything', () {
      expect(herdrFuzzyScore('abc', 'axc', allowTypo: true), isNull);
      expect(herdrFuzzyScore('abcd', 'axcd', allowTypo: true), isNotNull);
    });

    test('two typos still do not match', () {
      expect(herdrFuzzyScore('hzrdz', 'herdr', allowTypo: true), isNull);
    });

    test('filter surfaces a typo match only when nothing matches exactly', () {
      final items = ['herdr-mobile', 'rustdesk'];
      final results = herdrFuzzyFilter<String>(
        'herdz',
        items,
        (s) => s,
        (_) => 0,
        allowTypo: true,
      );
      expect(results.map((r) => r.item), ['herdr-mobile']);
    });
  });
}
