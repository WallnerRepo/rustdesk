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
  String label;
  VoidCallback? listener;

  _TerminalTab({
    required this.id,
    required this.model,
    required this.focusNode,
    required this.label,
    this.ready = false,
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

  @override
  void initState() {
    super.initState();
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
  /// disconnect/idle and reattach on reconnect (the SSH+tmux-like behavior).
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
    final terminalId = _baseTerminalId + _nextTabId;
    final model = TerminalModel(_ffi, terminalId);
    final focusNode = FocusNode(canRequestFocus: false);

    model.onResizeExternal = (w, h, pw, ph) {
      if (!focusNode.canRequestFocus && w > 0 && h > 0) {
        focusNode.canRequestFocus = true;
      }
      if (mounted) setState(() {});
    };

    final tab = _TerminalTab(
      id: terminalId,
      model: model,
      focusNode: focusNode,
      label: 'Tab ${_nextTabId + 1}',
    );

    tab.listener = () {
      if (model.terminalOpened && !tab.ready && mounted) {
        setState(() => tab.ready = true);
      }
    };
    model.addListener(tab.listener!);

    // Registering the model lets the FFI drive open()/reattach() on connect
    // and reconnect, and routes terminal output back to this model.
    _ffi.registerTerminalModel(terminalId, model);

    _tabs.add(tab);
    _selectedTabIndex = _tabs.length - 1;
    _nextTabId++;
    if (mounted) setState(() {});
  }

  void _closeTab(int index) {
    if (_tabs.length <= 1) return;
    final tab = _tabs[index];
    _disposeTab(tab);
    _tabs.removeAt(index);
    if (_selectedTabIndex >= _tabs.length) {
      _selectedTabIndex = _tabs.length - 1;
    }
    if (mounted) setState(() {});
  }

  EdgeInsets _calculatePadding(double heightPx) {
    const defaultPadding = EdgeInsets.symmetric(horizontal: 5.0, vertical: 2.0);
    final rows = (heightPx / 18.0).floor();
    if (rows <= 0) return defaultPadding;
    final extraSpace = heightPx - rows * 18.0;
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
                  return TerminalView(
                    currentTab.model.terminal,
                    controller: currentTab.model.terminalController,
                    focusNode: currentTab.focusNode,
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
                },
              ),
            ),
        ],
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
      onTap: () => setState(() => _selectedTabIndex = index),
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
            if (!tab.ready)
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
              tab.label,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.grey.shade400,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(width: 4),
            if (_tabs.length > 1)
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
