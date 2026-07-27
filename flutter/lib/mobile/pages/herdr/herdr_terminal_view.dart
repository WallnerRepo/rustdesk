import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

/// Readability floor for the auto-fit.
///
/// The host pane is desktop-sized (157 columns is normal) and a phone is
/// ~400 logical pixels wide, so fitting every column meant shrinking the font
/// to single digits — the old floor was 4.0, which is unreadable. Below this
/// the horizontal scroll is the better trade: legible text you pan, instead
/// of the whole width rendered as grey mush.
const double herdrTerminalMinFontSize = 9.0;

/// Ceiling, matching the inline terminal panel's own font size so the two
/// consoles look like the same product.
const double herdrTerminalMaxFontSize = 14.0;

/// Same monospace stack as `desktop/pages/inline_terminal_panel.dart`.
///
/// The view used to pass no fontFamily at all, so it fell back to the
/// platform default (proportional on some Android builds) — box drawing and
/// column alignment broke, which is most of why it looked wrong next to the
/// inline terminal.
const String herdrTerminalFontFamily = 'JetBrainsMono Nerd Font';
const List<String> herdrTerminalFontFallback = [
  'Cascadia Code',
  'Fira Code',
  'Menlo',
  'Consolas',
  'monospace',
];

/// Text style for [size], sharing the panel's family and line height.
TerminalStyle herdrTerminalStyle(double size) => TerminalStyle(
      fontSize: size,
      height: 1.3,
      fontFamily: herdrTerminalFontFamily,
      fontFamilyFallback: herdrTerminalFontFallback,
    );

/// Smallest column count the view will settle on. A momentarily blank or
/// nearly-blank screen must not blow the font up to the ceiling and back.
const int herdrTerminalMinCols = 80;

/// How many consecutive narrower snapshots are needed before shrinking.
const int herdrTerminalShrinkAfter = 3;

/// Grow/shrink policy for the inferred host column count, extracted so it can
/// be tested without a widget tree.
///
/// Grows on the first wider snapshot (the pane really is that wide) but only
/// shrinks once [herdrTerminalShrinkAfter] consecutive snapshots agree, and
/// then to the widest of those. Growth-only pinned the font at the floor for
/// the session after a single long line; shrink-immediately made it jitter on
/// every cleared screen.
class HerdrColsTracker {
  HerdrColsTracker({int cols = herdrTerminalMinCols}) : _cols = cols;

  int _cols;
  int _narrowStreak = 0;
  int _narrowMax = 0;

  int get cols => _cols;

  /// Feed the widest visible line of a snapshot; returns the column count to
  /// render with.
  int update(int observed) {
    if (observed >= _cols) {
      _narrowStreak = 0;
      _narrowMax = 0;
      if (observed > _cols) _cols = observed;
      return _cols;
    }
    _narrowStreak++;
    if (observed > _narrowMax) _narrowMax = observed;
    if (_narrowStreak < herdrTerminalShrinkAfter) return _cols;
    _cols = _narrowMax < herdrTerminalMinCols
        ? herdrTerminalMinCols
        : _narrowMax;
    _narrowStreak = 0;
    _narrowMax = 0;
    return _cols;
  }
}

/// Font size that makes a terminal of [cols] columns fit [availableWidth]
/// exactly (`availableWidth = cols * fontSize * charWidthRatio`), clamped to
/// a usable range. Pure so it stays unit-testable.
double herdrTerminalFitFontSize({
  required int cols,
  required double availableWidth,
  required double charWidthRatio,
  double min = herdrTerminalMinFontSize,
  double max = herdrTerminalMaxFontSize,
}) {
  if (cols <= 0 || availableWidth <= 0 || charWidthRatio <= 0) return max;
  final fit = availableWidth / (cols * charWidthRatio);
  return fit.clamp(min, max);
}

/// xterm-based view of one agent pane snapshot.
///
/// The host pane is far wider than a phone (e.g. 157x58), and TUIs paint
/// with absolute cursor positioning, so the terminal is rendered with
/// EXACTLY the pane's columns — no rewrapping. By default the font is
/// scaled down so the whole width fits the screen (auto-fit); pinch-to-zoom
/// multiplies that base size (0.5x-2.5x — past the screen width the
/// horizontal scroll comes back naturally) and double-tap resets the zoom.
/// Each `read_pane` answer is a full snapshot that is redrawn in place.
class HerdrTerminalView extends StatefulWidget {
  const HerdrTerminalView({
    Key? key,
    required this.content,
    required this.agentType,
  }) : super(key: key);

