/// The host's known directories, for a zoxide-style picker.
///
/// The relay's `list_directories` takes a path and nothing else — no query, no
/// recursion — so the directory picker could only walk one level at a time.
/// Crawling the tree over the tunnel to build an index would be hundreds of
/// round trips and would still rank a cache directory the same as a project.
///
/// The host already knows the answer: zoxide ranks the directories you
/// actually visit. `herdr-dirs-http.socket` serves that list on loopback
/// (127.0.0.1:8379), reached through the same tunnel as the quota strip.
///
/// Parsing and ranking are pure here so they stay unit-testable; the fetch is
/// the only part that touches the network.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// One directory the host knows about, with zoxide's frecency score.
class HerdrKnownDir {
  const HerdrKnownDir({required this.path, this.score = 0});

  final String path;
  final double score;

  /// Last path segment — what the row shows big.
  String get name {
    final trimmed =
        path.length > 1 && path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final base = trimmed.split('/').last;
    return base.isEmpty ? trimmed : base;
  }
}

/// Parse the `{"dirs":[{"path":..,"score":..}]}` body.
///
/// Order is preserved: the service emits zoxide's own ranking, best first, and
/// that is the tie-break when scores are equal. A malformed entry is skipped
/// rather than failing the whole list — a picker with some suggestions beats a
/// picker with none.
List<HerdrKnownDir> herdrParseKnownDirs(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! Map) return const [];
  final list = decoded['dirs'];
  if (list is! List) return const [];
  final out = <HerdrKnownDir>[];
  for (final item in list) {
    if (item is! Map) continue;
    final path = item['path'];
    if (path is! String || path.isEmpty) continue;
    final score = item['score'];
    out.add(HerdrKnownDir(
      path: path,
      score: score is num ? score.toDouble() : 0,
    ));
  }
  return out;
}

/// Fetch the host's directory list through the tunnel.
///
/// Returns an empty list on any failure: the service is optional (no zoxide,
/// an older host, the forward not registered), and the picker falls back to
/// browsing level by level.
Future<List<HerdrKnownDir>> herdrFetchKnownDirs(String url) async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 5);
  // Bypass any system proxy: some phones route even localhost through a local
  // proxy app, which fails with a "Connection refused" to the proxy's port.
  client.findProxy = (_) => 'DIRECT';
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close().timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) return const [];
    final body = await response.transform(utf8.decoder).join();
    return herdrParseKnownDirs(body);
  } catch (e) {
    debugPrint('[herdr] known dirs fetch failed: $e');
    return const [];
  } finally {
    client.close(force: true);
  }
}
