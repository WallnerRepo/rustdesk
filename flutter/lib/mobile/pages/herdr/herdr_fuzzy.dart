/// Dependency-free subsequence fuzzy matcher for the agent/workspace
/// search. Pure logic, unit-tested.
library;

/// Penalty applied to a match that only succeeded after dropping a mistyped
/// character. Larger than any realistic bonus total for a short query, so an
/// exact subsequence match always outranks a typo match.
const int herdrTypoPenalty = 100;

/// Queries shorter than this are matched strictly: on 1-3 characters a typo
/// budget matches almost everything and the ranking turns to noise.
const int herdrTypoMinQueryLength = 4;

/// Score of [query] against [candidate]: higher is better, null when the
/// query is not a subsequence of the candidate (case-insensitive). Prefix
/// and word-boundary matches weigh more, and consecutive runs are rewarded.
///
/// With [allowTypo] (and a query of at least [herdrTypoMinQueryLength]
/// characters), a query that is NOT a subsequence is retried once per
/// position with that character dropped, and the best result is returned
/// minus [herdrTypoPenalty]. Dropping one character covers the common typo
/// classes — an extra character ("herrdr"), a wrong one ("herdz") and a
/// transposition ("hedrr" still contains h-e-d-r in order) — without the cost
/// of a full edit-distance table.
int? herdrFuzzyScore(String query, String candidate, {bool allowTypo = false}) {
  final exact = _subsequenceScore(query, candidate);
  if (exact != null) return exact;
  if (!allowTypo) return null;

  final q = query.trim();
  if (q.length < herdrTypoMinQueryLength) return null;

  int? best;
  for (var drop = 0; drop < q.length; drop++) {
    final relaxed = q.substring(0, drop) + q.substring(drop + 1);
    final score = _subsequenceScore(relaxed, candidate);
    if (score != null && (best == null || score > best)) best = score;
  }
  return best == null ? null : best - herdrTypoPenalty;
}

/// Strict subsequence scorer — the original, unchanged behaviour.
int? _subsequenceScore(String query, String candidate) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return 0;
  final c = candidate.toLowerCase();
  var score = 0;
  var queryIndex = 0;
  var runLength = 0;
  for (var i = 0; i < c.length && queryIndex < q.length; i++) {
    if (c[i] != q[queryIndex]) {
      runLength = 0;
      continue;
    }
    // Base point per matched char, plus bonuses.
    score += 1;
    if (i == 0) {
      score += 6; // candidate prefix
    } else if (_isBoundary(c[i - 1])) {
      score += 3; // word boundary
    }
    runLength += 1;
    if (runLength > 1) score += 2; // consecutive run
    queryIndex++;
  }
  if (queryIndex < q.length) return null;
  // Shorter candidates with the same match are more relevant.
  return score - (c.length - q.length) ~/ 8;
}

bool _isBoundary(String char) =>
    char == ' ' || char == '/' || char == '_' || char == '-' || char == '·';

/// One fuzzy search result: an agent whose combined haystack matched.
class HerdrFuzzyResult<T> {
  final T item;
  final int score;

  const HerdrFuzzyResult(this.item, this.score);
}

/// Filter and rank [items] by fuzzy score against [query]; the best
/// [maxResults] come first, ties broken by recency (higher timestamp).
///
/// Typo tolerance is opt-in per call site ([allowTypo]) and only kicks in for
/// candidates no strict match found, so exact results are never displaced.
List<HerdrFuzzyResult<T>> herdrFuzzyFilter<T>(
  String query,
  Iterable<T> items,
  String Function(T) haystack,
  int Function(T) updatedAt, {
  int maxResults = 20,
  bool allowTypo = false,
}) {
  final results = <HerdrFuzzyResult<T>>[];
  for (final item in items) {
    final score =
        herdrFuzzyScore(query, haystack(item), allowTypo: allowTypo);
    if (score != null) results.add(HerdrFuzzyResult(item, score));
  }
  results.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    return updatedAt(b.item).compareTo(updatedAt(a.item));
  });
  if (results.length > maxResults) {
    return results.sublist(0, maxResults);
  }
  return results;
}
