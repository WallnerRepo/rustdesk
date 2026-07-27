import 'package:flutter_hbb/mobile/pages/herdr/herdr_keymap.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for the Termux-style sticky modifiers and the relay key mapping
/// (control bytes and escape sequences go through send_text as raw bytes).
void main() {
  group('HerdrModifierState', () {
    test('tap cycles off → armed → locked → off', () {
      final state = HerdrModifierState();
      expect(state.ctrl, isFalse);
      state.tap(HerdrKeyModifier.ctrl);
      expect(state.stateOf(HerdrKeyModifier.ctrl), HerdrModState.armed);
      expect(state.ctrl, isTrue);
      state.tap(HerdrKeyModifier.ctrl);
      expect(state.stateOf(HerdrKeyModifier.ctrl), HerdrModState.locked);
      expect(state.ctrl, isTrue);
      state.tap(HerdrKeyModifier.ctrl);
      expect(state.stateOf(HerdrKeyModifier.ctrl), HerdrModState.off);
    });

    test('consume disarms one-shot but keeps locked', () {
      final state = HerdrModifierState();
      state.tap(HerdrKeyModifier.ctrl); // armed
      state.tap(HerdrKeyModifier.alt); // armed
      state.tap(HerdrKeyModifier.alt); // locked
      state.consume();
      expect(state.ctrl, isFalse);
      expect(state.alt, isTrue);
    });
  });

  group('HerdrKeymap.controlByte', () {
    test('letters map to \x01-\x1a', () {
      expect(HerdrKeymap.controlByte('a'), '\x01');
      expect(HerdrKeymap.controlByte('c'), '\x03');
      expect(HerdrKeymap.controlByte('z'), '\x1a');
      expect(HerdrKeymap.controlByte('C'), '\x03');
    });

    test('punctuation aliases', () {
      expect(HerdrKeymap.controlByte('@'), '\x00');
      expect(HerdrKeymap.controlByte('['), '\x1b');
      expect(HerdrKeymap.controlByte('?'), '\x7f');
    });

    test('digits and multi-char strings have no control byte', () {
      expect(HerdrKeymap.controlByte('1'), isNull);
      expect(HerdrKeymap.controlByte('ab'), isNull);
    });
  });

  test('altEscape prefixes ESC', () {
    expect(HerdrKeymap.altEscape('b'), '\x1bb');
  });

  test('modifierParam follows the xterm encoding', () {
    expect(HerdrKeymap.modifierParam(), 1);
    expect(HerdrKeymap.modifierParam(shift: true), 2);
    expect(HerdrKeymap.modifierParam(alt: true), 3);
    expect(HerdrKeymap.modifierParam(ctrl: true), 5);
    expect(HerdrKeymap.modifierParam(shift: true, ctrl: true), 6);
  });

  group('modifiedSpecialKeyText', () {
    test('no modifiers falls back to send_keys', () {
      expect(HerdrKeymap.modifiedSpecialKeyText('Up'), isNull);
    });

    test('Ctrl+arrow uses \x1b[1;5X', () {
      expect(HerdrKeymap.modifiedSpecialKeyText('Up', ctrl: true),
          '\x1b[1;5A');
      expect(HerdrKeymap.modifiedSpecialKeyText('Down', ctrl: true),
          '\x1b[1;5B');
      expect(HerdrKeymap.modifiedSpecialKeyText('Left', ctrl: true),
          '\x1b[1;5D');
      expect(HerdrKeymap.modifiedSpecialKeyText('Right', ctrl: true),
          '\x1b[1;5C');
    });

    test('Alt+arrow uses \x1b[1;3X and combined modifiers add up', () {
      expect(HerdrKeymap.modifiedSpecialKeyText('Up', alt: true), '\x1b[1;3A');
      expect(HerdrKeymap.modifiedSpecialKeyText('Up', shift: true, ctrl: true),
          '\x1b[1;6A');
    });

    test('Ctrl+Home/End and PageUp/PageDown', () {
      expect(HerdrKeymap.modifiedSpecialKeyText('Home', ctrl: true),
          '\x1b[1;5H');
      expect(HerdrKeymap.modifiedSpecialKeyText('End', ctrl: true),
          '\x1b[1;5F');
      expect(HerdrKeymap.modifiedSpecialKeyText('PageUp', ctrl: true),
          '\x1b[5;5~');
      expect(HerdrKeymap.modifiedSpecialKeyText('PageDown', ctrl: true),
          '\x1b[6;5~');
    });

    test('Shift+Tab is backtab', () {
      expect(HerdrKeymap.modifiedSpecialKeyText('Tab', shift: true), '\x1b[Z');
    });

    test('unmapped combos fall back to send_keys', () {
      expect(HerdrKeymap.modifiedSpecialKeyText('Enter', ctrl: true), isNull);
      expect(HerdrKeymap.modifiedSpecialKeyText('Escape', alt: true), isNull);
    });
  });
}
