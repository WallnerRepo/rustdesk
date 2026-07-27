import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/pages/herdr/herdr_relay_client.dart';
import 'package:flutter_hbb/mobile/pages/herdr/herdr_terminal_view.dart';
import 'package:xterm/xterm.dart';

/// A snapshot shaped like a real `read_pane` answer: SGR colours, box drawing
/// and short lines, i.e. far fewer lines than a phone viewport has rows.
const String kSnapshot = '[0m[38;2;215;119;87m ▐[0m Claude Code\n'
    '[38;2;153;153;153m~/Desktop/MAN_PC[0m\n'
    '\n'
    '❯ hola\n';

Widget wrap(Widget child, {Size size = const Size(400, 800)}) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: size.width, height: size.height, child: child),
        ),
      ),
    );

void main() {
  group('herdrSnapshotSequence', () {
    test('never emits the erase-display that crashes xterm', () {
      final seq = herdrSnapshotSequence(kSnapshot, 40);
      expect(seq, isNot(contains('\x1b[2J')));
      expect(seq, isNot(contains('\x1b[J')));
    });

    test('writes exactly one row per viewport row', () {
      final seq = herdrSnapshotSequence('a\nb\n', 10);
      // Rows are separated by CRLF, so one fewer than the row count.
      expect('\r\n'.allMatches(seq).length, 9);
      expect('\x1b[K'.allMatches(seq).length, 10);
    });

    test('pads past the content so stale rows are cleared', () {
      final seq = herdrSnapshotSequence('only one line', 5);
      expect(seq, contains('only one line'));
      expect('\x1b[K'.allMatches(seq).length, 5);
    });

    test('keeps the END of a snapshot taller than the viewport', () {
      // The live screen is at the tail. Rendering the head showed the oldest,
      // blank part of the scrollback and the console looked empty.
      final seq = herdrSnapshotSequence('a\nb\nc\nd\ne', 2);
      expect(seq, contains('d'));
      expect(seq, contains('e'));
      expect(seq, isNot(contains('a')));
    });

    test('a 400-line tail on a 220-row viewport shows the newest lines', () {
      final tail = List.generate(400, (i) => 'linea $i').join('\n');
      final seq = herdrSnapshotSequence(tail, 220);
      expect(seq, contains('linea 399'));
      expect(seq, contains('linea 180'));
      expect(seq, isNot(contains('linea 0\x1b')));
    });

    test('falls back to the content height before the first layout', () {
      final seq = herdrSnapshotSequence('a\nb\nc', 0);
      expect('\x1b[K'.allMatches(seq).length, 3);
    });

    test('resets SGR first so cleared cells do not inherit a background', () {
      expect(herdrSnapshotSequence('x', 1), startsWith('\x1b[0m\x1b[H'));
    });

    test('clears each row BEFORE drawing it, never after', () {
      // The relay sends CRLF, so a line carries a trailing '\r'. Erasing after
      // drawing let that CR park the cursor at column 0 and the erase wiped
      // the row that had just been written — the whole console came out blank.
      final seq = herdrSnapshotSequence('hola\r\nadios\r', 2);
      expect(seq.indexOf('\x1b[K'), lessThan(seq.indexOf('hola')));
      expect(seq, contains('hola'));
      expect(seq, contains('adios'));
    });

    test('strips the trailing CR the relay leaves on every line', () {
      // A surviving CR would send the cursor back to column 0, so whatever
      // came next overwrote the row.
      final seq = herdrSnapshotSequence('uno\r\ndos\r', 2);
      expect(seq, isNot(contains('uno\r\x1b')));
      expect(seq, isNot(contains('dos\r\x1b[0m')));
      // The row separator is still a real CRLF.
      expect(seq, contains('\r\n'));
    });

    test('a CRLF snapshot survives a full round trip into xterm', () {
      final crlf = List.generate(80, (i) => 'fila $i\r').join('\n');
      final seq = herdrSnapshotSequence(crlf, 40);
      for (final row in ['fila 79', 'fila 40']) {
        expect(seq, contains(row));
      }
    });
  });

  group('HerdrTerminalView rendering', () {
    testWidgets('paints a snapshot without throwing', (tester) async {
      await tester.pumpWidget(wrap(
        const HerdrTerminalView(content: kSnapshot, agentType: 'claude'),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('survives a content update (the poll path)', (tester) async {
      await tester.pumpWidget(wrap(
        const HerdrTerminalView(content: kSnapshot, agentType: 'claude'),
      ));
      await tester.pumpAndSettle();
      await tester.pumpWidget(wrap(
        const HerdrTerminalView(
            content: '$kSnapshot[32mmás salida[0m\n',
            agentType: 'claude'),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('survives a width change, which resizes the buffer',
        (tester) async {
      // Narrow content first, then a much wider line: this grows the column
      // count, which is exactly what used to leave unwritten buffer rows.
      await tester.pumpWidget(wrap(
        const HerdrTerminalView(content: 'corto\n', agentType: 'claude'),
      ));
      await tester.pumpAndSettle();
      await tester.pumpWidget(wrap(
        HerdrTerminalView(content: '${'x' * 200}\n', agentType: 'claude'),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('survives a viewport needing more rows than 200', (tester) async {
      // The real failure: a 157-column host pane on a narrow, tall phone puts
      // the auto-fit font on its floor, which asks xterm for ~218 rows. With
      // the old maxLines: 200 the circular buffer wrapped, eraseDisplay read
      // an empty slot and threw on every redraw — a black console.
      expect(herdrTerminalMaxLines, greaterThanOrEqualTo(1000));
      await tester.pumpWidget(wrap(
        HerdrTerminalView(content: '${'x' * 157}\n$kSnapshot',
            agentType: 'claude'),
        size: const Size(360, 2400),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('survives a tall viewport with a short snapshot',
        (tester) async {
      // The crash needed viewHeight > materialised lines; a tall view with
      // four lines of content is that case.
      await tester.pumpWidget(wrap(
        const HerdrTerminalView(content: kSnapshot, agentType: 'claude'),
        size: const Size(400, 2000),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('forwards typed bytes to onInput when writable',
        (tester) async {
      final sent = <String>[];
      await tester.pumpWidget(wrap(
        HerdrTerminalView(
          content: kSnapshot,
          agentType: 'claude',
          onInput: sent.add,
        ),
      ));
      await tester.pumpAndSettle();

      // Drive xterm the way the IME does; it reaches us through onOutput,
      // which is the whole point of reusing the inline terminal's input path.
      final view = tester.widget<TerminalView>(find.byType(TerminalView));
      view.terminal.textInput('hola');
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(sent, contains('hola'));
    });

    testWidgets('normalises Enter to CR, which raw-mode TUIs need',
        (tester) async {
      final sent = <String>[];
      await tester.pumpWidget(wrap(
        HerdrTerminalView(
          content: kSnapshot,
          agentType: 'claude',
          onInput: sent.add,
        ),
      ));
      await tester.pumpAndSettle();

      // Android soft keyboards emit '\n'; the agents in these panes only act
      // on '\r' (same reason TerminalModel does this).
      tester.widget<TerminalView>(find.byType(TerminalView)).terminal
          .textInput('\n');
      await tester.pump();

      expect(sent, contains('\r'));
      expect(sent, isNot(contains('\n')));
    });

    testWidgets('stays read-only when no input sink is given', (tester) async {
      await tester.pumpWidget(wrap(
        const HerdrTerminalView(content: kSnapshot, agentType: 'claude'),
      ));
      await tester.pumpAndSettle();
      expect(
          tester.widget<TerminalView>(find.byType(TerminalView)).readOnly, isTrue);
    });
  });

  group('herdrTailLines', () {
    test('keeps the tail when the relay dumps the whole scrollback', () {
      // The relay ignores read_pane's `lines`: measured 4641 lines / 728 KB
      // for a request of 60. Processing that every 1.5s starved the UI thread
      // and the console stayed black.
      final huge = List.generate(4641, (i) => 'linea $i').join('\n');
      final tail = herdrTailLines(huge);
      expect('\n'.allMatches(tail).length, lessThanOrEqualTo(kHerdrPaneTailLines));
      expect(tail, contains('linea 4640'));
      expect(tail, isNot(contains('linea 0\n')));
      expect(tail.length, lessThan(huge.length ~/ 5));
    });

    test('leaves a snapshot shorter than the cap untouched', () {
      const small = 'a\nb\nc';
      expect(herdrTailLines(small), small);
      expect(herdrTailLines(''), '');
    });

    test('keeps enough rows for the tallest viewport', () {
      // A 2400px screen at the 9pt floor asks xterm for ~220 rows.
      expect(kHerdrPaneTailLines, greaterThan(220));
    });
  });
}
