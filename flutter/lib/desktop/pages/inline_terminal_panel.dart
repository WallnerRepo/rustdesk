import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/terminal_model.dart';
import 'package:xterm/xterm.dart';
import 'terminal_connection_manager.dart';

/// An embeddable terminal panel that shows one or more persistent terminal
/// tabs over a single shared terminal connection to [peerId].
///
/// It reuses RustDesk's native terminal stack (TerminalModel + the
/// `terminal-persistent` option), so sessions survive disconnect/idle and
/// reattach on reconnect — no tmux/SSH wrapper, no server/proto changes.
class InlineTerminalPanel extends StatefulWidget {
  final String peerId;
  final String? password;
  final bool? isSharedPassword;
  final bool? forceRelay;

  const InlineTerminalPanel({
    Key? key,
    required this.peerId,
    this.password,
    this.isSharedPassword,
    this.forceRelay,
  }) : super(key: key);

  @override
  State<InlineTerminalPanel> createState() => _InlineTerminalPanelState();
}

class _TerminalTab {
  final int id;
  final TerminalModel model;
  final FocusNode focusNode;
  bool ready;
  // True once the remote shell has exited (e.g. the user typed `exit`).
  bool closed;
  String label;
  VoidCallback? listener;

  _TerminalTab({
    required this.id,
    required this.model,
    required this.focusNode,
    required this.label,
    this.ready = false,
    this.closed = false,
  });
}

class _InlineTerminalPanelState extends State<InlineTerminalPanel> {
  // Offset terminal ids to avoid colliding with a standalone terminal window
  // that may share the same per-peer connection.
  static const int _baseTerminalId = 900;

  late final FFI _ffi;
  final List<_TerminalTab> _tabs = [];
  int _selectedTabIndex = 0;
  int _nextTabId = 0;
  // True once the shared connection has come up (first terminal opened).
  bool _connReady = false;
  // Real terminal cell height (px), reported by the model on resize; used for
  // vertical padding instead of a hardcoded guess.
  double _cellHeight = 18.0;

  @override
  void initState() {
    super.initState();
    // Establish the terminal connection exactly like the stock mobile terminal
    // (peer_card -> connect(isTerminal:true) -> TerminalPage): a plain
    // getConnection + registered TerminalModel. No connToken / persistence
    // toggle / event-callback routing here — those broke the connection.
    _ffi = TerminalConnectionManager.getConnection(
      peerId: widget.peerId,
      password: widget.password,
      isSharedPassword: widget.isSharedPassword,
      forceRelay: widget.forceRelay,
    );
    _ensurePersistent();
    _addTab();
  }

  /// Enable RustDesk's native persistent-terminal option so sessions survive
  /// disconnect/idle and reattach on reconnect. This only flips a local config
  /// bool + queues an option message; it does NOT restart the connection.
  void _ensurePersistent() {
    try {
      final on = bind.sessionGetToggleOptionSync(
        sessionId: _ffi.sessionId,
        arg: kOptionTerminalPersistent,
      );
      if (!on) {
        bind.sessionToggleOption(
          sessionId: _ffi.sessionId,
          value: kOptionTerminalPersistent,
        );
      }
    } catch (e) {
      debugPrint('[InlineTerminalPanel] Failed to enable persistence: $e');
    }
  }

  @override
  void dispose() {
    for (final tab in _tabs) {
      _disposeTab(tab);
    }
    _tabs.clear();
    // Release this panel's single reference to the shared connection.
    TerminalConnectionManager.releaseConnection(widget.peerId);
    super.dispose();
  }

  void _disposeTab(_TerminalTab tab) {
    if (tab.listener != null) {
      tab.model.removeListener(tab.listener!);
    }
    _ffi.unregisterTerminalModel(tab.id);
    tab.model.dispose();
    tab.focusNode.dispose();
  }

  void _addTab() {
    _addTabWithId(_baseTerminalId + _nextTabId);
    _nextTabId++;
  }

