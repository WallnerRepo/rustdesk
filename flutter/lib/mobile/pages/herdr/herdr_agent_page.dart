import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'herdr_fuzzy.dart';
import 'herdr_input_batcher.dart';
import 'herdr_keymap.dart';
import 'herdr_name_dialog.dart';
import 'herdr_relay_client.dart';
import 'herdr_terminal_view.dart';

/// Per-agent view: the pane rendered as a terminal (polled via `read_pane`,
/// the relay has no streaming), a special-keys bar, and the approval/question
/// UI when the agent blocks waiting for a decision.
///
/// You type straight into the console (see [_HerdrAgentPageState._directInput],
/// on by default), like the fork's inline terminal. The appbar toggle swaps
/// that for a prompt composer when you want to edit before sending.
class HerdrAgentPage extends StatefulWidget {
  const HerdrAgentPage({
    Key? key,
    required this.client,
    required this.initialAgent,
  }) : super(key: key);

  final HerdrRelayClient client;
  final HerdrAgent initialAgent;

  @override
  State<HerdrAgentPage> createState() => _HerdrAgentPageState();
}

class _HerdrAgentPageState extends State<HerdrAgentPage>
    with WidgetsBindingObserver {
  /// Adaptive polling bounds: fast while the agent works or the pane keeps
  /// changing, backing off to [_maxPollInterval] when nothing moves.
  static const Duration _minPollInterval = Duration(milliseconds: 1500);
  static const Duration _maxPollInterval = Duration(seconds: 8);

  late HerdrAgent _agent;
  final TextEditingController _promptController = TextEditingController();
  final List<StreamSubscription> _subs = [];
  Timer? _pollTimer;

  Duration _pollInterval = _minPollInterval;
  String _lastContent = '';

  /// Latest raw ANSI snapshot, rendered by [HerdrTerminalView].
  String _content = '';

  /// False while the app is backgrounded: polling stops entirely.
  bool _foreground = true;

  /// Height of the system keyboard, tracked with a debounce like the
  /// RustDesk terminal page so the floating bar sits right above it.
  double _sysKeyboardHeight = 0;
  Timer? _keyboardDebounce;

  /// Guard against duplicate answers.
  bool _responding = false;

  /// Direct terminal input mode: tapping the terminal focuses a hidden text
  /// field whose keystrokes go straight to the agent, exactly like the fork's
  /// inline terminal.
  ///
  /// ON by default. With it off, the only way to type was the prompt text
  /// box below the console, which is not what a terminal should feel like —
  /// you type INTO the console. The prompt field stays available underneath
  /// for long prompts you want to compose before sending.
  bool _directInput = true;
  final FocusNode _directFocusNode = FocusNode();
  final TextEditingController _directController = TextEditingController();
  String _lastDirectText = '';
  late final HerdrInputBatcher _directBatcher =
      HerdrInputBatcher(onFlush: _sendText);

  /// Slash command catalog of this agent; null until loaded, empty when the
  /// agent has none (the "/" button stays hidden then).
  List<HerdrSlashCommand>? _slashCommands;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _agent = widget.initialAgent;

    _subs.add(widget.client.agents.listen(_onAgents));
    _subs.add(widget.client.paneContent.listen(_onPaneContent));
    _subs.add(widget.client.blocked.listen(_onBlocked));

    _poll();
    _schedulePoll();
    unawaited(_loadSlashCommands());
  }

  /// Load the agent's slash command catalog; failures just hide the button.
  Future<void> _loadSlashCommands() async {
    try {
      final commands =
          await widget.client.listSlashCommands(_agent.requestPaneId);
      if (mounted) setState(() => _slashCommands = commands);
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    _keyboardDebounce?.cancel();
    _directBatcher.dispose();
    _directFocusNode.dispose();
    _directController.dispose();
    for (final sub in _subs) {
      sub.cancel();
    }
    _promptController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    _foreground = foreground;
    if (foreground) {
      _poll();
      _schedulePoll();
    } else {
      _pollTimer?.cancel();
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    // Debounced, same as terminal_page.dart: prevents flicker while the
    // system keyboard animates in/out.
    _keyboardDebounce?.cancel();
    _keyboardDebounce = Timer(const Duration(milliseconds: 20), () {
      if (!mounted) return;
      setState(() =>
          _sysKeyboardHeight = MediaQuery.of(context).viewInsets.bottom);
    });
  }

  // ---------------------------------------------------------------------------
  // Adaptive polling
  // ---------------------------------------------------------------------------

  void _schedulePoll() {
    _pollTimer?.cancel();
    if (!_foreground) return;
    _pollTimer = Timer(_pollInterval, () {
      _poll();
      _schedulePoll();
    });
  }

  void _poll() {
    if (!_foreground) return;
    // Roughly one host screen; the xterm view pins to its bottom edge.
    widget.client.readPane(_agent.requestPaneId, lines: 60);
  }

  /// Poll fast again: called after user input so the effect shows up at once.
  void _kickPolling() {
    _pollInterval = _minPollInterval;
    _schedulePoll();
    _poll();
  }

  void _onAgents(List<HerdrAgent> agents) {
    for (final agent in agents) {
      if (agent.paneId == _agent.paneId) {
        if (mounted) setState(() => _agent = agent);
        return;
      }
    }
  }

  void _onBlocked(HerdrAgent agent) {
    if (agent.paneId != _agent.paneId) return;
    setState(() {
      _agent = agent;
      _responding = false;
    });
    _kickPolling();
  }

  void _onPaneContent(HerdrPaneContent frame) {
    if (frame.paneId != _agent.paneId && frame.paneId != _agent.rawPaneId) {
      return;
    }
    // Each read_pane answer is a full snapshot of the pane tail; the view
    // re-renders only when the content actually changed.
    if (frame.content != _content && mounted) {
      setState(() => _content = frame.content);
    }
    _adaptPollInterval(frame.content);
  }

  /// Slow the poll down while the pane is static and the agent is idle, and
  /// speed it back up as soon as something moves or the agent is busy.
  void _adaptPollInterval(String content) {
    final busy = _agent.isWorking || _agent.isBlocked;
    final changed = content != _lastContent;
    _lastContent = content;
    final Duration next;
    if (busy || changed) {
      next = _minPollInterval;
    } else {
      next = _pollInterval * 2 > _maxPollInterval
          ? _maxPollInterval
          : _pollInterval * 2;
    }
    if (next != _pollInterval) {
      _pollInterval = next;
      _schedulePoll();
    }
  }

  // ---------------------------------------------------------------------------
  // Commands
  // ---------------------------------------------------------------------------

  Future<void> _runCommand(Future<HerdrCommandResult> future) async {
    try {
      await future;
      // Refresh soon so the effect of the command is visible without waiting
      // for the next poll tick.
      _kickPolling();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  void _submitPrompt() {
    final text = _promptController.text.trim();
    if (text.isEmpty) return;
    _promptController.clear();
    _lastPromptText = '';
    _runCommand(widget.client.submitPrompt(_agent.requestPaneId, text));
  }

  void _sendKeys(List<String> keys) {
    _runCommand(widget.client.sendKeys(_agent.requestPaneId, keys));
  }

  void _sendText(String text) {
    _runCommand(widget.client.sendText(_agent.requestPaneId, text));
  }

  // ---------------------------------------------------------------------------
  // Sticky modifiers (Termux-style, see herdr_keymap.dart)
  // ---------------------------------------------------------------------------

  final HerdrModifierState _modifiers = HerdrModifierState();

  void _onModifierTap(HerdrKeyModifier mod) {
    HapticFeedback.lightImpact();
    setState(() => _modifiers.tap(mod));
  }

  /// Disarm one-shot modifiers after they have been applied to a key.
  void _consumeModifiers() {
    if (_modifiers.anyActive) setState(() => _modifiers.consume());
  }

  /// Named special key with the active modifiers applied (Ctrl+arrow and
  /// friends become xterm escape sequences sent as raw bytes).
  void _onSpecialKey(String name) {
    HapticFeedback.lightImpact();
    final text = HerdrKeymap.modifiedSpecialKeyText(name,
        shift: _modifiers.shift, alt: _modifiers.alt, ctrl: _modifiers.ctrl);
    if (text != null) {
      _sendText(text);
    } else {
      _sendKeys([name]);
    }
    _consumeModifiers();
  }

  /// Printable symbol from the keys bar with the active modifiers applied.
  void _onTextKey(String char) {
    HapticFeedback.lightImpact();
    _sendText(_modifiedCharPayload(char));
    _consumeModifiers();
  }

  /// Apply the active modifiers to a printable character (bar or keyboard):
  /// Ctrl → control byte, Alt → ESC prefix, Shift → uppercase.
  String _modifiedCharPayload(String char) {
    if (_modifiers.ctrl) {
      return HerdrKeymap.controlByte(char) ?? char;
    }
    if (_modifiers.alt) return HerdrKeymap.altEscape(char);
    if (_modifiers.shift) return char.toUpperCase();
    return char;
  }

  /// Hardware keyboard support for the prompt field (see _buildInputRow):
  /// printable characters edit the controller, Enter submits, Backspace
  /// deletes, and Esc/Tab/arrows are forwarded to the agent as send_keys so
  /// a physical keyboard can drive the TUI directly.
  KeyEventResult _onInputKey(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final modified = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final key = event.logicalKey;
    final forwarded = {
      LogicalKeyboardKey.escape: 'Escape',
      LogicalKeyboardKey.tab: 'Tab',
      LogicalKeyboardKey.arrowUp: 'Up',
      LogicalKeyboardKey.arrowDown: 'Down',
      LogicalKeyboardKey.arrowLeft: 'Left',
      LogicalKeyboardKey.arrowRight: 'Right',
    };
    final sendName = forwarded[key];
    if (sendName != null) {
      _sendKeys([sendName]);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter && !modified) {
      _submitPrompt();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace && !modified) {
      _deleteBackward();
      return KeyEventResult.handled;
    }
    // Injected key events report a null character for Space.
    if (key == LogicalKeyboardKey.space && !modified) {
      _insertText(' ');
      return KeyEventResult.handled;
    }
    if (modified) return KeyEventResult.ignored;
    final character = event.character;
    if (character != null && character.isNotEmpty) {
      if (_modifiers.anyActive) {
        _applyModifiedChar(character);
      } else {
        _insertText(character);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Last committed prompt text, for intercepting IME commits while a
  /// modifier is armed (soft keyboards bypass the key-event path entirely).
  String _lastPromptText = '';
  bool _applyingModifiedInput = false;

  /// Intercept IME commits while a modifier is active: a committed character
  /// is transformed instead of staying in the field (Ctrl+c → \x03). A lone
  /// "/" opens the slash command picker (same as the relay web app).
  void _onPromptChanged(String value) {
    if (_applyingModifiedInput) {
      _lastPromptText = value;
      return;
    }
    final previous = _lastPromptText;
    _lastPromptText = value;
    if (value == '/' && previous.isEmpty && !_modifiers.anyActive) {
      _applyingModifiedInput = true;
      _promptController.value = const TextEditingValue();
      _applyingModifiedInput = false;
      _lastPromptText = '';
      unawaited(_openSlashPicker());
      return;
    }
    if (!_modifiers.anyActive) return;
    if (value.length == previous.length + 1 && value.startsWith(previous)) {
      final char = value.substring(previous.length);
      _applyingModifiedInput = true;
      _promptController.value = TextEditingValue(
        text: previous,
        selection: TextSelection.collapsed(offset: previous.length),
      );
      _applyingModifiedInput = false;
      _lastPromptText = previous;
      _applyModifiedChar(char);
    }
  }

  void _applyModifiedChar(String char) {
    if (_modifiers.ctrl) {
      final byte = HerdrKeymap.controlByte(char);
      if (byte != null) {
        _sendText(byte);
        _consumeModifiers();
        return;
      }
    }
    _sendText(_modifiedCharPayload(char));
    _consumeModifiers();
  }

  // ---------------------------------------------------------------------------
  // Direct terminal input
  // ---------------------------------------------------------------------------

  /// Key events for direct terminal input (hardware keyboard over the
  /// hidden field). Printable text is batched into short send_text payloads;
  /// Enter sends '\r' and Backspace '\x7f', exactly what a shell writes to
  /// the PTY; named keys reuse the special-keys bar mapping.
  KeyEventResult _onDirectKey(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter) {
      _directBatcher.flush();
      _sendText('\r');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace) {
      _directBatcher.flush();
      _sendText('\x7f');
      return KeyEventResult.handled;
    }
    final named = {
      LogicalKeyboardKey.escape: 'Escape',
      LogicalKeyboardKey.tab: 'Tab',
      LogicalKeyboardKey.arrowUp: 'Up',
      LogicalKeyboardKey.arrowDown: 'Down',
      LogicalKeyboardKey.arrowLeft: 'Left',
      LogicalKeyboardKey.arrowRight: 'Right',
      LogicalKeyboardKey.home: 'Home',
      LogicalKeyboardKey.end: 'End',
      LogicalKeyboardKey.pageUp: 'PageUp',
      LogicalKeyboardKey.pageDown: 'PageDown',
    };
    final name = named[key];
    if (name != null) {
      _directBatcher.flush();
      final text = HerdrKeymap.modifiedSpecialKeyText(name,
          shift: _modifiers.shift, alt: _modifiers.alt, ctrl: _modifiers.ctrl);
      if (text != null) {
        _sendText(text);
      } else {
        _sendKeys([name]);
      }
      _consumeModifiers();
      return KeyEventResult.handled;
    }
    final character = event.character;
    if (character != null && character.isNotEmpty) {
      if (_modifiers.anyActive) {
        _directBatcher.flush();
        _sendText(_modifiedCharPayload(character));
        _consumeModifiers();
      } else {
        _directBatcher.add(character);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// IME commits for direct input (soft keyboard): forward the inserted text
  /// and keep the hidden field empty so composition never grows.
  void _onDirectChanged(String value) {
    if (value.length > _lastDirectText.length &&
        value.startsWith(_lastDirectText)) {
      final inserted = value.substring(_lastDirectText.length);
      if (_modifiers.anyActive && inserted.length == 1) {
        _directBatcher.flush();
        _sendText(_modifiedCharPayload(inserted));
        _consumeModifiers();
      } else {
        _directBatcher.add(inserted);
      }
    }
    _directController.value = const TextEditingValue();
    _lastDirectText = '';
  }

  // ---------------------------------------------------------------------------
  // Slash commands
  // ---------------------------------------------------------------------------

  Future<void> _openSlashPicker() async {
    final commands = _slashCommands;
    if (commands == null || commands.isEmpty || !mounted) return;
    final selected = await showModalBottomSheet<HerdrSlashCommand>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _SlashCommandSheet(commands: commands),
    );
    if (selected == null || !mounted) return;
    // Leave the command in the prompt field so the user can add arguments
    // (same as the relay web app) and send with the normal flow.
    _promptController.value = TextEditingValue(
      text: '${selected.command} ',
      selection: TextSelection.collapsed(offset: selected.command.length + 1),
    );
    _lastPromptText = _promptController.text;
  }

  void _insertText(String text) {
    final value = _promptController.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    _promptController.value = TextEditingValue(
      text: value.text.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
    );
    _lastPromptText = _promptController.text;
  }

  void _deleteBackward() {
    final value = _promptController.value;
    final selection = value.selection;
    if (selection.isValid && selection.start != selection.end) {
      _promptController.value = TextEditingValue(
        text: value.text.replaceRange(selection.start, selection.end, ''),
        selection: TextSelection.collapsed(offset: selection.start),
      );
      _lastPromptText = _promptController.text;
      return;
    }
    final caret = selection.isValid ? selection.start : value.text.length;
    if (caret <= 0) return;
    _promptController.value = TextEditingValue(
      text: value.text.replaceRange(caret - 1, caret, ''),
      selection: TextSelection.collapsed(offset: caret - 1),
    );
    _lastPromptText = _promptController.text;
  }

  Future<void> _respond(int index) async {
    setState(() => _responding = true);
    await _runCommand(
        widget.client.respond(_agent.requestPaneId, _agent.eventId, index));
  }

  Future<void> _rename() async {
    final name = await showHerdrRenameDialog(context, _agent.name);
    if (name == null || name.isEmpty || name == _agent.name) return;
    await _runCommand(widget.client.agentRename(_agent.requestPaneId, name));
  }

  Future<void> _stop() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Parar agente'),
        content: Text('¿Parar "${_agent.displayName}"? Se cerrará su terminal.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Parar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.client.agentStop(_agent.requestPaneId);
      widget.client.refreshAgents();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Manual keyboard handling (floating bar above the keyboard), same
      // pattern as the RustDesk terminal page — avoids layout flicker.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_agent.displayName, style: const TextStyle(fontSize: 16)),
            if (_agent.agent.isNotEmpty || _agent.project.isNotEmpty)
              Text(
                [_agent.agent, _agent.project]
                    .where((e) => e.isNotEmpty)
                    .join(' · '),
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.normal),
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(_directInput ? Icons.keyboard : Icons.edit_note,
                color: _directInput ? Colors.greenAccent : null),
            tooltip: _directInput
                ? 'Escribiendo en la consola · toca para redactar un prompt'
                : 'Redactando prompt · toca para escribir en la consola',
            onPressed: () {
              setState(() => _directInput = !_directInput);
              // Focus the hidden field once it exists so the IME opens.
              if (_directInput) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _directFocusNode.requestFocus();
                });
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Actualizar terminal',
            onPressed: _kickPolling,
          ),
          PopupMenuButton<String>(
            tooltip: 'Acciones',
            onSelected: (action) {
              switch (action) {
                case 'rename':
                  _rename();
                case 'restart':
                  _runCommand(
                      widget.client.agentRestart(_agent.requestPaneId));
                case 'clear':
                  _runCommand(widget.client.agentClear(_agent.requestPaneId));
                case 'stop':
                  _stop();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'rename', child: Text('Renombrar')),
              const PopupMenuItem(value: 'restart', child: Text('Reiniciar')),
              const PopupMenuItem(
                  value: 'clear', child: Text('Limpiar terminal')),
              const PopupMenuItem(value: 'stop', child: Text('Parar')),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: SafeArea(
              child: Column(
                children: [
                  if (_agent.isBlocked) _buildAttentionBanner(),
                  Expanded(
                    child: _buildTerminalArea(),
                  ),
                ],
              ),
            ),
          ),
          _buildFloatingBar(),
        ],
      ),
    );
  }

  /// Terminal plus the direct-input machinery: in direct mode, tapping it
  /// focuses a hidden text field whose keystrokes go live to the agent. A
  /// Listener is used (not a GestureDetector) so xterm's own gesture
  /// handlers can't win the arena; the focus request is deferred past
  /// xterm's own tap-focus.
  Widget _buildTerminalArea() {
    return Stack(
      children: [
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _directInput
                ? (_) => WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _directFocusNode.requestFocus();
                    })
                : null,
            child: HerdrTerminalView(
              content: _content,
              agentType: _agent.agent,
            ),
          ),
        ),
        // Hidden field that owns the IME connection in direct mode (the
        // standard invisible-text-input pattern; the TerminalView is not
        // rebuilt). 1x1 and fully transparent.
        if (_directInput)
          Positioned(
            left: 0,
            bottom: 0,
            child: SizedBox(
              width: 1,
              height: 1,
              child: Opacity(
                opacity: 0,
                child: Focus(
                  onKeyEvent: (node, event) => _onDirectKey(event),
                  child: TextField(
                    focusNode: _directFocusNode,
                    controller: _directController,
                    autocorrect: false,
                    enableSuggestions: false,
                    onChanged: _onDirectChanged,
                    onSubmitted: (_) {
                      _directBatcher.flush();
                      _sendText('\r');
                    },
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// Floating bottom section (special-keys bar + prompt input) that sits
  /// right above the system keyboard when it opens — same pattern as the
  /// RustDesk terminal page (resizeToAvoidBottomInset: false + debounced
  /// viewInsets tracking) to avoid layout flicker.
  Widget _buildFloatingBar() {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 200),
      left: 0,
      right: 0,
      bottom: _sysKeyboardHeight,
      child: Container(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildKeysBar(),
              // In direct mode the console IS the input, like the fork's
              // inline terminal — no text box in front of it. The prompt
              // composer comes back with the appbar toggle, for prompts long
              // enough to want editing before sending.
              //
              // Nothing is lost by hiding it here: the relay's slash picker
              // only feeds this field, and in direct mode typing "/" reaches
              // the agent, which shows its OWN command picker in the console.
              if (!_directInput) _buildInputRow(),
            ],
          ),
        ),
      ),
    );
  }

  /// Special-keys bar: Termux-style extra keys with sticky CTRL/ALT/SHIFT
  /// modifiers, keeping the RustDesk shell's two key rows (plus F1-F12) and
  /// button styling. Rows scroll horizontally when they do not fit. Named
  /// keys go through `send_keys`; printable symbols, control bytes and
  /// escape sequences through `send_text` (the relay appends no Enter, like
  /// the shell writing bytes to the PTY).
  Widget _buildKeysBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _scrollableKeyRow([
            _modifierButton('CTRL', HerdrKeyModifier.ctrl),
            _modifierButton('ALT', HerdrKeyModifier.alt),
            _modifierButton('SHIFT', HerdrKeyModifier.shift),
            _keyButton('Esc', () => _onSpecialKey('Escape')),
            _keyButton('/', () => _onTextKey('/')),
            _keyButton('|', () => _onTextKey('|')),
            _keyButton('Home', () => _onSpecialKey('Home')),
            _keyButton('↑', () => _onSpecialKey('Up')),
            _keyButton('End', () => _onSpecialKey('End')),
            _keyButton('PgUp', () => _onSpecialKey('PageUp')),
          ]),
          _scrollableKeyRow([
            _keyButton('Tab', () => _onSpecialKey('Tab')),
            _keyButton('Ctrl+C', () => _onSpecialKey('Ctrl+C')),
            _keyButton('~', () => _onTextKey('~')),
            _keyButton('←', () => _onSpecialKey('Left')),
            _keyButton('↓', () => _onSpecialKey('Down')),
            _keyButton('→', () => _onSpecialKey('Right')),
            _keyButton('PgDn', () => _onSpecialKey('PageDown')),
            _keyButton('Enter', () => _onSpecialKey('Enter')),
            for (var i = 1; i <= 12; i++)
              _keyButton('F$i', () => _onSpecialKey('F$i')),
          ]),
        ],
      ),
    );
  }

  Widget _scrollableKeyRow(List<Widget> buttons) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(children: buttons),
    );
  }

  /// Sticky modifier toggle: highlighted while armed, solid with a lock
  /// marker while locked (tap cycles off → armed → locked → off).
  Widget _modifierButton(String label, HerdrKeyModifier mod) {
    final state = _modifiers.stateOf(mod);
    final colorScheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (state) {
      HerdrModState.off => (
          colorScheme.surfaceContainerHighest,
          colorScheme.onSurfaceVariant
        ),
      HerdrModState.armed => (
          colorScheme.primaryContainer,
          colorScheme.onPrimaryContainer
        ),
      HerdrModState.locked => (colorScheme.primary, colorScheme.onPrimary),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: ElevatedButton(
        onPressed: () => _onModifierTap(mod),
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(48, 32),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          textStyle: const TextStyle(fontSize: 12),
          backgroundColor: background,
          foregroundColor: foreground,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label),
            if (state == HerdrModState.locked) ...[
              const SizedBox(width: 2),
              const Icon(Icons.lock, size: 10),
            ],
          ],
        ),
      ),
    );
  }

  Widget _keyButton(String label, VoidCallback onPressed) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(44, 32),
          padding: EdgeInsets.zero,
          textStyle: const TextStyle(fontSize: 12),
          backgroundColor:
              Theme.of(context).colorScheme.surfaceContainerHighest,
          foregroundColor:
              Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        child: Text(label, maxLines: 1, overflow: TextOverflow.clip),
      ),
    );
  }

  Widget _buildInputRow() {
    final hasSlash = _slashCommands?.isNotEmpty ?? false;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Row(
        children: [
          if (hasSlash)
            IconButton(
              icon: const Text('/',
                  style:
                      TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              tooltip: 'Slash commands',
              onPressed: _openSlashPicker,
            ),
          Expanded(
            // Explicit hardware-keyboard handling: on this app the injected /
            // physical key events are consumed by the framework's keyboard
            // navigation before reaching the EditableText (see the green
            // focus border with hw.keyboard=yes), so a physical keyboard
            // never commits text. Intercepting keys here makes both text
            // entry and terminal control keys work deterministically; the
            // soft keyboard path (IME) is untouched.
            child: Focus(
              onKeyEvent: (node, event) => _onInputKey(event),
              child: TextField(
                controller: _promptController,
                decoration: const InputDecoration(
                  hintText: 'Enviar prompt al agente…',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.send,
                onChanged: _onPromptChanged,
                onSubmitted: (_) => _submitPrompt(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            icon: const Icon(Icons.send),
            tooltip: 'Enviar',
            onPressed: _submitPrompt,
          ),
        ],
      ),
    );
  }

  /// Shown while the agent waits for a decision: a structured question when
  /// the relay classified one, plain approval buttons otherwise.
  Widget _buildAttentionBanner() {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.notification_important,
                    color: colorScheme.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'El agente espera tu decisión',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_agent.interaction != null)
              _QuestionForm(
                agent: _agent,
                busy: _responding,
                onSubmit: (selected, otherSelected, otherText) async {
                  setState(() => _responding = true);
                  await _runCommand(widget.client.answerQuestion(
                    _agent.requestPaneId,
                    _agent.interaction!.id,
                    selectedIndices: selected,
                    otherSelected: otherSelected,
                    otherText: otherText,
                  ));
                },
                onBack: () => _runCommand(widget.client.navigateQuestion(
                    _agent.requestPaneId,
                    _agent.interaction!.id,
                    'previous')),
              )
            else
              _ApprovalOptions(
                agent: _agent,
                busy: _responding,
                onRespond: _respond,
              ),
          ],
        ),
      ),
    );
  }
}

