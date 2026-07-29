import 'package:flutter_hbb/mobile/pages/herdr/herdr_pane_width.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('herdrColumnsFor', () {
    test('a typical phone width lands well inside the relay bounds', () {
      // ~360 logical px of text at the reading view's ~7.8px monospace glyph.
      final columns = herdrColumnsFor(336, 7.8);
      expect(columns, 43);
      expect(columns, greaterThanOrEqualTo(kHerdrMinPaneColumns));
      expect(columns, lessThanOrEqualTo(kHerdrMaxPaneColumns));
    });

    test('clamps to what the relay accepts', () {
      expect(herdrColumnsFor(100, 7.8), kHerdrMinPaneColumns);
      expect(herdrColumnsFor(9000, 7.8), kHerdrMaxPaneColumns);
    });

    test('0 means "not measurable yet", never a bogus lease', () {
      // First frame, a collapsed layout or a font that measured as nothing.
      expect(herdrColumnsFor(0, 7.8), 0);
      expect(herdrColumnsFor(336, 0), 0);
      expect(herdrColumnsFor(-1, 7.8), 0);
      expect(herdrColumnsFor(double.infinity, 7.8), 0);
      expect(herdrColumnsFor(336, double.nan), 0);
    });
  });

  group('herdrShouldRelease', () {
    test('ignores layout jitter', () {
      // The keyboard animating in must not fire a relay command per frame,
      // and a resize makes the agent redraw its whole pane.
      expect(herdrShouldRelease(43, 43), isFalse);
      expect(herdrShouldRelease(43, 44), isFalse);
    });

    test('acts on a real change of width', () {
      expect(herdrShouldRelease(43, 45), isTrue);
      expect(herdrShouldRelease(80, 43), isTrue);
    });

    test('says no when either side is unknown', () {
      expect(herdrShouldRelease(0, 43), isFalse);
      expect(herdrShouldRelease(43, 0), isFalse);
    });
  });
}
