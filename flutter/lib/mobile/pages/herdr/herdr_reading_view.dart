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
import 'herdr_pane_width.dart';

/// Lines that are pure decoration in an agent TUI and only cost screen space
/// once the text is wrapped.
///
/// Mirrors herdr-remote's CHROME_RE, plus the prompt-box rules Claude Code
/// draws at full pane width — the very lines that force our column count to
/// 181 and make everything else tiny.
/// Anchored to the SHAPE of a hint line, not to the words in it — the same
/// rule [_footer] already follows, and for the same reason.
///
/// `esc to cancel` and `type to queue` used to match anywhere in the line, so
/// any real output that merely MENTIONED them vanished. Verified against a
/// live pane: three lines of an agent discussing this very filter were being
/// deleted from the console. The relay's own classifier anchors it the same
/// way (`/^(?:…|esc to cancel\b.*)$/i`), and the hint lines this is meant to
/// drop start the line — everything else that decorates a working agent
/// (`⏵⏵ …`, the `❯` box, the `ctx NN%` status row) is [_footer]'s job.
final RegExp _chrome = RegExp(
  r'^[\s─-╿_—|◔◑◕●]+$'
  r'|^\s*(?:esc to cancel|type to queue)\b.*$'
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
/// [keep] counts lines that SURVIVED the filter, so it must stay below the
/// number of raw rows fetched ([kHerdrPaneTailLines]) or it silently becomes
/// the real limit on how far you can scroll back.
///
/// The returned lines KEEP their escape sequences: the view colours them with
/// [herdrAnsiTextSpan]. Only the filtering decisions look at the stripped
/// text. Pure, so the filter is unit-testable without a widget tree.
List<String> herdrReadableLines(String content, {int keep = 500}) {
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
  const HerdrReadingView({
    Key? key,
    required this.content,
    this.onColumns,
  }) : super(key: key);

  final String content;

  /// How many columns of this view's own monospace font fit across it.
  ///
  /// Reported from here because this is the only place that knows both the
  /// width it was given and the style it renders with. Fires only when the
  /// number changes. Used for the optional pane-width lease
  /// (herdr_pane_width.dart); null when nobody cares.
  final ValueChanged<int>? onColumns;

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

  /// Memoised parse of [widget.content].
  ///
  /// `build()` used to run herdrReadableLines + herdrAnsiTextSpan every time,
  /// and the parent rebuilds for reasons that have nothing to do with the pane
  /// — a modifier tap, the keyboard-height debounce, any agent's heartbeat.
  /// Measured at 2.5ms for a 240-line tail and 5.5ms for a densely coloured
  /// one, on every one of those. Keyed on the content, so a real change still
  /// re-parses exactly once.
  String? _parsedFor;
  TextSpan? _parsed;
  bool _parsedEmpty = true;

  TextSpan? _spanFor(String content) {
    if (_parsedFor == content) return _parsedEmpty ? null : _parsed;
    final lines = herdrReadableLines(content);
    _parsedFor = content;
    _parsedEmpty = lines.isEmpty;
    _parsed = _parsedEmpty ? null : herdrAnsiTextSpan(lines.join('\n'), _base);
    return _parsed;
  }

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

  /// Width of one glyph in [_base], measured once (the style is const).
  static double? _charWidth;

  static double get charWidth {
    final cached = _charWidth;
    if (cached != null) return cached;
    final painter = TextPainter(
      text: const TextSpan(text: 'M', style: _base),
      textDirection: TextDirection.ltr,
    )..layout();
    return _charWidth = painter.width;
  }

  int _reportedColumns = 0;

  void _reportColumns(double width) {
    final report = widget.onColumns;
    if (report == null) return;
    final columns = herdrColumnsFor(width, charWidth);
    if (columns == 0 || columns == _reportedColumns) return;
    _reportedColumns = columns;
    // Out of the build phase: the listener leases over the network and calls
    // setState on its own page.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => mounted ? report(columns) : null);
  }

  @override
  Widget build(BuildContext context) {
    final span = _spanFor(widget.content);
    if (span == null) {
      return const Center(child: Text('Cargando…'));
    }
    return LayoutBuilder(builder: (context, constraints) {
      // Minus the horizontal padding below, so the number is what actually
      // fits the text.
      _reportColumns(constraints.maxWidth - 24);
      return _buildPane(span);
    });
  }

  Widget _buildPane(TextSpan span) {
    return Container(
      color: const Color(0xFF1E1E1E),
      child: Scrollbar(
        controller: _scroll,
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          // SelectableText builds a read-only EditableText whose focus node can
          // still take primary focus: a plain TAP on the pane called
          // requestKeyboard() on it, and because a read-only field opens no
          // input connection, the composer's connection was torn down and the
          // keyboard vanished. The pane fills ~80% of the screen, so tapping it
          // while reading is the natural gesture. Selection by long-press/drag
          // is unaffected — only the tap-to-focus path is.
          child: Focus(
            canRequestFocus: false,
            descendantsAreFocusable: false,
            child: SelectableText.rich(span, style: _base),
          ),
        ),
      ),
    );
  }
}
