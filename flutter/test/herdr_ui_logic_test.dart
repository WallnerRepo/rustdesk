import 'package:flutter_hbb/mobile/pages/herdr/herdr_fuzzy.dart';
import 'package:flutter_hbb/mobile/pages/herdr/herdr_terminal_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('herdrTerminalFitFontSize', () {
    // charWidthRatio measured like xterm: cellWidth / fontSize (~0.55 for
    // monospace).
    test('fits columns to the available width', () {
      final size = herdrTerminalFitFontSize(
          cols: 100, availableWidth: 550, charWidthRatio: 0.55);
      expect(size, closeTo(10.0, 0.01));
    });

    test('clamps to the readable floor, not to mush', () {
      // A 157-column host pane on a 320px phone: fitting every column would
      // need ~3.7pt. The floor keeps it legible and lets the horizontal
      // scroll cover the rest.
      final size = herdrTerminalFitFontSize(
          cols: 157, availableWidth: 320, charWidthRatio: 0.55);
      expect(size, herdrTerminalMinFontSize);
      expect(herdrTerminalMinFontSize, greaterThanOrEqualTo(9.0));
    });

    test('clamps to the ceiling for narrow panes', () {
      final size = herdrTerminalFitFontSize(
          cols: 40, availableWidth: 800, charWidthRatio: 0.55);
      expect(size, herdrTerminalMaxFontSize);
    });

    test('the ceiling matches the inline terminal panel font size', () {
      expect(herdrTerminalMaxFontSize, 14.0);
    });

    test('degenerate inputs fall back to the ceiling', () {
      expect(
          herdrTerminalFitFontSize(
              cols: 0, availableWidth: 320, charWidthRatio: 0.55),
          herdrTerminalMaxFontSize);
      expect(
          herdrTerminalFitFontSize(
              cols: 80, availableWidth: 0, charWidthRatio: 0.55),
          herdrTerminalMaxFontSize);
    });

    test('style uses the same monospace stack as the inline panel', () {
      final style = herdrTerminalStyle(12);
      expect(style.fontFamily, 'JetBrainsMono Nerd Font');
      expect(style.fontFamilyFallback, contains('monospace'));
    });

    test('style does NOT override the line height', () {
      // Regression guard. Setting height (the inline panel uses 1.3) made the
      // cell height xterm paints with disagree with the layout, so its painter
      // dereferenced buffer rows that were never written and threw
      // "Null check operator used on a null value" on every frame — the
      // console rendered completely black.
      expect(herdrTerminalStyle(12).height, TerminalStyle().height);
    });
  });

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


  group('HerdrColsTracker', () {
    test('grows immediately to a wider pane', () {
      final t = HerdrColsTracker();
      expect(t.update(157), 157);
      expect(t.cols, 157);
    });

    test('one long line does not pin the width forever', () {
      final t = HerdrColsTracker();
      t.update(240); // a stray absolute path
      expect(t.cols, 240);
      // The pane is really 157 wide; after the streak it settles back.
      for (var i = 0; i < herdrTerminalShrinkAfter; i++) {
        t.update(157);
      }
      expect(t.cols, 157);
    });

    test('does not shrink before the streak completes', () {
      final t = HerdrColsTracker();
      t.update(200);
      for (var i = 0; i < herdrTerminalShrinkAfter - 1; i++) {
        expect(t.update(100), 200);
      }
    });

    test('a single narrow snapshot between wide ones changes nothing', () {
      final t = HerdrColsTracker();
      t.update(157);
      t.update(40); // one cleared screen
      t.update(157);
      expect(t.cols, 157);
    });

    test('shrinks to the widest of the agreeing snapshots, not the last', () {
      final t = HerdrColsTracker();
      t.update(200);
      t.update(90);
      t.update(120);
      t.update(100);
      expect(t.cols, 120);
    });

    test('never collapses below the minimum', () {
      final t = HerdrColsTracker();
      t.update(200);
      for (var i = 0; i < herdrTerminalShrinkAfter; i++) {
        t.update(10);
      }
      expect(t.cols, herdrTerminalMinCols);
    });

    test('equal width keeps the column count and resets the streak', () {
      final t = HerdrColsTracker();
      t.update(157);
      t.update(100);
      t.update(157);
      t.update(100);
      t.update(100);
      // Streak was reset by the equal-width snapshot, so still 157.
      expect(t.cols, 157);
    });
  });
}
