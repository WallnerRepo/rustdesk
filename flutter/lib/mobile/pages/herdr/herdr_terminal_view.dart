import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/models/input_modifier_utils.dart';
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

/// Text style for [size], sharing the panel's monospace family.
///
/// NOTE: no `height` multiplier here, unlike the inline panel. The panel
/// drives a real terminal whose buffer is always fully populated; this view
/// paints a sparse snapshot, and any mismatch between the cell height xterm
/// uses to pick the rows to paint and the one the layout assumes makes it
/// read a buffer slot that was never written — xterm 4.0 then throws
/// "Null check operator used on a null value" from RenderTerminal._paint on
/// EVERY frame, which renders as a black console.
TerminalStyle herdrTerminalStyle(double size) => TerminalStyle(
      fontSize: size,
      fontFamily: herdrTerminalFontFamily,
      fontFamilyFallback: herdrTerminalFontFallback,
    );

/// Buffer capacity, matching the inline terminal panel's `Terminal(maxLines:)`.
///
/// This is NOT about scrollback depth — a snapshot view has none. It is a
/// correctness bound. xterm sizes the terminal from the widget, and
/// `Buffer.eraseDisplay` then walks `viewHeight` rows starting at
/// `scrollBack` (= `height - viewHeight`), so the buffer must be able to hold
/// at least one full viewport. This used to be 200 while a tall phone at the
/// 9pt font floor needs ~218 rows: the circular buffer wrapped, `lines[]`
/// found an empty slot, and its `!` threw "Null check operator used on a null
/// value" on every redraw — the console rendered black. The inline terminal
/// never hit it because it has always used 10000.
const int herdrTerminalMaxLines = 10000;

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

