import 'dart:async';

/// Batches printable characters into short `send_text` payloads so live
/// typing does not fire one WebSocket command per keystroke. Pure timing
/// logic, unit-testable.
class HerdrInputBatcher {
  HerdrInputBatcher({
    required this.onFlush,
    this.window = const Duration(milliseconds: 120),
  });

  /// Called with the accumulated text when the batch closes.
  final void Function(String text) onFlush;

  /// Idle time that closes a batch.
  final Duration window;

  String _pending = '';
  Timer? _timer;

  /// Accumulate text; the batch flushes after [window] without more input.
  void add(String text) {
    if (text.isEmpty) return;
    _pending += text;
    _timer?.cancel();
    _timer = Timer(window, flush);
  }

  /// Send whatever is pending right now (before a special key or dispose).
  void flush() {
    _timer?.cancel();
    _timer = null;
    if (_pending.isEmpty) return;
    final text = _pending;
    _pending = '';
    onFlush(text);
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _pending = '';
  }
}
