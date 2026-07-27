import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_hbb/common/widgets/terminal_extra_keys.dart';

import 'herdr_fuzzy.dart';
import 'herdr_keymap.dart';
import 'herdr_name_dialog.dart';
import 'herdr_reading_view.dart';
import 'herdr_relay_client.dart';

/// Per-agent view: the pane rendered as a terminal (polled via `read_pane`,
/// the relay has no streaming), a special-keys bar, and the approval/question
/// UI when the agent blocks waiting for a decision.
///
/// The pane is shown as wrapped text (herdr_reading_view.dart) and you send
/// with the composer at the bottom. There is no keystroke mode: see
/// _buildTerminalArea for why it was removed.
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

  /// Delay used to coalesce a burst of keystrokes into ONE poll.
  ///
  /// Deliberately not a fast polling window. A `read_pane` answer carries the
  /// pane's whole scrollback — measured at 876 KB on a long-running agent, and
  /// it grows with the session — because the relay ignores `lines`, `limit`
  /// and `source` alike (all three verified against 0.10.6). Polling every
  /// 350ms would push megabytes per second through the tunnel and make the
  /// echo slower, not faster. One poll per burst is the most that pays off.
  static const Duration _inputDebounceDelay = Duration(milliseconds: 150);

  /// Never let continuous typing go longer than this without a refresh.
  ///
  /// A plain debounce was worse than useless here: every keystroke reset it,
  /// so while you typed without pausing NO poll ever fired and the console
  /// only caught up once you stopped — which read as "it only updates when I
  /// send".
  static const Duration _inputPollCeiling = Duration(milliseconds: 700);

  Timer? _inputDebounce;
  DateTime? _lastInputPoll;

  late HerdrAgent _agent;
  final TextEditingController _promptController = TextEditingController();
  final List<StreamSubscription> _subs = [];
  Timer? _pollTimer;

  Duration _pollInterval = _minPollInterval;
  String _lastContent = '';

  /// Latest raw ANSI snapshot, rendered by [HerdrReadingView].
  String _content = '';

  /// False while the app is backgrounded: polling stops entirely.
  bool _foreground = true;


  /// Guard against duplicate answers.
  bool _responding = false;

  /// The agent's pane vanished from the relay's snapshot: nothing sent from
  /// here can arrive any more. See [_onAgents].
  bool _agentGone = false;

  /// Height of the system keyboard, tracked with a debounce like the RustDesk
  /// terminal page.
  ///
  /// The Scaffold deliberately does NOT resize for the keyboard
  /// (`resizeToAvoidBottomInset: false`). Letting it resize re-laid out the
  /// page every time the IME animated in, the terminal lost focus mid-show and
  /// Android cancelled the request — visible as a storm of
  /// `ImeTracker ... onCancelled at PHASE_CLIENT_APPLY_ANIMATION` and, for the
  /// user, a console that would not accept a single keystroke. Instead the
  /// whole column is padded by this height, so the terminal shrinks to fit
  /// above the keyboard without any focus churn.
  double _sysKeyboardHeight = 0;
  Timer? _keyboardDebounce;

  /// Focus of the prompt composer, so the appbar toggle can hand it over.
  final FocusNode _promptFocusNode = FocusNode();

  /// F1..F12 are behind a cap: they are rarely used and doubled the bar.
  bool _showFnKeys = false;

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
    _inputDebounce?.cancel();
    _keyboardDebounce?.cancel();
    _promptFocusNode.dispose();
    for (final sub in _subs) {
      sub.cancel();
    }
    _promptController.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    // Debounced, same as terminal_page.dart: prevents flicker while the
    // system keyboard animates in and out.
    _keyboardDebounce?.cancel();
    _keyboardDebounce = Timer(const Duration(milliseconds: 20), () {
      if (!mounted) return;
      setState(() =>
          _sysKeyboardHeight = MediaQuery.of(context).viewInsets.bottom);
    });
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
        if (mounted) {
          setState(() {
            _agent = agent;
            _agentGone = false;
          });
        }
        return;
      }
    }
    // The pane is no longer in the snapshot: the agent stopped, or herdr
    // restarted and rebuilt its workspaces with new pane ids.
    //
    // This used to fall through silently, leaving a stale `_agent` whose pane
    // no longer exists. Every command then failed on the host with
    // "Agent is unavailable" and every read_pane came back empty, so the
    // console looked frozen and neither the keyboard nor the prompt box
    // appeared to do anything — with nothing on screen to explain why.
    //
    // An empty list is ignored: that is what a reconnect looks like for a
    // moment, and it must not be mistaken for a dead agent.
    if (agents.isEmpty || _agentGone) return;
    if (mounted) setState(() => _agentGone = true);
    _pollTimer?.cancel();
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

  Future<void> _runCommand(Future<HerdrCommandResult> future,
      {bool kick = true}) async {
    try {
      await future;
      if (!kick) return;
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
    _runCommand(widget.client.sendText(_agent.requestPaneId, text),
        kick: false);
    _kickAfterInput();
  }

  /// Poll fast for a short window after typing, coalescing keystrokes.
  ///
  /// Every command used to kick a poll of its own, and a poll is a ~58 KB
  /// answer (the relay always returns the whole scrollback), so typing "hola"
  /// pushed four of them through the tunnel in a second and the echo lagged
  /// behind the typing. One debounced poll per burst, then a brief fast
  /// cadence so the characters appear as they land, then back to normal.
  void _kickAfterInput() {
    final now = DateTime.now();
    final last = _lastInputPoll;
    // Trailing edge for a short burst, but never starve a long one.
    if (last == null || now.difference(last) >= _inputPollCeiling) {
      _inputDebounce?.cancel();
      _lastInputPoll = now;
      _kickPolling();
      return;
    }
    _inputDebounce?.cancel();
    _inputDebounce = Timer(_inputDebounceDelay, () {
      if (!mounted) return;
      _lastInputPoll = DateTime.now();
      _kickPolling();
    });
  }

  // ---------------------------------------------------------------------------
  // Sticky modifiers (Termux-style, see herdr_keymap.dart)
  // ---------------------------------------------------------------------------

  final HerdrModifierState _modifiers = HerdrModifierState();

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
  /// Forward the few control keys a text field would otherwise swallow, and
  /// let EVERYTHING else reach the field.
  ///
  /// This used to intercept printable characters, Enter and Backspace too and
  /// return `handled`, applying them to the controller by hand — a workaround
  /// for physical keyboards. On a phone that meant the soft keyboard's own
  /// commits never reached the TextField and the prompt box refused to accept
  /// a single letter. The IME path works perfectly well on its own; Enter is
  /// covered by `onSubmitted`, Backspace by the field itself.
  KeyEventResult _onInputKey(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
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
    // A sticky modifier from the keys bar still applies to the next letter.
    final character = event.character;
    if (_modifiers.anyActive && character != null && character.isNotEmpty) {
      _applyModifiedChar(character);
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
      // See _sysKeyboardHeight: the keyboard is handled by padding, not by
      // letting the Scaffold resize, which broke focus and hence typing.
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
      // Column, not a Stack with a floating bar: the bar used to overlay the
      // terminal, so the bottom rows — where the agent's prompt box lives —
      // were rendered but hidden behind it and the system keyboard. The inline
      // terminal panel has always laid it out this way.
      body: SafeArea(
        child: Padding(
          // Shrink the column instead of resizing the Scaffold, so the console
          // clears the keyboard without the terminal ever losing focus.
          padding: EdgeInsets.only(bottom: _sysKeyboardHeight),
          child: Column(
          children: [
            if (_agentGone) _buildAgentGoneBanner(),
            if (_agent.isBlocked && !_agentGone) _buildAttentionBanner(),
            Expanded(child: _buildTerminalArea()),
            _buildKeysBar(),
            // In direct mode the console IS the input, like the inline
            // terminal. The appbar toggle brings the composer back for long
            // prompts; the relay's slash picker only feeds that field, and in
            // direct mode typing "/" reaches the agent's own picker.
            _buildInputRow(),
          ],
          ),
        ),
      ),
    );
  }

  /// The pane, always as wrapped text.
  ///
  /// The faithful xterm view and its per-key input were removed: a 181-column
  /// pane cannot be both legible and complete on a phone, and typing into it
  /// meant a round trip per character with no local echo. The composer below
  /// is simply better over this transport, so there is one mode and no toggle
  /// to get stuck in.
  Widget _buildTerminalArea() => HerdrReadingView(content: _content);


  /// Special-keys bar: Termux-style extra keys with sticky CTRL/ALT/SHIFT
  /// modifiers, keeping the RustDesk shell's two key rows (plus F1-F12) and
  /// button styling. Rows scroll horizontally when they do not fit. Named
  /// keys go through `send_keys`; printable symbols, control bytes and
  /// escape sequences through `send_text` (the relay appends no Enter, like
  /// the shell writing bytes to the PTY).
  /// Shown when the agent's pane disappeared, so a console that can no longer
  /// send anything says so instead of just looking stuck.
  Widget _buildAgentGoneBanner() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: ListTile(
        dense: true,
        leading: Icon(Icons.link_off, color: scheme.onErrorContainer),
        title: Text('Este agente ya no existe',
            style: TextStyle(color: scheme.onErrorContainer)),
        subtitle: Text(
          'Su pane desapareció del host (agente parado o herdr reiniciado). '
          'Lo que escribas aquí no llegará a ninguna parte.',
          style: TextStyle(color: scheme.onErrorContainer),
        ),
        trailing: TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Volver'),
        ),
      ),
    );
  }

  /// Extra-keys bar: the SHARED widget, identical to the inline terminal's.
  /// Only the label -> bytes mapping is ours, because this console speaks the
  /// relay protocol instead of writing to a PTY.
  Widget _buildKeysBar() {
    return TerminalExtraKeys(
      onKey: _onExtraKey,
      ctrlActive: _modifiers.ctrl,
      altActive: _modifiers.alt,
      shiftActive: _modifiers.shift,
      onToggleCtrl: () => setState(() => _modifiers.tap(HerdrKeyModifier.ctrl)),
      onToggleAlt: () => setState(() => _modifiers.tap(HerdrKeyModifier.alt)),
      onToggleShift: () =>
          setState(() => _modifiers.tap(HerdrKeyModifier.shift)),
      onInterrupt: () => _onSpecialKey('Ctrl+C'),
      showFunctionKeys: _showFnKeys,
      onToggleFunctionKeys: () => setState(() => _showFnKeys = !_showFnKeys),
      onAfterTap: () {
        // Keep the composer focused so the soft keyboard stays up and a
        // sticky modifier can still apply to the next letter.
        if (!_promptFocusNode.hasFocus) _promptFocusNode.requestFocus();
      },
    );
  }

  /// Map a bar label to this console's transport.
  ///
  /// Named keys the relay understands go through `send_keys`; the symbol caps
  /// are literal text. The shared bar emits arrow glyphs, which the relay
  /// names differently.
  static const Map<String, String> _relayKeyNames = {
    'Esc': 'Escape',
    'Tab': 'Tab',
    '↑': 'Up',
    '↓': 'Down',
    '←': 'Left',
    '→': 'Right',
    'Home': 'Home',
    'End': 'End',
    'PgUp': 'PageUp',
    'PgDn': 'PageDown',
  };

  void _onExtraKey(String label) {
    final named = _relayKeyNames[label];
    if (named != null) {
      _onSpecialKey(named);
    } else if (label.startsWith('F') && label.length <= 3) {
      _onSpecialKey(label);
    } else {
      _onTextKey(label);
    }
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
                focusNode: _promptFocusNode,
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