/// Escape sequence that repaints a whole snapshot in place.
///
/// Deliberately does NOT use `\x1b[2J` (erase display). xterm's
/// `Buffer.eraseDisplay` walks `viewHeight` rows of the buffer:
///
/// ```dart
/// for (var i = 0; i < viewHeight; i++) { final line = lines[i + scrollBack]; ... }
/// ```
///
/// and `lines[]` ends in `_getChild(index)!`. After the terminal is resized to
/// more rows than the buffer has materialised, those slots are still empty, so
/// the `!` throws "Null check operator used on a null value" — on every redraw,
/// which left the console completely black. The inline terminal never trips it
/// because it never emits the erase itself: the remote shell does, by which
/// point a real PTY has filled the buffer.
///
/// Instead: home the cursor and rewrite EVERY viewport row, clearing each one
/// with `\x1b[K` (erase-to-end-of-line, which only ever touches the row the
/// cursor is already on) and padding with blank rows past the content. Same
/// visual result, no whole-buffer walk. The leading SGR reset still matters:
/// xterm fills erased cells with the current cursor background, so clearing
/// with a leftover panel background painted the screen with it.
String herdrSnapshotSequence(String content, int viewHeight) {
  final source = content.split('\n');
  final rows = viewHeight > 0 ? viewHeight : source.length;
  // Render the LAST `rows` lines, not the first. The snapshot is a scrollback
  // tail (hundreds of lines) and the live screen is at its END; taking the
  // head painted the oldest, usually blank, part of the tail and the console
  // looked empty even though the content had arrived.
  final first = source.length > rows ? source.length - rows : 0;
  final out = StringBuffer('\x1b[0m\x1b[H');
  for (var i = 0; i < rows; i++) {
    if (i > 0) out.write('\r\n');
    // Clear the row BEFORE drawing it, never after.
    //
    // The relay's snapshot uses CRLF endings, so splitting on '\n' leaves a
    // trailing '\r' on every line. Writing the line and then erasing meant the
    // CR parked the cursor back at column 0 and `\x1b[K` wiped the line that
    // had just been drawn — every row erased itself and the console came out
    // blank even though the content was correct and the terminal was sized.
    out.write('\x1b[K');
    final line = first + i;
    if (line < source.length) {
      final text = source[line];
      // Also drop the trailing CR: it moves the cursor to column 0 and would
      // make anything written after it overwrite this row.
      out.write(text.endsWith('\r')
          ? text.substring(0, text.length - 1)
          : text);
    }
  }
  return (out..write('\x1b[0m')).toString();
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
    this.onInput,
    this.isCtrlLocked,
    this.isAltLocked,
    this.onModifiersConsumed,
    this.focusNode,
    this.fitWidth = false,
  }) : super(key: key);

  /// Latest raw ANSI snapshot (empty until the first read_pane answer).
  final String content;

  /// Agent kind (kept for parity with the caller; currently unused).
  final String agentType;

  /// Where keystrokes go. When null the view stays read-only.
  ///
  /// This is the inline terminal's input model, reused verbatim: xterm owns
  /// the keyboard, IME, selection and paste, and hands us the bytes it would
  /// have written to a PTY through `terminal.onOutput`. We just forward them
  /// to the relay. The previous approach — a hidden 1x1 TextField behind the
  /// terminal — is why typing did not work.
  final void Function(String data)? onInput;

  /// Sticky CTRL/ALT from the keys bar, read at the moment a key is sent so
  /// `prepareTerminalInputPayload` can apply them, exactly like TerminalModel.
  final bool Function()? isCtrlLocked;
  final bool Function()? isAltLocked;

  /// Called after a key consumed a one-shot (armed, not locked) modifier.
  final VoidCallback? onModifiersConsumed;

  /// Focus of the terminal. The caller owns it so the extra-keys bar can hand
  /// focus straight back after a tap, keeping the soft keyboard up — the
  /// inline terminal does exactly this with its per-tab node.
  final FocusNode? focusNode;

  /// Squeeze the host's full width onto the screen instead of keeping the
  /// font readable.
  ///
  /// A herdr pane is desktop-wide (182 columns measured) and a phone is ~360
  /// logical pixels, so the two goals genuinely conflict: either the text is
  /// legible and you pan, or everything fits and it is tiny. This is the
  /// user's choice rather than a guess, exposed as an appbar toggle.
  final bool fitWidth;

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

  /// Used only when the caller does not supply one.
  FocusNode? _ownedFocusNode;
  FocusNode get _focusNode =>
      widget.focusNode ?? (_ownedFocusNode ??= FocusNode());

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
    _terminal = Terminal(maxLines: herdrTerminalMaxLines);
    // ALWAYS hide xterm's own cursor, even when writable. This view paints a
    // snapshot in which the agent's TUI has already drawn its real cursor, so
    // xterm's would be a second, wrong one parked wherever the last write
    // ended — the "focus shows up somewhere else" effect.
    _terminal.write('\x1b[?25l');
    if (widget.onInput != null) {
      // Same wiring as TerminalModel: xterm emits what a PTY would receive.
      _terminal.onOutput = _handleOutput;
    }
    // Mounting with content already in hand (a rebuild that replaces this
    // State) must paint it: build() no longer renders.
    _renderIfChanged(duringInit: true);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _ownedFocusNode?.dispose();
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
  /// Forward a keystroke to the relay, applying the same normalisation the
  /// inline terminal applies before writing to a PTY.
  ///
  /// The '\n' -> '\r' part matters here more than anywhere: Android soft
  /// keyboards send '\n' on Enter, and the agents in these panes are raw-mode
  /// TUIs that only act on '\r'.
  void _handleOutput(String data) {
    final send = widget.onInput;
    if (send == null) return;
    final ctrlLocked = widget.isCtrlLocked?.call() ?? false;
    final altLocked = widget.isAltLocked?.call() ?? false;
    final consumes = (ctrlLocked || altLocked) &&
        shouldApplyTerminalInputModifiers(data);
    final payload = prepareTerminalInputPayload(
      data,
      source: TerminalInputSource.keyboard,
      isMobileOrWebMobile: true,
      bracketedPasteMode: _terminal.bracketedPasteMode,
      ctrlLocked: ctrlLocked,
      altLocked: altLocked,
    );
    if (payload.isNotEmpty) send(payload);
    if (consumes) widget.onModifiersConsumed?.call();
  }

  /// Columns the current buffer content was written at. A resize grows the
  /// buffer with EMPTY slots, and xterm's painter dereferences them, so the
  /// snapshot has to be written again whenever the width changes — not only
  /// when the content does.
  int _renderedCols = 0;

  void _renderIfChanged({bool duringInit = false}) {
    if (widget.content.isEmpty) return;
    if (widget.content == _renderedContent && _renderedCols == _cols) {
        return;
    }
    _renderedContent = widget.content;
    // Stick to the bottom only while the user has not scrolled up (same
    // rule as the relay web app).
    final stick = !_scrollController.hasClients ||
        _scrollController.position.maxScrollExtent -
                _scrollController.position.pixels <
            _cellSize.height * 2;
    final content = _trimTrailingBlankLines(widget.content);
    final source = content.split('\n');
    var observed = 0;
    for (final line in source) {
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
    _terminal.write(herdrSnapshotSequence(content, _terminal.viewHeight));
    // This write went to the terminal at its CURRENT (old) width, so record
    // that; if the width changed, the mismatch is what makes the follow-up
    // below actually re-render instead of hitting the guard.
    _renderedCols = before;
    if (cols != before && !duringInit) {
      // The resize lands on the NEXT layout, after this write, so the rows it
      // adds are still empty slots. Write the snapshot again once the new size
      // is in effect; the guard at the top stops this from looping.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _renderIfChanged();
      });
    }
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
              // Fit mode drops the readability floor so every column lands on
              // screen; pinch-to-zoom still works on top of either mode.
              min: widget.fitWidth ? 3.0 : herdrTerminalMinFontSize,
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
                  // Writable when someone is listening: xterm then owns the
                  // keyboard, IME, selection and paste, like the inline panel.
                  readOnly: widget.onInput == null,
                  focusNode: _focusNode,
                  autofocus: widget.onInput != null,
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
