/// Reading mode: the pane as wrapped text instead of as a terminal.
///
/// The faithful terminal view cannot escape the width problem — a herdr pane
/// is desktop-wide (181 columns measured) and a phone is ~360 logical pixels,
/// so either the text is legible and you pan sideways, or it all fits and is
/// unreadable. That is a real trade, not a bug.
///
/// This is the other side of it, and the approach `dcolinmorgan/herdr-remote`
/// takes for its phone UI: drop terminal fidelity, strip the TUI's decoration
/// and wrap the remaining text so it always fits the screen. Their web client
/// renders the pane with `white-space: pre-wrap; word-break: break-all;
/// overflow-x: hidden` after filtering separator rules and spinner lines.
///
/// It also drops the agent's own prompt box and status bar: you send text
/// with the composer, so the pane's input line is dead weight, and a
/// 181-column status row can only shred itself once wrapped.
///
/// This is the DEFAULT on mobile. Alignment and box drawing are lost, so the
/// faithful terminal view stays one tap away for driving an interactive TUI.
library;

import 'package:flutter/material.dart';

import 'herdr_ansi_text.dart';

/// Lines that are pure decoration in an agent TUI and only cost screen space
/// once the text is wrapped.
///
/// Mirrors herdr-remote's CHROME_RE, plus the prompt-box rules Claude Code
/// draws at full pane width — the very lines that force our column count to
/// 181 and make everything else tiny.
final RegExp _chrome = RegExp(
  r'^[\s─-╿_—|◔◑◕●]+$'
  r'|esc to cancel'
  r'|type to queue'
  r'|^\s*[◔◑◕●]\s+(Shell|Bash)',
);

/// The agent's own prompt box and status bar.
///
/// Dropped because on a phone you send text with the composer, so the pane's
/// input line is dead weight — and the status bar is a single 181-column row
/// of `·`-separated segments that can only shred itself once wrapped to 360
/// logical pixels. Everything it reports (model, cwd, context, quota) is
/// either in the app bar already or not worth four broken lines.
///
/// Matched on the stripped text and anchored to the SHAPE of those lines, not
/// to the words in them. Matching bare phrases silently ate real content: a
/// diff line reading `48 + r'|bypass permissions'` disappeared from the
/// console because it mentioned the string. Every pattern here needs the
/// line's structure — an indented status row with `·` separators, or a line
/// that starts with the hint glyph — so ordinary text that happens to discuss
/// these things survives.
final RegExp _footer = RegExp(
  r'^\s*[❯>]\s*$'
  r'|^\s*⏵'
  r'|^\s+\S.*·.*\bctx\s+\d+%',
);

final RegExp _ansi = RegExp('\x1b\\[[0-9;?]*[ -/]*[@-~]');

/// Drop decoration and blank lines, keep the last [keep] lines.
///
/// The returned lines KEEP their escape sequences: the view colours them with
/// [herdrAnsiTextSpan]. Only the filtering decisions look at the stripped
/// text. Pure, so the filter is unit-testable without a widget tree.
List<String> herdrReadableLines(String content, {int keep = 200}) {
  final out = <String>[];
  for (final raw in content.split('\n')) {
    final plain = raw.replaceAll(_ansi, '').replaceAll('\r', '').trimRight();
    if (plain.trim().isEmpty) continue;
    if (_chrome.hasMatch(plain) || _footer.hasMatch(plain)) continue;
    out.add(raw.replaceAll('\r', '').trimRight());
  }
  return out.length > keep ? out.sublist(out.length - keep) : out;
}

/// Wrapped, selectable rendering of a pane snapshot.
class HerdrReadingView extends StatefulWidget {
  const HerdrReadingView({Key? key, required this.content}) : super(key: key);

  final String content;

  @override
  State<HerdrReadingView> createState() => _HerdrReadingViewState();
}

class _HerdrReadingViewState extends State<HerdrReadingView> {
  static const TextStyle _base = TextStyle(
    color: Color(0xFFD7DAE0),
    fontFamily: 'JetBrainsMono Nerd Font',
    fontFamilyFallback: ['monospace'],
    fontSize: 13,
    height: 1.45,
  );

  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(HerdrReadingView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.content == oldWidget.content) return;
    // Stick to the live edge unless the user scrolled up to read back.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final atBottom =
          _scroll.position.maxScrollExtent - _scroll.position.pixels < 80;
      if (atBottom) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final lines = herdrReadableLines(widget.content);
    if (lines.isEmpty) {
      return const Center(child: Text('Cargando…'));
    }
    return Container(
      color: const Color(0xFF1E1E1E),
      child: Scrollbar(
        controller: _scroll,
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: SelectableText.rich(
            herdrAnsiTextSpan(lines.join('\n'), _base),
            style: _base,
          ),
        ),
      ),
    );
  }
}