  /// Latest raw ANSI snapshot (empty until the first read_pane answer).
  final String content;

  /// Agent kind (kept for parity with the caller; currently unused).
  final String agentType;

  @override
  State<HerdrTerminalView> createState() => HerdrTerminalViewState();
}

class HerdrTerminalViewState extends State<HerdrTerminalView> {
  // Same One Dark-inspired palette as the desktop inline terminal panel.
  static const TerminalTheme _theme = TerminalTheme(
    cursor: Color(0xFF61AFEF),
    selection: Color(0x553B4252),
    foreground: Color(0xFFD7DAE0),
    background: Color(0xFF1E1E1E),
    black: Color(0xFF21252B),
    red: Color(0xFFE06C75),
    green: Color(0xFF98C379),
    yellow: Color(0xFFE5C07B),
    blue: Color(0xFF61AFEF),
    magenta: Color(0xFFC678DD),
    cyan: Color(0xFF56B6C2),
    white: Color(0xFFABB2BF),
    brightBlack: Color(0xFF5C6370),
    brightRed: Color(0xFFE06C75),
    brightGreen: Color(0xFF98C379),
    brightYellow: Color(0xFFE5C07B),
    brightBlue: Color(0xFF61AFEF),
    brightMagenta: Color(0xFFC678DD),
    brightCyan: Color(0xFF56B6C2),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0xFFFFFF2B),
    searchHitBackgroundCurrent: Color(0xFF31FF26),
    searchHitForeground: Color(0xFF000000),
  );

  /// Reference style the char-width ratio is measured from.
  static final TerminalStyle _referenceStyle = herdrTerminalStyle(11);

  /// cellWidth / fontSize for the monospace font, measured once.
  late final double _charWidthRatio =
      _measureCell(_referenceStyle).width / _referenceStyle.fontSize;

  /// Zoom factor over the auto-fit font size (pinch), reset on double-tap.
  double _zoom = 1.0;
  double _zoomBase = 1.0;

  /// Cell metrics cache for the current effective font size.
  double _cellFontSize = 0;
  Size _cellSize = Size.zero;

  late final Terminal _terminal;
  final TerminalController _terminalController = TerminalController();

  String _renderedContent = '';

  /// Columns of the host pane, driving both the layout width and the auto-fit
  /// font size. See [HerdrColsTracker] for the grow/shrink policy.
  final HerdrColsTracker _colsTracker = HerdrColsTracker();
  int get _cols => _colsTracker.cols;

  final ScrollController _scrollController = ScrollController();

  /// Trim trailing blank rows: the snapshot is the host screen top-to-bottom
  /// and TUI screens often end with empty padded rows, which would push the
  /// status bar out of the viewport.
  static String _trimTrailingBlankLines(String content) {
    final lines = content.split('\n');
    var end = lines.length;
    while (end > 0 && lines[end - 1].replaceAll(_csiRe, '').trim().isEmpty) {
      end--;
    }
    return lines.sublist(0, end).join('\n');
  }

  static Size _measureCell(TerminalStyle style) {
    const test = 'mmmmmmmmmm';
    final painter = TextPainter(
      text: TextSpan(text: test, style: style.toTextStyle()),
      textDirection: TextDirection.ltr,
    )..layout();
    return Size(painter.width / test.length, painter.height);
  }

  /// Visible-cell width of one ANSI line (runes, ANSI stripped).
  static int _visibleWidth(String line) {
    final clean = line.replaceAll(_csiRe, '');
    return clean.runes.length;
  }

  static final RegExp _csiRe = RegExp('\x1b\\[[0-9;?]*[ -/]*[@-~]');

  @override
  void initState() {
    super.initState();
    // Bounded scrollback: every poll redraws a full snapshot.
    _terminal = Terminal(maxLines: 200);
    // Read-only snapshot view: hide the cursor, the user never types here.
    _terminal.write('\x1b[?25l');
    // Mounting with content already in hand (a rebuild that replaces this
    // State) must paint it: build() no longer renders.
    _renderIfChanged(duringInit: true);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    // TerminalController is a ChangeNotifier; the agent page builds a new
    // view per agent, so not disposing it leaks a listener each time.
    _terminalController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(HerdrTerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _renderIfChanged();
  }

  /// The tracker already holds the new value; this only asks for a repaint.
  /// setState is illegal before the first build, so initState skips it.
  void _setCols(int cols, {required bool duringInit}) {
    if (duringInit) return;
    setState(() {});
  }

  /// Render the latest snapshot. [duringInit] must be true when called from
  /// [initState], where setState is not allowed yet.
  void _renderIfChanged({bool duringInit = false}) {
    if (widget.content == _renderedContent || widget.content.isEmpty) return;
    _renderedContent = widget.content;
    // Stick to the bottom only while the user has not scrolled up (same
    // rule as the relay web app).
    final stick = !_scrollController.hasClients ||
        _scrollController.position.maxScrollExtent -
                _scrollController.position.pixels <
            _cellSize.height * 2;
    final content = _trimTrailingBlankLines(widget.content);
    var observed = 0;
    for (final line in content.split('\n')) {
      final width = _visibleWidth(line);
      if (width > observed) observed = width;
    }
    final before = _cols;
    final cols = _colsTracker.update(observed);
    if (cols != before) {
      // The SizedBox is rebuilt with the new width and autoResize makes the
      // terminal follow; the next poll redraws cleanly.
      _setCols(cols, duringInit: duringInit);
    }
    // Reset SGR BEFORE erasing: xterm fills erased cells with the current
    // cursor background, so erasing with a leftover panel bg painted the
    // whole screen with it (the "black blocks").
    final normalized = content.replaceAll('\n', '\r\n');
    _terminal.write('\x1b[0m\x1b[2J\x1b[H$normalized\x1b[0m');
    // Keep the viewport pinned to the bottom of the buffer (the live edge
    // of the TUI) after every redraw, unless the user scrolled up.
    if (stick) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController
              .jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Deliberately NOT rendering here. _renderIfChanged writes to the
    // terminal and can call setState — both illegal as a side effect of
    // build ("setState() called during build"). Content only ever arrives
    // through the widget, so initState and didUpdateWidget cover every case.
    if (widget.content.isEmpty) {
      return Container(
        color: _theme.background,
        child: const Center(
          child:
              Text('Cargando…', style: TextStyle(color: Color(0xFFD7DAE0))),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // Auto-fit: scale the font so the pane's columns fit the screen
        // width; pinch multiplies that base size.
        final fontSize = herdrTerminalFitFontSize(
              cols: _cols,
              availableWidth: constraints.maxWidth - 4,
              charWidthRatio: _charWidthRatio,
            ) *
            _zoom;
        if (fontSize != _cellFontSize) {
          _cellFontSize = fontSize;
          _cellSize = _measureCell(herdrTerminalStyle(fontSize));
        }
        return Container(
          color: _theme.background,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTap: () => setState(() => _zoom = 1.0),
            onScaleStart: (_) => _zoomBase = _zoom,
            onScaleUpdate: (details) {
              final next = (_zoomBase * details.scale).clamp(0.5, 2.5);
              if (next != _zoom) setState(() => _zoom = next);
            },
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: _cols * _cellSize.width + 1,
                child: TerminalView(
                  _terminal,
                  controller: _terminalController,
                  scrollController: _scrollController,
                  theme: _theme,
                  textStyle: herdrTerminalStyle(fontSize),
                  readOnly: true,
                  // Same padding as the inline terminal panel.
                  padding: const EdgeInsets.symmetric(
                      horizontal: 2.5, vertical: 2.0),
                  // Long-press/right-tap copies the selection, like the
                  // panel. Paste is meaningless here: the view is a
                  // read-only snapshot, input goes through the hidden field.
                  onSecondaryTapDown: (details, offset) async {
                    final selection = _terminalController.selection;
                    if (selection == null) return;
                    final text = _terminal.buffer.getText(selection);
                    _terminalController.clearSelection();
                    await Clipboard.setData(ClipboardData(text: text));
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
