import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/pages/herdr/herdr_ansi_text.dart';
import 'package:flutter_hbb/mobile/pages/herdr/herdr_reading_view.dart';
import 'package:flutter_hbb/mobile/pages/herdr/herdr_relay_client.dart';

/// A snapshot shaped like a real `read_pane` answer: SGR colours and CRLF.
const String kSnapshot = '[0m[38;2;215;119;87m ▐[0m Claude Code\n'
    '[38;2;153;153;153m~/Desktop/MAN_PC[0m\n'
    '\n'
    '❯ hola\n';

void main() {
  group('herdrTailLines', () {
    test('the view never keeps more lines than are fetched', () {
      // herdrReadableLines' `keep` counts lines that SURVIVED the filter, so
      // if it ever reaches kHerdrPaneTailLines it, not the fetch, becomes the
      // real limit on scrollback — silently.
      final lines = List.generate(kHerdrPaneTailLines * 2, (i) => 'linea $i');
      final kept = herdrReadableLines(lines.join('\n'));
      expect(kept.length, lessThan(kHerdrPaneTailLines),
          reason: 'the view cap must stay below the fetch size');
      expect(kept.last, 'linea ${lines.length - 1}');
    });

    test('keeps the tail when an old relay dumps the whole scrollback', () {
      // Relay 0.10.6 ignored read_pane's `lines`: measured 4641 lines / 728 KB
      // for a request of 60. 0.12.0 honours it, but this trim still bounds an
      // older relay's answer.
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

  group('herdrReadableLines (modo lectura)', () {
    test('drops the full-width rules that force 181 columns', () {
      const snapshot = 'hola\n'
          '────────────────────────────\n'
          'adios\n';
      expect(herdrReadableLines(snapshot), ['hola', 'adios']);
    });

    test('drops spinner and hint chrome, like herdr-remote does', () {
      const snapshot = 'texto\n'
          '  esc to cancel\n'
          '  type to queue\n'
          '  ◔ Shell\n';
      expect(herdrReadableLines(snapshot), ['texto']);
    });

    test('keeps the escapes so the view can colour them', () {
      final out = herdrReadableLines('\x1b[38;2;1;2;3mcolor\x1b[0m\r\n');
      expect(out.single, contains('color'));
      expect(out.single, contains('\x1b['));
      expect(out.single, isNot(contains('\r')));
    });

    test('filters on the STRIPPED text, so colour cannot hide chrome', () {
      // A separator rule wrapped in colour is still a separator rule.
      const painted = '\x1b[38;5;240m────────────\x1b[0m';
      expect(herdrReadableLines('hola\n$painted\nadios'), ['hola', 'adios']);
    });

    test('drops blank lines, which dominate a padded pane', () {
      expect(herdrReadableLines('a\n\n\n   \n\nb'), ['a', 'b']);
    });

    test('keeps only the tail', () {
      final many = List.generate(500, (i) => 'l$i').join('\n');
      final out = herdrReadableLines(many, keep: 10);
      expect(out.length, 10);
      expect(out.last, 'l499');
    });
  });

  group('herdrParseAnsi', () {
    test('truecolour, 256 and basic colours all resolve', () {
      expect(herdrParseAnsi('\x1b[38;2;10;20;30mx').single.color,
          const Color.fromARGB(255, 10, 20, 30));
      expect(herdrParseAnsi('\x1b[31mx').single.color, isNotNull);
      expect(herdrParseAnsi('\x1b[38;5;196mx').single.color, isNotNull);
    });

    test('reset clears colour, bold and dim', () {
      final spans = herdrParseAnsi('\x1b[1;31mrojo\x1b[0mllano');
      expect(spans.first.bold, isTrue);
      expect(spans.last.color, isNull);
      expect(spans.last.bold, isFalse);
    });

    test('background parameters are consumed, not read as colours', () {
      // 48;2;r;g;b must not leave its numbers to be parsed as further codes.
      final spans = herdrParseAnsi('\x1b[48;2;55;55;55mtexto');
      expect(spans.single.color, isNull);
      expect(spans.single.text, 'texto');
    });

    test('non-SGR escapes are dropped, text survives', () {
      final spans = herdrParseAnsi('\x1b[2Klimpio\x1b[Hcasa');
      expect(spans.map((s) => s.text).join(), 'limpiocasa');
    });

    test('plain text yields one uncoloured span', () {
      final spans = herdrParseAnsi('sin color');
      expect(spans.single.text, 'sin color');
      expect(spans.single.color, isNull);
    });
  });

  group('herdrReadableLines: pie de pagina', () {
    test('drops the empty prompt line', () {
      expect(herdrReadableLines('texto\n❯\n'), ['texto']);
      expect(herdrReadableLines('texto\n  ❯  \n'), ['texto']);
    });

    test('drops the status bar, which cannot survive wrapping', () {
      const status =
          '  Opus 5 (1M context)  ~/Desktop/MAN_PC  main  ·  ctx 84%  ·  5h 19%';
      expect(herdrReadableLines('hola\n' + status + '\n'), ['hola']);
    });

    test('drops the permissions hint line', () {
      const hint = '  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 1 agent';
      expect(herdrReadableLines('hola\n' + hint + '\n'), ['hola']);
    });

    test('keeps a prompt line that actually has text in it', () {
      // Only the EMPTY prompt is noise; what you typed is content.
      expect(herdrReadableLines('❯ dime la hora'), ['❯ dime la hora']);
    });

    test('keeps ordinary lines that merely mention a percentage', () {
      const line = 'la cobertura subio al 84% esta semana';
      expect(herdrReadableLines(line), [line]);
    });

    test('keeps real output that merely mentions the hint phrases', () {
      // Captured from a live pane: these are agent output, not chrome, and the
      // unanchored form of _chrome deleted every one of them.
      const lines = [
        '  _chrome matches the bare phrases esc to cancel and type to queue',
        '  it deletes any pane line containing esc to cancel anywhere',
        'pulsa esc to cancel para abortar el comando',
      ];
      for (final line in lines) {
        expect(herdrReadableLines(line), [line], reason: line);
      }
    });

    test('still drops the hint lines themselves', () {
      expect(herdrReadableLines('hola\n  esc to cancel\n'), ['hola']);
      expect(herdrReadableLines('hola\ntype to queue messages\n'), ['hola']);
    });
  });
}