  /// Create a tab bound to a specific server-side terminal_id. Used for new
  /// tabs and for restoring surviving persistent sessions after a reconnect.
  /// All tabs share ONE authenticated connection (no per-tab re-login).
  void _addTabWithId(int terminalId, {bool selectNew = true}) {
    if (_tabs.any((t) => t.id == terminalId)) return; // already shown
    final model = TerminalModel(_ffi, terminalId);
    // Focusable from birth so the tab can always receive keyboard input; only
    // rebuild on an actual cell-height change (not every resize frame).
    final focusNode = FocusNode();

    model.onResizeExternal = (w, h, pw, ph) {
      if (ph > 0 && _cellHeight != ph) {
        _cellHeight = ph * 1.0;
        if (mounted) setState(() {});
      }
    };
    // Surface other surviving sessions so we can restore them as tabs.
    model.onPersistentSessions = _restorePersistentSessions;

    final tab = _TerminalTab(
      id: terminalId,
      model: model,
      focusNode: focusNode,
      label: 'Tab ${_tabs.length + 1}',
    );

    tab.listener = () {
      if (!mounted) return;
      if (model.terminalOpened) {
        _connReady = true;
        if (!tab.ready || tab.closed) {
          setState(() {
            tab.ready = true;
            tab.closed = false;
          });
        }
      } else if (tab.ready && !tab.closed) {
        // Was open, now closed (remote shell exited, e.g. `exit`). The model
        // gets the 'closed' event even if this tab's view isn't laid out.
        setState(() => tab.closed = true);
      }
    };
    model.addListener(tab.listener!);

    // Registering lets the FFI drive open()/reattach() on connect AND on
    // reconnect (re-sends OpenTerminal(force) → reattaches to the persistent
    // session and replays output).
    _ffi.registerTerminalModel(terminalId, model);

    // The FFI "ready" event only opens models registered before it fired.
    // A tab added after the connection is already up must be opened directly
    // — on the SAME connection, so no re-login.
    if (_connReady) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) model.onReady();
      });
    }

    _tabs.add(tab);
    if (selectNew) _selectedTabIndex = _tabs.length - 1;
    if (mounted) setState(() {});
  }

  /// On (re)connect the server reports surviving persistent session ids; show
  /// each as a tab so you can switch to whichever you want. Cascades until all
  /// survivors are restored; ids already shown are skipped.
  void _restorePersistentSessions(List<int> ids) {
    for (final id in ids) {
      if (_tabs.any((t) => t.id == id)) continue;
      final offset = id - _baseTerminalId;
      if (offset >= _nextTabId) _nextTabId = offset + 1; // avoid id collisions
      _addTabWithId(id, selectNew: false);
    }
  }

  Future<void> _closeTab(int index) async {
    if (index < 0 || index >= _tabs.length) return;
    final tab = _tabs[index];
    if (!tab.closed) {
      // Killing a LIVE session — confirm, and keep at least one live tab.
      if (_tabs.length <= 1) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(translate('Close')),
          content: Text('${translate('Close')} "${tab.label}"?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(translate('Cancel'))),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(translate('OK'))),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      // Explicit close terminates the server-side session (vs. disconnect/idle,
      // which keeps it alive for reconnect).
      tab.model.closeTerminal();
    }
    // Re-find by identity — _tabs may have changed during the dialog.
    final i = _tabs.indexOf(tab);
    if (i < 0) return;
    _disposeTab(tab);
    _tabs.removeAt(i);
    if (_selectedTabIndex >= _tabs.length) {
      _selectedTabIndex = _tabs.isEmpty ? 0 : _tabs.length - 1;
    }
    if (mounted) setState(() {});
  }

  EdgeInsets _calculatePadding(double heightPx) {
    const defaultPadding = EdgeInsets.symmetric(horizontal: 5.0, vertical: 2.0);
    final cell = _cellHeight > 0 ? _cellHeight : 18.0;
    final rows = (heightPx / cell).floor();
    if (rows <= 0) return defaultPadding;
    final extraSpace = heightPx - rows * cell;
    if (!extraSpace.isFinite || extraSpace < 0) return defaultPadding;
    return EdgeInsets.symmetric(
      horizontal: defaultPadding.horizontal / 2,
      vertical: extraSpace / 2.0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentTab = _tabs.isEmpty ? null : _tabs[_selectedTabIndex];

    return Container(
      color: const Color(0xFF1E1E1E),
      child: Column(
        children: [
          _buildTabBar(),
          if (currentTab != null)
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final view = TerminalView(
                    currentTab.model.terminal,
                    controller: currentTab.model.terminalController,
                    focusNode: currentTab.focusNode,
                    autofocus: true,
                    backgroundOpacity: 0.7,
                    padding: _calculatePadding(constraints.maxHeight),
                    onSecondaryTapDown: (details, offset) async {
                      final selection = currentTab.model.terminalController.selection;
                      if (selection != null) {
                        final text =
                            currentTab.model.terminal.buffer.getText(selection);
                        currentTab.model.terminalController.clearSelection();
                        await Clipboard.setData(ClipboardData(text: text));
                      } else {
                        final data = await Clipboard.getData('text/plain');
                        final text = data?.text;
                        if (text != null) {
                          currentTab.model.terminal.paste(text);
                        }
                      }
                    },
                  );
                  return RepaintBoundary(
                    child: Stack(
                      children: [
                        view,
                        if (!currentTab.ready && !currentTab.closed)
                          Positioned.fill(child: _connectingView()),
                        if (currentTab.closed)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: _closedBanner(currentTab),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _closedBanner(_TerminalTab tab) {
    return Container(
      color: Colors.black.withOpacity(0.65),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.cancel, size: 14, color: Colors.grey.shade400),
          const SizedBox(width: 8),
          Text(translate('Session closed'),
              style: TextStyle(color: Colors.grey.shade300, fontSize: 12)),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => tab.model.openTerminal(force: true),
            child: Text(translate('Restart')),
          ),
        ],
      ),
    );
  }

  Widget _connectingView() {
    return Container(
      color: const Color(0xFF1E1E1E),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.grey.shade500,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '${translate('Connecting')}...',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: const Color(0xFF2D2D2D),
        border: Border(
          bottom: BorderSide(color: Colors.grey.shade800, width: 1),
        ),
      ),
      child: Row(
        children: [
          const SizedBox(width: 8),
          Icon(Icons.terminal, size: 16, color: Colors.grey.shade400),
          // Persistent-session indicator: sessions survive reconnect/idle.
          const SizedBox(width: 6),
          Tooltip(
            message: translate('Keep terminal sessions on disconnect'),
            child: Icon(Icons.push_pin, size: 12, color: Colors.green.shade400),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _tabs.length,
              itemBuilder: (context, index) => _buildTab(index),
            ),
          ),
          IconButton(
            icon: Icon(Icons.add, size: 16, color: Colors.grey.shade400),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: _addTab,
            tooltip: translate('New tab'),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildTab(int index) {
    final tab = _tabs[index];
    final isSelected = index == _selectedTabIndex;
    return GestureDetector(
      onTap: () {
        setState(() => _selectedTabIndex = index);
        // Grab the keyboard when switching to a tab (the view is laid out only
        // after this rebuild, so request focus post-frame).
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _selectedTabIndex == index) {
            tab.focusNode.requestFocus();
          }
        });
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF3D3D3D) : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          border: isSelected
              ? Border.all(color: Colors.blue.shade400, width: 1)
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (tab.closed)
              Icon(Icons.cancel, size: 10, color: Colors.grey.shade500)
            else if (!tab.ready)
              SizedBox(
                width: 8,
                height: 8,
                child: CircularProgressIndicator(
                  strokeWidth: 1,
                  color: Colors.grey.shade500,
                ),
              )
            else
              Icon(Icons.check_circle, size: 10, color: Colors.green.shade400),
            const SizedBox(width: 4),
            Text(
              // Positional label so it stays consistent after close/restore.
              'Tab ${index + 1}',
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.grey.shade400,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(width: 4),
            // Show the close affordance for any extra tab, and for a dead tab
            // even if it's the last one (so it can be removed).
            if (_tabs.length > 1 || tab.closed)
              GestureDetector(
                onTap: () => _closeTab(index),
                child: Icon(Icons.close, size: 12, color: Colors.grey.shade500),
              ),
          ],
        ),
      ),
    );
  }
}
