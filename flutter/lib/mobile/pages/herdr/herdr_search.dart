/// Row composition for the global search palette: merges the live agent list
/// with persisted history into ONE list with no duplicates.
///
/// Pure and Flutter-free so the dedup rules — the part most likely to render
/// the same thing twice — are unit-testable.
library;

import 'herdr_history.dart';
import 'herdr_relay_client.dart';

/// One row of the palette, from either source.
class HerdrSearchRow {
  const HerdrSearchRow({
    required this.title,
    required this.subtitle,
    required this.haystack,
    required this.sortAt,
    this.agent,
    this.entry,
  });

  final String title;
  final String subtitle;

  /// Text a fuzzy query is matched against.
  final String haystack;

  /// Recency used to break score ties.
  final int sortAt;

  /// Live agent backing this row, when there is one.
  final HerdrAgent? agent;

  /// History entry this row came from; null for a purely live row.
  final HerdrHistoryEntry? entry;

  /// A live row is one the user can open right now.
  bool get isLive => agent != null;

  /// True for rows that only exist in history — tapping one starts an agent
  /// in its directory rather than opening something.
  bool get isRemembered => entry != null && agent == null;
}

/// The live agent matching [entry], or null when nothing is running for it.
///
/// Agents are matched by NAME, never by pane id: a restart gives the same
/// agent a new pane, and a history entry recorded before that restart must
/// still resolve to it. Workspace entries match on cwd, which is the relay's
/// own grouping key (SelectWorkspaceForCwd).
HerdrAgent? herdrLiveAgentFor(
    HerdrHistoryEntry entry, Iterable<HerdrAgent> agents) {
  for (final agent in agents) {
    switch (entry.kind) {
      case HerdrHistoryKind.agent:
        if (agent.displayName == entry.id) return agent;
      case HerdrHistoryKind.workspace:
        if (entry.cwd.isNotEmpty && agent.cwd == entry.cwd) return agent;
    }
  }
  return null;
}

/// Live agents first, then history entries that are not already represented.
///
/// Two dedup rules, both about never showing one thing twice:
///  - an `agent` entry whose name is running is dropped: the live row above
///    already IS that agent, and carries its real status.
///  - a `workspace` entry whose cwd has a running agent is dropped for the
///    same reason — the agent row already points at that directory.
/// A workspace with nothing running survives, because it is the only way to
/// get back to a project whose agents are all stopped.
List<HerdrSearchRow> herdrSearchRows({
  required List<HerdrAgent> agents,
  required List<HerdrHistoryEntry> history,
}) {
  final rows = <HerdrSearchRow>[];

  for (final agent in agents) {
    rows.add(HerdrSearchRow(
      title: agent.displayName,
      subtitle: [agent.agent, agent.project, agent.workspaceId]
          .where((s) => s.isNotEmpty)
          .join(' · '),
      haystack: '${agent.workspaceId} ${agent.displayName} ${agent.agent} '
          '${agent.project} ${agent.cwd}',
      sortAt: agent.updatedAt,
      agent: agent,
    ));
  }

  for (final entry in history) {
    if (herdrLiveAgentFor(entry, agents) != null) continue;
    rows.add(HerdrSearchRow(
      title: entry.label,
      subtitle: entry.subtitle,
      haystack: entry.haystack,
      sortAt: entry.lastOpenedAt,
      entry: entry,
    ));
  }
  return rows;
}
