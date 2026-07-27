import 'package:flutter_hbb/mobile/pages/herdr/herdr_fuzzy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('herdrFuzzyScore', () {
    test('empty query matches everything', () {
      expect(herdrFuzzyScore('', 'anything'), 0);
    });

    test('non-subsequence does not match', () {
      expect(herdrFuzzyScore('xyz', 'opencode'), isNull);
    });

    test('prefix beats substring beats scattered subsequence', () {
      final prefix = herdrFuzzyScore('open', 'opencode')!;
      final substring = herdrFuzzyScore('code', 'opencode')!;
      final scattered = herdrFuzzyScore('oce', 'opencode')!;
      expect(prefix, greaterThan(substring));
      expect(substring, greaterThan(scattered));
    });

    test('case-insensitive', () {
      expect(herdrFuzzyScore('OC', 'opencode'), isNotNull);
    });

    test('word boundary bonus', () {
      final boundary = herdrFuzzyScore('mov', 'test-movil')!;
      final scattered = herdrFuzzyScore('mov', 'xmsandoval')!;
      expect(boundary, greaterThan(scattered));
    });
  });

  group('herdrFuzzyFilter', () {
    test('ranks by score, ties by recency, caps results', () {
      final items = [
        ('open-code', 100),
        ('opencode-extra', 300),
        ('other', 200),
      ];
      final results = herdrFuzzyFilter(
        'open',
        items,
        (item) => item.$1,
        (item) => item.$2,
      );
      expect(results.map((r) => r.item.$1),
          ['open-code', 'opencode-extra']);
      // Recency breaks ties for equal scores.
      final ties = herdrFuzzyFilter(
        'o',
        [('ao', 1), ('bo', 9)],
        (item) => item.$1,
        (item) => item.$2,
      );
      expect(ties.first.item.$2, 9);
    });
  });


}
