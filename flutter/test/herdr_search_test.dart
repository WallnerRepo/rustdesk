import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/pages/herdr/herdr_history.dart';
import 'package:flutter_hbb/mobile/pages/herdr/herdr_relay_client.dart';
import 'package:flutter_hbb/mobile/pages/herdr/herdr_search.dart';

HerdrAgent agent(String name, {String cwd = '', String project = ''}) =>
    HerdrAgent(
      paneId: 'w1:p$name',
      name: name,
      agent: 'claude',
      cwd: cwd,
      project: project,
      workspaceId: 'w1',
      updatedAt: 100,
    );

HerdrHistoryEntry hAgent(String id, {String cwd = ''}) => HerdrHistoryEntry(
      kind: HerdrHistoryKind.agent,
      id: id,
      label: id,
      cwd: cwd,
      lastOpenedAt: 50,
    );

HerdrHistoryEntry hWorkspace(String cwd, {String label = 'proj'}) =>
    HerdrHistoryEntry(
      kind: HerdrHistoryKind.workspace,
      id: cwd,
      label: label,
      cwd: cwd,
      lastOpenedAt: 50,
    );

void main() {
  group('herdrLiveAgentFor', () {
    test('matches an agent entry by name, not by pane id', () {
      final live = agent('api');
      expect(herdrLiveAgentFor(hAgent('api'), [live]), same(live));
      expect(herdrLiveAgentFor(hAgent('other'), [live]), isNull);
    });

    test('matches a workspace entry by cwd', () {
      final live = agent('api', cwd: '/home/hyt/api');
      expect(herdrLiveAgentFor(hWorkspace('/home/hyt/api'), [live]), same(live));
      expect(herdrLiveAgentFor(hWorkspace('/home/hyt/web'), [live]), isNull);
    });

    test('a workspace entry with an empty cwd never matches', () {
      final live = agent('api', cwd: '');
      expect(herdrLiveAgentFor(hWorkspace(''), [live]), isNull);
    });

    test('an agent name is not matched against a workspace cwd', () {
      final live = agent('api', cwd: '/home/hyt/api');
      expect(herdrLiveAgentFor(hAgent('/home/hyt/api'), [live]), isNull);
    });
  });

  group('herdrSearchRows dedup', () {
    test('live agents come first', () {
      final rows = herdrSearchRows(
        agents: [agent('api'), agent('web')],
        history: [hAgent('old')],
      );
      expect(rows.map((r) => r.title), ['api', 'web', 'old']);
      expect(rows.take(2).every((r) => r.isLive), isTrue);
    });

    test('a remembered agent that is running is NOT listed twice', () {
      final rows = herdrSearchRows(
        agents: [agent('api')],
        history: [hAgent('api')],
      );
      expect(rows.length, 1);
      expect(rows.single.isLive, isTrue);
    });

    test('a remembered workspace whose cwd has a live agent is dropped', () {
      final rows = herdrSearchRows(
        agents: [agent('api', cwd: '/home/hyt/api')],
        history: [hWorkspace('/home/hyt/api')],
      );
      expect(rows.length, 1);
      expect(rows.single.isLive, isTrue);
    });

    test('a workspace with nothing running survives — it is the way back', () {
      final rows = herdrSearchRows(
        agents: [agent('api', cwd: '/home/hyt/api')],
        history: [hWorkspace('/home/hyt/stopped', label: 'stopped')],
      );
      expect(rows.map((r) => r.title), ['api', 'stopped']);
      expect(rows.last.isRemembered, isTrue);
    });

    test('a stopped agent stays in the list as a remembered row', () {
      final rows = herdrSearchRows(
        agents: const [],
        history: [hAgent('gone', cwd: '/home/hyt/gone')],
      );
      expect(rows.single.isRemembered, isTrue);
      expect(rows.single.isLive, isFalse);
      expect(rows.single.entry!.cwd, '/home/hyt/gone');
    });

    test('empty inputs produce no rows', () {
      expect(herdrSearchRows(agents: const [], history: const []), isEmpty);
    });

    test('haystack covers name, agent kind, project, workspace and cwd', () {
      final rows = herdrSearchRows(
        agents: [agent('api', cwd: '/srv/api', project: 'backend')],
        history: const [],
      );
      final h = rows.single.haystack;
      for (final term in ['api', 'claude', 'backend', 'w1', '/srv/api']) {
        expect(h, contains(term), reason: term);
      }
    });
  });
}
