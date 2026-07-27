/// Minimal ANSI SGR -> Flutter spans, for the reading view.
///
/// The reading view used to strip every escape, which made an agent pane —
/// diffs, prompts, status, all colour-coded — come out as a flat grey wall.
/// This keeps the colour while still wrapping the text, which is the whole
/// point of that mode.
///
/// Deliberately partial: only what an agent TUI actually uses for text.
/// Backgrounds are dropped on purpose — Claude Code paints full-width blocks
/// behind its boxes, and once the text is re-wrapped those blocks land on the
/// wrong cells and look like corruption.
library;

import 'package:flutter/material.dart';

/// One run of text sharing a style.
class HerdrAnsiSpan {
  const HerdrAnsiSpan(this.text, {this.color, this.bold = false, this.dim = false});

  final String text;
  final Color? color;
  final bool bold;
  final bool dim;
}

/// The 16 ANSI colours, in the One Dark palette the terminal view uses, so
/// both consoles agree on what "red" looks like.
const List<Color> _basic = [
  Color(0xFF21252B), Color(0xFFE06C75), Color(0xFF98C379), Color(0xFFE5C07B),
  Color(0xFF61AFEF), Color(0xFFC678DD), Color(0xFF56B6C2), Color(0xFFABB2BF),
  Color(0xFF5C6370), Color(0xFFE06C75), Color(0xFF98C379), Color(0xFFE5C07B),
  Color(0xFF61AFEF), Color(0xFFC678DD), Color(0xFF56B6C2), Color(0xFFFFFFFF),
];

/// xterm 256-colour cube entry.
Color _xterm256(int n) {
  if (n < 16) return _basic[n];
  if (n < 232) {
    final i = n - 16;
    const steps = [0, 95, 135, 175, 215, 255];
    return Color.fromARGB(
        255, steps[i ~/ 36], steps[(i ~/ 6) % 6], steps[i % 6]);
  }
  final grey = 8 + (n - 232) * 10;
  return Color.fromARGB(255, grey, grey, grey);
}

final RegExp _sgr = RegExp('\x1b\\[([0-9;]*)m');
final RegExp _otherEscape = RegExp('\x1b\\[[0-9;?]*[ -/]*[@-ln-~]|\x1b\\][^\x07\x1b]*(\x07|\x1b\\\\)');

/// Parse [input] into styled runs. Never throws: anything unrecognised is
/// dropped and the text is kept.
List<HerdrAnsiSpan> herdrParseAnsi(String input) {
  final spans = <HerdrAnsiSpan>[];
  Color? color;
  var bold = false;
  var dim = false;
  var index = 0;

  void emit(String text) {
    if (text.isEmpty) return;
    // Strip any non-SGR escape left over (cursor moves, OSC titles).
    final clean = text.replaceAll(_otherEscape, '').replaceAll('\r', '');
    if (clean.isEmpty) return;
    spans.add(HerdrAnsiSpan(clean, color: color, bold: bold, dim: dim));
  }

  for (final match in _sgr.allMatches(input)) {
    emit(input.substring(index, match.start));
    index = match.end;
    final body = match.group(1) ?? '';
    final codes = body.isEmpty
        ? <int>[0]
        : body.split(';').map((c) => int.tryParse(c) ?? 0).toList();
    for (var i = 0; i < codes.length; i++) {
      final code = codes[i];
      if (code == 0) {
        color = null;
        bold = false;
        dim = false;
      } else if (code == 1) {
        bold = true;
      } else if (code == 2) {
        dim = true;
      } else if (code == 22) {
        bold = false;
        dim = false;
      } else if (code >= 30 && code <= 37) {
        color = _basic[code - 30];
      } else if (code >= 90 && code <= 97) {
        color = _basic[code - 90 + 8];
      } else if (code == 39) {
        color = null;
      } else if (code == 38 && i + 1 < codes.length) {
        // 38;5;n (256) or 38;2;r;g;b (truecolour)
        if (codes[i + 1] == 5 && i + 2 < codes.length) {
          color = _xterm256(codes[i + 2]);
          i += 2;
        } else if (codes[i + 1] == 2 && i + 4 < codes.length) {
          color = Color.fromARGB(255, codes[i + 2], codes[i + 3], codes[i + 4]);
          i += 4;
        }
      } else if (code == 48 && i + 1 < codes.length) {
        // Backgrounds are ignored, but their parameters must still be consumed
        // or the colour numbers would be read as further SGR codes.
        if (codes[i + 1] == 5) {
          i += 2;
        } else if (codes[i + 1] == 2) {
          i += 4;
        }
      }
    }
  }
  emit(input.substring(index));
  return spans;
}

/// Build the [TextSpan] tree for [input] under [base].
TextSpan herdrAnsiTextSpan(String input, TextStyle base) => TextSpan(
      children: [
        for (final span in herdrParseAnsi(input))
          TextSpan(
            text: span.text,
            style: base.copyWith(
              color: span.dim
                  ? (span.color ?? base.color)?.withOpacity(0.6)
                  : span.color,
              fontWeight: span.bold ? FontWeight.w700 : null,
            ),
          ),
      ],
    );
