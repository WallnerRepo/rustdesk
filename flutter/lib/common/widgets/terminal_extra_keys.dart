/// The accessory key bar shown above the soft keyboard in terminal screens.
///
/// ONE implementation shared by the fork's two terminal surfaces — the inline
/// terminal panel (`desktop/pages/inline_terminal_panel.dart`, also used on
/// mobile) and the herdr agent console
/// (`mobile/pages/herdr/herdr_agent_page.dart`). They used to carry separate,
/// drifting copies: same idea, different layout, different styling, different
/// focus behaviour. Anything changed here now lands in both.
///
/// The widget owns presentation and the key VOCABULARY only. Each screen maps
/// a label to bytes its own way (the inline panel writes to a PTY, the herdr
/// console sends relay messages), which is the one thing that genuinely
/// differs between them.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Escape sequences for the named keys this bar emits.
///
/// Shared so both screens agree on what 'PgUp' means. Anything not in here is
/// sent literally (the symbol caps: `-`, `/`, `|`, `~`, `` ` ``).
const Map<String, String> kTerminalKeySequences = {
  'Esc': '\x1B',
  'Tab': '\t',
  '↑': '\x1B[A',
  '↓': '\x1B[B',
  '→': '\x1B[C',
  '←': '\x1B[D',
  'Home': '\x1B[H',
  'End': '\x1B[F',
  'PgUp': '\x1B[5~',
  'PgDn': '\x1B[6~',
};

/// A Termius-style accessory bar: one scrollable row docked above the system
/// keyboard, with sticky Ctrl/Alt that highlight while armed and combine with
/// the next key (this bar's or the system keyboard's).
class TerminalExtraKeys extends StatelessWidget {
  const TerminalExtraKeys({
    Key? key,
    required this.onKey,
    required this.ctrlActive,
    required this.altActive,
    required this.onToggleCtrl,
    required this.onToggleAlt,
    this.onAfterTap,
    this.shiftActive,
    this.onToggleShift,
    this.showFunctionKeys = false,
    this.onToggleFunctionKeys,
    this.onInterrupt,
  }) : super(key: key);

  /// Receives a label from [kTerminalKeySequences] or a literal symbol.
  final void Function(String label) onKey;

  final bool ctrlActive;
  final bool altActive;
  final VoidCallback onToggleCtrl;
  final VoidCallback onToggleAlt;

  /// Runs after every cap. Both screens use it to hand focus back to the
  /// terminal — see [_KeyCap] for why that matters.
  final VoidCallback? onAfterTap;

  /// Shift is optional: the inline panel has no use for it, the herdr console
  /// applies it to the next key.
  final bool? shiftActive;
  final VoidCallback? onToggleShift;

  /// F1..F12 behind a cap. They are rare and would otherwise double the bar's
  /// height, which is what made the herdr console feel cramped.
  final bool showFunctionKeys;
  final VoidCallback? onToggleFunctionKeys;

  /// Ctrl+C, offered as its own cap where the screen wants it.
  final VoidCallback? onInterrupt;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF161618),
        border: Border(top: BorderSide(color: Color(0xFF333336), width: 1)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Row(
          children: [
            _cap(label: 'esc', onTap: () => onKey('Esc')),
            _cap(label: 'ctrl', active: ctrlActive, onTap: onToggleCtrl),
            _cap(label: 'alt', active: altActive, onTap: onToggleAlt),
            if (onToggleShift != null)
              _cap(
                  label: 'shift',
                  active: shiftActive ?? false,
                  onTap: onToggleShift!),
            _cap(label: 'tab', onTap: () => onKey('Tab')),
            _separator(),
            _cap(icon: Icons.west, onTap: () => onKey('←')),
            _cap(icon: Icons.north, onTap: () => onKey('↑')),
            _cap(icon: Icons.south, onTap: () => onKey('↓')),
            _cap(icon: Icons.east, onTap: () => onKey('→')),
            _separator(),
            for (final s in const ['-', '/', '|', '~', '`'])
              _cap(label: s, onTap: () => onKey(s)),
            _separator(),
            for (final k in const ['Home', 'End', 'PgUp', 'PgDn'])
              _cap(label: k, onTap: () => onKey(k)),
            if (onInterrupt != null) ...[
              _separator(),
              _cap(label: '^C', onTap: onInterrupt!),
            ],
            if (onToggleFunctionKeys != null) ...[
              _cap(
                label: showFunctionKeys ? 'fn ▾' : 'fn ▸',
                active: showFunctionKeys,
                onTap: onToggleFunctionKeys!,
              ),
              if (showFunctionKeys)
                for (var i = 1; i <= 12; i++)
                  _cap(label: 'F$i', onTap: () => onKey('F$i')),
            ],
          ],
        ),
      ),
    );
  }

  Widget _separator() => Container(
        width: 1,
        height: 18,
        margin: const EdgeInsets.symmetric(horizontal: 7),
        color: const Color(0xFF38383B),
      );

  Widget _cap({
    String? label,
    IconData? icon,
    bool active = false,
    required VoidCallback onTap,
  }) =>
      _KeyCap(
        label: label,
        icon: icon,
        active: active,
        onTap: onTap,
        onAfterTap: onAfterTap,
      );
}

class _KeyCap extends StatelessWidget {
  const _KeyCap({
    this.label,
    this.icon,
    required this.active,
    required this.onTap,
    this.onAfterTap,
  });

  final String? label;
  final IconData? icon;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback? onAfterTap;

  @override
  Widget build(BuildContext context) {
    final fg = active ? Colors.white : const Color(0xFFCED0D4);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Material(
        color: active ? const Color(0xFF3B6FE0) : const Color(0xFF2B2B2E),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          // Never take focus from the terminal — otherwise the soft keyboard
          // closes and the armed modifier has no next key to combine with.
          canRequestFocus: false,
          onTap: () {
            HapticFeedback.lightImpact();
            onTap();
            onAfterTap?.call();
          },
          child: Container(
            height: 34,
            constraints: const BoxConstraints(minWidth: 42),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            child: icon != null
                ? Icon(icon, size: 17, color: fg)
                : Text(
                    label!,
                    style: TextStyle(
                      color: fg,
                      fontSize: 13,
                      height: 1.0,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
