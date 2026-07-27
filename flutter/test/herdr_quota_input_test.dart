import 'package:flutter_hbb/mobile/pages/herdr/herdr_quota.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('herdrParseUsage', () {
    test('parses providers and keeps ALL windows sorted by severity', () {
      final entries = herdrParseUsage(
          '{"ts": 1, "claude": {"plan": "pro", "windows": ['
          '{"label": "5h", "remaining": 75.0},'
          '{"label": "7d", "remaining": 42.5}]}}');
      expect(entries, hasLength(1));
      final entry = entries.single;
      expect(entry.provider, 'claude');
      expect(entry.plan, 'pro');
      expect(entry.windows.map((w) => w.label), ['7d', '5h']);
      expect(entry.windows.map((w) => w.remaining), [42.5, 75.0]);
      expect(entry.worstRemaining, 42.5);
    });

    test('hides opencode-go entirely', () {
      final entries = herdrParseUsage(
          '{"opencode-go": {"windows": [{"label": "30d", "remaining": 60}]},'
          '"claude": {"windows": [{"label": "5h", "remaining": 75}]}}');
      expect(entries.map((e) => e.provider), ['claude']);
    });

    test('sorts providers by worst remaining and formats names', () {
      final entries = herdrParseUsage(
          '{"claude": {"windows": [{"label": "5h", "remaining": 75}]},'
          '"kimi": {"windows": [{"label": "ciclo", "remaining": 28},'
          '{"label": "5h", "remaining": 95}]}}');
      expect(entries.map((e) => e.provider), ['kimi', 'claude']);
      final kimi = entries.first;
      expect(kimi.displayName, 'Kimi');
      expect(kimi.windows.map((w) => '${w.label} ${w.remaining.round()}%'),
          ['ciclo 28%', '5h 95%']);
      expect(entries[1].displayName, 'Claude');
    });

    test('ignores ts, malformed providers and windows without remaining', () {
      final entries = herdrParseUsage(
          '{"ts": 5, "bad": "nope", "empty": {"windows": []},'
          '"claude": {"windows": [{"label": "5h"}]}}');
      expect(entries, isEmpty);
    });

    test('invalid JSON throws, non-map returns empty', () {
      expect(herdrParseUsage('[1,2]'), isEmpty);
    });
  });

}