/// Approval buttons for a blocked agent without a structured question.
class _ApprovalOptions extends StatelessWidget {
  const _ApprovalOptions({
    required this.agent,
    required this.busy,
    required this.onRespond,
  });

  final HerdrAgent agent;
  final bool busy;
  final Future<void> Function(int index) onRespond;

  @override
  Widget build(BuildContext context) {
    // The relay sends the option labels shown by the agent (e.g. "Yes",
    // "Yes, and don't ask again", "No"); fall back to a sane default.
    final options =
        agent.options.isNotEmpty ? agent.options : const ['Yes', 'No'];
    final detail = agent.command.isNotEmpty ? agent.command : agent.prompt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (detail.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(detail, maxLines: 4, overflow: TextOverflow.ellipsis),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < options.length; i++)
              FilledButton.tonal(
                onPressed: busy ? null : () => onRespond(i),
                child: Text(options[i]),
              ),
          ],
        ),
      ],
    );
  }
}

/// Structured question form (single/multi select + optional "other" text).
class _QuestionForm extends StatefulWidget {
  const _QuestionForm({
    required this.agent,
    required this.busy,
    required this.onSubmit,
    required this.onBack,
  });

  final HerdrAgent agent;
  final bool busy;
  final Future<void> Function(
          List<int> selected, bool otherSelected, String otherText)
      onSubmit;
  final Future<void> Function() onBack;

