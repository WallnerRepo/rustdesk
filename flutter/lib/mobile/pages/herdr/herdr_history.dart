/// Recently-opened history for the herdr mobile UI: agents, workspaces,
/// projects and sessions, ranked by recency, pinnable and removable.
///
/// Deliberately free of Flutter and FFI so the whole ranking/grouping/pruning
/// surface is unit-testable. Persistence is a thin adapter on top
/// (`herdr_history_store.dart`): this file only turns JSON into entries and
/// back.
library;

import 'dart:convert';

/// What a history entry points at. The name is persisted, so values must not
/// be renamed without a migration; adding one is safe (unknown kinds are
/// dropped on decode).
///
/// Only two kinds exist because the relay model has only two things worth
/// remembering, under several names:
///  - [agent] is also the "session": a herdr agent IS one pane running one
///    agent session, and the relay exposes no separate session identity.
///  - [workspace] is also the "project": both are the agent's cwd, which is
///    exactly what the relay groups workspaces by (SelectWorkspaceForCwd).
enum HerdrHistoryKind { agent, workspace }

HerdrHistoryKind? _kindFromName(String name) {
  for (final k in HerdrHistoryKind.values) {
    if (k.name == name) return k;
  }
  return null;
}

/// One remembered destination.
class HerdrHistoryEntry {
  const HerdrHistoryEntry({
    required this.kind,
    required this.id,
    required this.label,
    this.subtitle = '',
    this.cwd = '',
    this.workspaceId = '',
    required this.lastOpenedAt,
    this.openCount = 1,
    this.pinned = false,
  });

  final HerdrHistoryKind kind;

  /// Stable identity within [kind] (agent name, workspace id, cwd…).
  final String id;

  final String label;
  final String subtitle;
  final String cwd;
  final String workspaceId;

  /// Unix milliseconds of the last open.
  final int lastOpenedAt;

  final int openCount;
  final bool pinned;

  /// Identity across kinds — two entries with the same key are the same thing.
  String get key => '${kind.name}:$id';

  /// Text a fuzzy query is matched against.
  String get haystack => '$label $subtitle $workspaceId $cwd';

  HerdrHistoryEntry copyWith({
    String? label,
    String? subtitle,
    String? cwd,
    String? workspaceId,
    int? lastOpenedAt,
    int? openCount,
    bool? pinned,
  }) =>
      HerdrHistoryEntry(
        kind: kind,
        id: id,
        label: label ?? this.label,
        subtitle: subtitle ?? this.subtitle,
        cwd: cwd ?? this.cwd,
        workspaceId: workspaceId ?? this.workspaceId,
        lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
        openCount: openCount ?? this.openCount,
        pinned: pinned ?? this.pinned,
      );

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'id': id,
        'label': label,
        if (subtitle.isNotEmpty) 'subtitle': subtitle,
        if (cwd.isNotEmpty) 'cwd': cwd,
        if (workspaceId.isNotEmpty) 'workspace': workspaceId,
        'at': lastOpenedAt,
        'n': openCount,
        if (pinned) 'pin': true,
      };

  /// Null for anything unparseable, so one corrupt row cannot take the whole
  /// history down with it.
  static HerdrHistoryEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kind = _kindFromName('${raw['kind']}');
    final id = raw['id'];
    final label = raw['label'];
    final at = raw['at'];
    if (kind == null || id is! String || id.isEmpty) return null;
    if (label is! String || label.isEmpty) return null;
    if (at is! int) return null;
    final n = raw['n'];
    return HerdrHistoryEntry(
      kind: kind,
      id: id,
      label: label,
      subtitle: raw['subtitle'] is String ? raw['subtitle'] as String : '',
      cwd: raw['cwd'] is String ? raw['cwd'] as String : '',
      workspaceId: raw['workspace'] is String ? raw['workspace'] as String : '',
      lastOpenedAt: at,
      openCount: n is int && n > 0 ? n : 1,
      pinned: raw['pin'] == true,
    );
  }
}

/// A date bucket in the grouped view ("Hoy", "Ayer"…).
class HerdrHistoryGroup {
  const HerdrHistoryGroup(this.title, this.entries);

  final String title;
  final List<HerdrHistoryEntry> entries;
}

/// Immutable-ish history list with recency ordering, pinning and pruning.
///
/// Ordering is always: pinned first, then most recently opened. Pruning never
/// drops a pinned entry.
class HerdrHistory {
  HerdrHistory({List<HerdrHistoryEntry>? entries, this.maxEntries = 60})
      : _entries = [...?entries] {
    _sort();
  }

  /// Cap on unpinned entries. Chosen to stay well inside the local-option
  /// value the Rust core persists while covering weeks of normal use.
  final int maxEntries;

