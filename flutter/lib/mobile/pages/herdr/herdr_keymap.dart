/// Termux-style sticky modifiers and key mapping for the herdr special-keys
/// bar. Pure logic, no widgets, so it stays unit-testable.
///
/// What the relay accepts (contracts/fixtures/inbound): `send_keys` takes
/// tmux-style key names (Enter, Escape, Up, F1, …) and `send_text` types a
/// literal string into the pane with no implicit Enter — the equivalent of
/// the RustDesk shell writing raw bytes to the PTY, so control bytes and
/// escape sequences go through `send_text`.
library;

/// The three sticky modifiers of the extra-keys bar.
enum HerdrKeyModifier { ctrl, alt, shift }

/// Sticky state of one modifier: one-shot (applies to the next key only) or
/// locked (applies until tapped again).
enum HerdrModState { off, armed, locked }

/// Sticky modifier state machine (Termux behavior): tap cycles
/// off → armed → locked → off; one-shot modifiers disarm after use.
class HerdrModifierState {
  final Map<HerdrKeyModifier, HerdrModState> _states = {
    for (final mod in HerdrKeyModifier.values) mod: HerdrModState.off,
  };

  HerdrModState stateOf(HerdrKeyModifier mod) => _states[mod]!;

  bool get ctrl => stateOf(HerdrKeyModifier.ctrl) != HerdrModState.off;
  bool get alt => stateOf(HerdrKeyModifier.alt) != HerdrModState.off;
  bool get shift => stateOf(HerdrKeyModifier.shift) != HerdrModState.off;
  bool get anyActive => ctrl || alt || shift;

  /// off → armed → locked → off.
  void tap(HerdrKeyModifier mod) {
    _states[mod] = switch (_states[mod]!) {
      HerdrModState.off => HerdrModState.armed,
      HerdrModState.armed => HerdrModState.locked,
      HerdrModState.locked => HerdrModState.off,
    };
  }

  /// Disarm one-shot modifiers after they have been applied to a key.
  /// Locked modifiers stay active.
  void consume() {
    for (final mod in HerdrKeyModifier.values) {
      if (_states[mod] == HerdrModState.armed) {
        _states[mod] = HerdrModState.off;
      }
    }
  }
}

/// Key mapping helpers: control bytes, alt escapes and xterm modifier
/// sequences for special keys.
class HerdrKeymap {
  HerdrKeymap._();

  /// Control byte for Ctrl+char (\x01-\x1a for a-z/A-Z, plus the usual
  /// punctuation aliases). Null when the combination has no control byte.
  static String? controlByte(String char) {
    if (char.length != 1) return null;
    final code = char.codeUnitAt(0);
    if (code >= 97 && code <= 122) return String.fromCharCode(code - 96);
    if (code >= 65 && code <= 90) return String.fromCharCode(code - 64);
    return switch (char) {
      '@' || ' ' => '\x00',
      '[' => '\x1b',
      '\\' => '\x1c',
      ']' => '\x1d',
      '^' => '\x1e',
      '_' => '\x1f',
      '?' => '\x7f',
      _ => null,
    };
  }

  /// Alt+char is ESC followed by the char.
  static String altEscape(String char) => '\x1b$char';

  /// xterm modifier parameter: 1 + shift(1) + alt(2) + ctrl(4).
  static int modifierParam({
    bool shift = false,
    bool alt = false,
    bool ctrl = false,
  }) =>
      1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0);

  /// `\x1b[1;<param>X` sequence for arrows/Home/End with modifiers.
  static String csiModifierSequence(
    String finalChar, {
    bool shift = false,
    bool alt = false,
    bool ctrl = false,
  }) =>
      '\x1b[1;${modifierParam(shift: shift, alt: alt, ctrl: ctrl)}$finalChar';

  /// `\x1b[<number>;<param>~` sequence for PageUp/PageDown with modifiers.
  static String tildeModifierSequence(
    int number, {
    bool shift = false,
    bool alt = false,
    bool ctrl = false,
  }) =>
      '\x1b[$number;${modifierParam(shift: shift, alt: alt, ctrl: ctrl)}~';

  /// What to send for one named special key while modifiers are active.
  /// Returns a send_text payload, or null to fall back to plain `send_keys`
  /// with [name]. Modifier-less calls always return null.
  static String? modifiedSpecialKeyText(
    String name, {
    bool shift = false,
    bool alt = false,
    bool ctrl = false,
  }) {
    if (!shift && !alt && !ctrl) return null;
    const csiFinals = {
      'Up': 'A',
      'Down': 'B',
      'Right': 'C',
      'Left': 'D',
      'Home': 'H',
      'End': 'F',
    };
    final csiFinal = csiFinals[name];
    if (csiFinal != null) {
      return csiModifierSequence(csiFinal,
          shift: shift, alt: alt, ctrl: ctrl);
    }
    if (name == 'PageUp') {
      return tildeModifierSequence(5, shift: shift, alt: alt, ctrl: ctrl);
    }
    if (name == 'PageDown') {
      return tildeModifierSequence(6, shift: shift, alt: alt, ctrl: ctrl);
    }
    if (name == 'Tab' && shift && !alt && !ctrl) return '\x1b[Z'; // backtab
    return null;
  }
}
