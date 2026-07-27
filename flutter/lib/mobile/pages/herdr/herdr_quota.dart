import 'dart:convert';
import 'dart:io';

/// One quota window of a provider (`5h`, `7d`, `ciclo`, …).
class HerdrQuotaWindow {
  final String label;

  /// Remaining percentage 0-100.
  final double remaining;

  const HerdrQuotaWindow({required this.label, required this.remaining});
}

/// aiuse quota for one provider: all of its windows, sorted by severity
/// (lowest remaining first).
class HerdrQuotaEntry {
  /// Provider key as served (`claude`, `kimi`, …).
  final String provider;
  final String plan;
  final List<HerdrQuotaWindow> windows;

  const HerdrQuotaEntry({
    required this.provider,
    this.plan = '',
    this.windows = const [],
  });

  /// Worst (lowest) remaining across windows; 0 with no windows.
  double get worstRemaining =>
      windows.isEmpty ? 0 : windows.first.remaining;

  /// `Claude` / `Kimi` style provider name.
  String get displayName => provider
      .split('-')
      .map((part) =>
          part.isEmpty ? part : part[0].toUpperCase() + part.substring(1))
      .join(' ');
}

/// Providers the user does not use: hidden from the strip entirely.
const Set<String> herdrQuotaHiddenProviders = {'opencode-go'};

/// Parse the aiuse `usage.json` payload: one entry per visible provider
/// with ALL its windows sorted by severity. Pure, unit-tested.
List<HerdrQuotaEntry> herdrParseUsage(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! Map) return const [];
  final entries = <HerdrQuotaEntry>[];
  for (final item in decoded.entries) {
    if (item.key == 'ts' ||
        herdrQuotaHiddenProviders.contains(item.key) ||
        item.value is! Map) {
      continue;
    }
    final provider = Map<String, dynamic>.from(item.value as Map);
    final rawWindows = provider['windows'];
    if (rawWindows is! List) continue;
    final windows = <HerdrQuotaWindow>[];
    for (final rawWindow in rawWindows) {
      if (rawWindow is! Map) continue;
      final remaining = (rawWindow['remaining'] as num?)?.toDouble();
      if (remaining == null) continue;
      windows.add(HerdrQuotaWindow(
        label: rawWindow['label'] as String? ?? '',
        remaining: remaining,
      ));
    }
    if (windows.isEmpty) continue;
    windows.sort((a, b) => a.remaining.compareTo(b.remaining));
    entries.add(HerdrQuotaEntry(
      provider: item.key,
      plan: provider['plan'] as String? ?? '',
      windows: windows,
    ));
  }
  entries.sort((a, b) => a.worstRemaining.compareTo(b.worstRemaining));
  return entries;
}

/// Fetch the quota over the tunnel. Throws on any failure — the caller
/// hides the strip silently in that case.
Future<List<HerdrQuotaEntry>> herdrFetchQuota(String url) async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 5);
  // Same bypass as the relay probe: some phones route even localhost
  // through a local proxy app.
  client.findProxy = (_) => 'DIRECT';
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close().timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) {
      throw HttpException('quota HTTP ${response.statusCode}');
    }
    final body = await response.transform(utf8.decoder).join();
    return herdrParseUsage(body);
  } finally {
    client.close(force: true);
  }
}
