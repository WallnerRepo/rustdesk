/// Pane-width lease: asking the relay to reflow an agent's terminal to the
/// width of the phone instead of the desktop's.
///
/// A herdr pane is desktop-wide (181 columns measured) and a phone is ~360
/// logical pixels. [HerdrReadingView] copes by dropping the TUI's decoration
/// and wrapping what is left, which loses alignment and box drawing. Relay
/// 0.12.0 offers the other half of the answer: the `pane_size_lease`
/// capability resizes the pane itself, so the agent RE-RENDERS at the phone's
/// width and the output is meant to be that narrow.
///
/// The catch, and the reason this is opt-in: the lease resizes the real tmux
/// pane, so the same terminal reflows on the DESKTOP too while the phone holds
/// the lease. That is why it is a toggle, why it is off by default, and why it
/// must always be released.
///
/// Pure logic only, so it stays unit-testable without a widget tree — same
/// split as herdr_fuzzy.dart and herdr_search.dart.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/models/platform_model.dart';

/// Column bounds the relay enforces; anything outside is rejected.
const int kHerdrMinPaneColumns = 40;
const int kHerdrMaxPaneColumns = 240;

/// Local-option key for the toggle. Namespaced like [kHerdrHistoryOption].
const String kHerdrPaneWidthOption = 'herdr-fit-pane-width';

/// How many columns of [charWidth]-wide glyphs fit in [width] logical pixels,
/// clamped to what the relay accepts.
///
/// Returns 0 when the inputs cannot produce a sane answer (zero-width layout
/// on the first frame, a font that measured as nothing) so callers can tell
/// "not known yet" from a real narrow width and simply not lease.
int herdrColumnsFor(double width, double charWidth) {
  if (!width.isFinite || !charWidth.isFinite) return 0;
  if (width <= 0 || charWidth <= 0) return 0;
  final columns = width ~/ charWidth;
  if (columns < kHerdrMinPaneColumns) return kHerdrMinPaneColumns;
  if (columns > kHerdrMaxPaneColumns) return kHerdrMaxPaneColumns;
  return columns;
}

/// Whether a new measurement is worth a round trip.
///
/// Re-leasing on every pixel of layout jitter would be one relay command per
/// frame while the keyboard animates, and a resize makes the agent redraw its
/// whole pane. Only a real change of width is worth that.
bool herdrShouldRelease(int leased, int measured) =>
    measured > 0 && leased > 0 && (measured - leased).abs() >= 2;

/// Reads the stored toggle. Synchronous, like [herdrLoadHistory].
bool herdrLoadFitPaneWidth() {
  try {
    return bind.mainGetLocalOption(key: kHerdrPaneWidthOption) == 'Y';
  } catch (e) {
    debugPrint('[herdr] pane-width option load failed: $e');
    return false;
  }
}

/// Persists the toggle. Failures are logged and swallowed: losing a preference
/// is never a reason to break the UI that changed it.
Future<void> herdrSaveFitPaneWidth(bool enabled) async {
  try {
    await bind.mainSetLocalOption(
        key: kHerdrPaneWidthOption, value: enabled ? 'Y' : '');
  } catch (e) {
    debugPrint('[herdr] pane-width option save failed: $e');
  }
}