  final List<HerdrHistoryEntry> _entries;

  List<HerdrHistoryEntry> get entries => List.unmodifiable(_entries);

  bool get isEmpty => _entries.isEmpty;

  void _sort() {
    _entries.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.lastOpenedAt.compareTo(a.lastOpenedAt);
    });
  }

  /// Record an open. An existing entry of the same [HerdrHistoryEntry.key] is
  /// refreshed in place (keeping its pin and bumping its counter) rather than
  /// duplicated, so re-opening the same agent never grows the list.
  void record(HerdrHistoryEntry entry) {
    final index = _entries.indexWhere((e) => e.key == entry.key);
    if (index >= 0) {
      final old = _entries[index];
      _entries[index] = old.copyWith(
        label: entry.label,
        subtitle: entry.subtitle,
        cwd: entry.cwd,
        workspaceId: entry.workspaceId,
        lastOpenedAt: entry.lastOpenedAt,
        openCount: old.openCount + 1,
      );
    } else {
      _entries.add(entry);
    }
    _sort();
    _prune();
  }

  void _prune() {
    var unpinned = _entries.where((e) => !e.pinned).length;
    if (unpinned <= maxEntries) return;
    // _entries is sorted, so walking backwards drops the oldest first.
    for (var i = _entries.length - 1; i >= 0 && unpinned > maxEntries; i--) {
      if (_entries[i].pinned) continue;
      _entries.removeAt(i);
      unpinned--;
    }
  }

  bool remove(String key) {
    final before = _entries.length;
    _entries.removeWhere((e) => e.key == key);
    return _entries.length != before;
  }

  void clear({bool keepPinned = true}) {
    _entries.removeWhere((e) => keepPinned ? !e.pinned : true);
  }

  /// Flip the pin on [key]; returns the new state (null when not found).
  bool? togglePin(String key) {
    final index = _entries.indexWhere((e) => e.key == key);
    if (index < 0) return null;
    final next = !_entries[index].pinned;
    _entries[index] = _entries[index].copyWith(pinned: next);
    _sort();
    _prune();
    return next;
  }

  /// Entries bucketed by age relative to [now], pinned lifted into their own
  /// group. Empty buckets are omitted.
  List<HerdrHistoryGroup> grouped(DateTime now) {
    final pinned = <HerdrHistoryEntry>[];
    final buckets = <String, List<HerdrHistoryEntry>>{};
    const order = ['Hoy', 'Ayer', 'Esta semana', 'Este mes', 'Hace tiempo'];

    final startOfToday = DateTime(now.year, now.month, now.day);
    for (final entry in _entries) {
      if (entry.pinned) {
        pinned.add(entry);
        continue;
      }
      final at = DateTime.fromMillisecondsSinceEpoch(entry.lastOpenedAt);
      final days = startOfToday.difference(DateTime(at.year, at.month, at.day)).inDays;
      final String bucket;
      if (days <= 0) {
        bucket = 'Hoy';
      } else if (days == 1) {
        bucket = 'Ayer';
      } else if (days < 7) {
        bucket = 'Esta semana';
      } else if (days < 30) {
        bucket = 'Este mes';
      } else {
        bucket = 'Hace tiempo';
      }
      buckets.putIfAbsent(bucket, () => []).add(entry);
    }

    return [
      if (pinned.isNotEmpty) HerdrHistoryGroup('Fijados', pinned),
      for (final title in order)
        if (buckets[title]?.isNotEmpty ?? false)
          HerdrHistoryGroup(title, buckets[title]!),
    ];
  }

  String encode() =>
      jsonEncode({'v': 1, 'entries': _entries.map((e) => e.toJson()).toList()});

  /// Never throws: unreadable or foreign payloads yield an empty history
  /// rather than breaking the page that reads it.
  static HerdrHistory decode(String? raw, {int maxEntries = 60}) {
    if (raw == null || raw.isEmpty) return HerdrHistory(maxEntries: maxEntries);
    try {
      final data = jsonDecode(raw);
      if (data is! Map || data['v'] != 1) {
        return HerdrHistory(maxEntries: maxEntries);
      }
      final list = data['entries'];
      if (list is! List) return HerdrHistory(maxEntries: maxEntries);
      final entries = <HerdrHistoryEntry>[];
      for (final raw in list) {
        final entry = HerdrHistoryEntry.fromJson(raw);
        if (entry != null) entries.add(entry);
      }
      return HerdrHistory(entries: entries, maxEntries: maxEntries);
    } on FormatException {
      return HerdrHistory(maxEntries: maxEntries);
    }
  }
}