  @override
  State<_QuestionForm> createState() => _QuestionFormState();
}

class _QuestionFormState extends State<_QuestionForm> {
  final Set<int> _selected = {};
  bool _otherSelected = false;
  final TextEditingController _otherController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final interaction = widget.agent.interaction!;
    for (final option in interaction.options) {
      if (option.selected) _selected.add(option.index);
    }
    _otherSelected = interaction.otherSelected;
  }

  @override
  void dispose() {
    _otherController.dispose();
    super.dispose();
  }

  void _toggle(int index) {
    final interaction = widget.agent.interaction!;
    setState(() {
      if (interaction.isMultiSelect) {
        _selected.contains(index)
            ? _selected.remove(index)
            : _selected.add(index);
      } else {
        _selected
          ..clear()
          ..add(index);
        _otherSelected = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final interaction = widget.agent.interaction!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (interaction.questionTotal > 1)
          Text('Pregunta ${interaction.questionIndex}/${interaction.questionTotal}',
              style: Theme.of(context).textTheme.labelSmall),
        if (interaction.question.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(interaction.question),
          ),
        for (final option in interaction.options)
          InkWell(
            onTap: widget.busy ? null : () => _toggle(option.index),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(
                    _selected.contains(option.index)
                        ? (interaction.isMultiSelect
                            ? Icons.check_box
                            : Icons.radio_button_checked)
                        : (interaction.isMultiSelect
                            ? Icons.check_box_outline_blank
                            : Icons.radio_button_off),
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(option.label)),
                ],
              ),
            ),
          ),
        if (interaction.otherLabel.isNotEmpty) ...[
          InkWell(
            onTap: widget.busy
                ? null
                : () => setState(() {
                      _otherSelected = !_otherSelected;
                      if (_otherSelected && !interaction.isMultiSelect) {
                        _selected.clear();
                      }
                    }),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(
                    _otherSelected
                        ? (interaction.isMultiSelect
                            ? Icons.check_box
                            : Icons.radio_button_checked)
                        : (interaction.isMultiSelect
                            ? Icons.check_box_outline_blank
                            : Icons.radio_button_off),
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(interaction.otherLabel)),
                ],
              ),
            ),
          ),
          if (_otherSelected)
            TextField(
              controller: _otherController,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                hintText: 'Tu respuesta…',
              ),
            ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            if (interaction.canGoBack)
              TextButton(
                onPressed: widget.busy ? null : widget.onBack,
                child: const Text('Atrás'),
              ),
            const Spacer(),
            FilledButton(
              onPressed: widget.busy
                  ? null
                  : () => widget.onSubmit(_selected.toList()..sort(),
                      _otherSelected, _otherController.text.trim()),
              child: Text(interaction.submitLabel),
            ),
          ],
        ),
      ],
    );
  }
}

