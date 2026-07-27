/// Persistence for [HerdrHistory], kept apart from the pure logic so that
/// file stays unit-testable without the Rust bridge.
///
/// Storage is the core's local options (`mainGetLocalOption` /
/// `mainSetLocalOption`), the same mechanism `ab_model` and `printer_model`
/// use. That keeps the herdr feature dependency-free — no shared_preferences
/// in pubspec, nothing new to merge from upstream — and survives restarts and
/// reinstalls of the Flutter layer alike.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'herdr_history.dart';

/// Local-option key. Namespaced so it cannot collide with an upstream option.
const String kHerdrHistoryOption = 'herdr-history';

/// Loads the stored history. Synchronous: `mainGetLocalOption` is a sync FFI
/// call, so callers can use this straight from `initState`.
HerdrHistory herdrLoadHistory() {
  try {
    return HerdrHistory.decode(
        bind.mainGetLocalOption(key: kHerdrHistoryOption));
  } catch (e) {
    debugPrint('[herdr] history load failed: $e');
    return HerdrHistory();
  }
}

/// Persists [history]. Failures are logged and swallowed: losing history is
/// never a reason to break the UI that triggered the save.
Future<void> herdrSaveHistory(HerdrHistory history) async {
  try {
    await bind.mainSetLocalOption(
        key: kHerdrHistoryOption, value: history.encode());
  } catch (e) {
    debugPrint('[herdr] history save failed: $e');
  }
}