/// Slash command picker with fuzzy filtering (same haystack style as the
/// home search): command, description and source.
class _SlashCommandSheet extends StatefulWidget {
  const _SlashCommandSheet({required this.commands});

  final List<HerdrSlashCommand> commands;

  @override
  State<_SlashCommandSheet> createState() => _SlashCommandSheetState();
}

class _SlashCommandSheetState extends State<_SlashCommandSheet> {
  final TextEditingController _queryController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  List<HerdrFuzzyResult<HerdrSlashCommand>> get _results => herdrFuzzyFilter(
        _query,
        widget.commands,
        (command) => '${command.command} ${command.description}',
        (command) => 0,
        maxResults: 30,
      );

  @override
  Widget build(BuildContext context) {
    final results = _results;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          16, 0, 16, MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _queryController,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'Filtrar comandos…',
              prefixIcon: Icon(Icons.bolt),
              isDense: true,
              border: OutlineInputBorder(),
            ),
            textInputAction: TextInputAction.go,
            onChanged: (value) => setState(() => _query = value),
            onSubmitted: (_) {
              if (results.isNotEmpty) {
                Navigator.pop(context, results.first.item);
              }
            },
          ),
          const SizedBox(height: 8),
          Flexible(
            child: results.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Sin resultados'),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: results.length,
                    itemBuilder: (context, index) {
                      final command = results[index].item;
                      return ListTile(
                        dense: true,
                        title: Text(command.command),
                        subtitle: command.description.isNotEmpty
                            ? Text(
                                [
                                  command.description,
                                  if (command.argumentHint.isNotEmpty)
                                    command.argumentHint,
                                ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              )
                            : null,
                        onTap: () => Navigator.pop(context, command),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
