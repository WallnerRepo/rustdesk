import 'dart:convert';
import 'dart:io';

import 'package:flutter_hbb/mobile/pages/herdr/herdr_relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Validates the Dart models against the relay's own contract fixtures
/// (herdr-mobile-relay `contracts/fixtures/outbound/*.json`, copied into
/// test/fixtures/herdr). If the relay changes a message shape, these tests
/// fail before the app does.
Map<String, dynamic> _loadFixture(String name) {
  final file = File('test/fixtures/herdr/$name');
  final decoded = jsonDecode(file.readAsStringSync());
  return Map<String, dynamic>.from(decoded as Map);
}

void main() {
  test('push_config: handshake fields and agent profiles', () {
    final config = HerdrPushConfig.fromJson(_loadFixture('push_config.json'));
    expect(config.protocol, kHerdrProtocolVersion);
    expect(config.host, 'dev-workstation');
    expect(config.version, '0.9.0');
    expect(config.capabilities, contains('structured_questions'));
    expect(config.agentProfiles, hasLength(2));
    expect(config.agentProfiles.first.id, 'claude');
    expect(config.agentProfiles.first.label, 'Claude');
  });

  test('agents: full snapshot parses with workspace/tab metadata', () {
    final message = _loadFixture('agents.json');
    final agents = (message['agents'] as List)
        .map((e) => HerdrAgent.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    expect(agents, hasLength(1));
    final agent = agents.single;
    expect(agent.paneId, 'pane-1');
    expect(agent.rawPaneId, 'pane-1');
    expect(agent.requestPaneId, 'pane-1');
    expect(agent.tabLabel, 'main');
    expect(agent.workspaceId, 'ws-1');
    expect(agent.agent, 'claude');
    expect(agent.name, 'fix-bug');
    expect(agent.displayName, 'fix-bug');
    expect(agent.status, 'working');
    expect(agent.isWorking, isTrue);
    expect(agent.isBlocked, isFalse);
    expect(agent.project, 'project');
    expect(agent.cwd, '/home/user/project');
  });

  test('agent_update: delta merges onto the snapshot without losing fields',
      () {
    final snapshotMessage = _loadFixture('agents.json');
    final snapshot = HerdrAgent.fromJson(Map<String, dynamic>.from(
        (snapshotMessage['agents'] as List).first as Map));
    final delta = HerdrAgent.fromJson(_loadFixture('agent_update.json'));
    final merged = snapshot.merge(delta);
    // The delta carries no `name`, so the snapshot value survives.
    expect(merged.name, 'fix-bug');
    expect(merged.status, 'working');
    expect(merged.workspaceId, 'ws-1');
    expect(merged.project, 'project');
  });

  test('merge: a status-carrying delta REPLACES the whole attention block', () {
    // A question followed by a plain approval. Merging the attention fields
    // one by one made `interaction` unclearable, so the phone kept rendering a
    // form bound to a dead question id and the answer was rejected by the host.
    final blocked = HerdrAgent.fromJson({
      'pane_id': 'w1:p1',
      'status': 'blocked',
      'event_id': 'ev-1',
      'attention_kind': 'question',
      'prompt': 'old prompt',
      'command': 'old command',
      'options': ['A', 'B'],
      'interaction': {
        'id': 'q-1',
        'kind': 'single_select',
        'question': 'Which one?',
        'options': [
          {'index': 0, 'label': 'A'},
        ],
      },
    });
    expect(blocked.interaction, isNotNull);

    final approval = HerdrAgent.fromJson({
      'pane_id': 'w1:p1',
      'status': 'blocked',
      'event_id': 'ev-2',
      'attention_kind': 'approval',
      'command': 'rm -rf build',
      'options': ['Yes', 'No'],
    });
    final merged = blocked.merge(approval);
    expect(merged.interaction, isNull, reason: 'the stale question must go');
    expect(merged.eventId, 'ev-2');
    expect(merged.attentionKind, 'approval');
    expect(merged.command, 'rm -rf build');
    expect(merged.prompt, isEmpty, reason: 'not carried over from the question');

    // A delta with no status at all is still a plain field-wise merge.
    final touch = HerdrAgent.fromJson({'pane_id': 'w1:p1', 'name': 'renamed'});
    final touched = blocked.merge(touch);
    expect(touched.interaction, isNotNull);
    expect(touched.name, 'renamed');
  });

  test('herdrTailLines: byte ceiling bounds a pane of very long lines', () {
    // The line trim alone does not bound cost: 240 lines of base64 is still
    // megabytes, and every consumer downstream pays per character.
    final huge = List.generate(300, (i) => 'x' * 4000).join('\n');
    expect(huge.length, greaterThan(kHerdrPaneMaxBytes));
    final trimmed = herdrTailLines(huge);
    expect(trimmed.length, lessThanOrEqualTo(kHerdrPaneMaxBytes));
    // And it keeps the TAIL, which is what the view shows.
    expect(huge.endsWith(trimmed), isTrue);
  });

  test('herdrTailLines: a normal pane is untouched by the byte ceiling', () {
    final normal = List.generate(50, (i) => 'line $i').join('\n');
    expect(herdrTailLines(normal), normal);
  });

  test('pane_unchanged: no content, flagged, carries the fingerprint', () {
    final frame = HerdrPaneContent.unchangedFrom({
      'type': 'pane_unchanged',
      'pane_id': 'w1:p1',
      'content_fingerprint': 'abc123',
    });
    expect(frame.unchanged, isTrue);
    expect(frame.paneId, 'w1:p1');
    expect(frame.fingerprint, 'abc123');
    expect(frame.content, isEmpty,
        reason: 'empty means "no news", not "the pane is empty"');
  });

  test('command_result: success and correlation fields', () {
    final result = HerdrCommandResult.fromJson(_loadFixture('command_result.json'));
    expect(result.requestId, 'req-001');
    expect(result.action, 'prompt');
    expect(result.ok, isTrue);
    expect(result.phase, 'completed');
    expect(result.paneId, 'pane-1');
  });

  test('question_advanced: structured question inside command_result data',
      () {
    final result =
        HerdrCommandResult.fromJson(_loadFixture('question_advanced.json'));
    expect(result.action, 'answer_question');
    expect(result.ok, isTrue);
    expect(result.phase, 'advanced');
    final interaction = HerdrQuestionInteraction.fromJson(result.data?['interaction']);
    expect(interaction, isNotNull);
    expect(interaction!.id, 'interaction-2');
    expect(interaction.kind, 'single_select');
    expect(interaction.isMultiSelect, isFalse);
    expect(interaction.question, 'Choose the second value');
    expect(interaction.options, hasLength(1));
    expect(interaction.options.single.label, 'Beta');
    expect(interaction.otherLabel, 'None of the above');
    expect(interaction.submitLabel, 'Submit');
    expect(interaction.canGoBack, isTrue);
    expect(interaction.questionIndex, 2);
    expect(interaction.questionTotal, 2);
  });

  test('question_navigated: previous question with selected option', () {
    final result =
        HerdrCommandResult.fromJson(_loadFixture('question_navigated.json'));
    expect(result.phase, 'navigated');
    final interaction = HerdrQuestionInteraction.fromJson(result.data?['interaction']);
    expect(interaction, isNotNull);
    expect(interaction!.options.single.selected, isTrue);
    expect(interaction.canGoBack, isFalse);
  });

  test('question_unconfirmed: failed navigation carries the error', () {
    final result =
        HerdrCommandResult.fromJson(_loadFixture('question_unconfirmed.json'));
    expect(result.ok, isFalse);
    expect(result.phase, 'unconfirmed');
    expect(result.error, isNotEmpty);
  });

  test('slash_commands: catalog inside command_result data', () {
    final result =
        HerdrCommandResult.fromJson(_loadFixture('slash_commands.json'));
    expect(result.action, 'list_slash_commands');
    expect(result.ok, isTrue);
    final commands = result.data?['commands'] as List;
    expect(commands, isNotEmpty);
    expect((commands.first as Map)['command'], '/add-dir');
  });

  test('activity_history: entries parse with kind/status', () {
    final message = _loadFixture('activity_history.json');
    final activities = (message['activities'] as List)
        .map((e) => HerdrActivity.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    expect(activities, hasLength(3));
    expect(activities[0].kind, 'prompt');
    expect(activities[0].paneId, 'pane-1');
    expect(activities[1].kind, 'blocked');
    expect(activities[1].status, 'attention');
    expect(activities[2].kind, 'finished');
  });

  test('list_directories: listing parses from command_result data', () {
    // Shape produced by fsutil.ListDirectories in the relay (no fixture is
    // shipped for it, so the JSON mirrors internal/fsutil/listdir.go).
    final listing = HerdrDirListing.fromJson(const {
      'current': {'path': '/home/user/project', 'label': '~/project'},
      'parent': '/home/user',
      'directories': [
        {'name': 'src', 'path': '/home/user/project/src'},
        {'name': 'docs', 'path': '/home/user/project/docs'},
      ],
    });
    expect(listing.currentPath, '/home/user/project');
    expect(listing.currentLabel, '~/project');
    expect(listing.parent, '/home/user');
    expect(listing.directories, hasLength(2));
    expect(listing.directories.first.name, 'src');
    expect(listing.directories.first.path, '/home/user/project/src');
  });

  test('list_directories: home listing has no parent and empty dirs', () {
    final listing = HerdrDirListing.fromJson(const {
      'current': {'path': '/home/user', 'label': '~'},
    });
    expect(listing.currentLabel, '~');
    expect(listing.parent, isEmpty);
    expect(listing.directories, isEmpty);
  });

  test('agent name validation mirrors the relay pattern', () {
    expect(herdrAgentNameError(''), isNull);
    expect(herdrAgentNameError('test-rename'), isNull);
    expect(herdrAgentNameError('a1_b-2'), isNull);
    expect(herdrAgentNameError('TestRename'), isNotNull);
    expect(herdrAgentNameError('1abc'), isNotNull);
    expect(herdrAgentNameError('has space'), isNotNull);
    expect(herdrAgentNameError('a' * 33), isNotNull);
  });

  test('blocked-shaped agent payload carries the attention fields', () {
    // The `blocked` message shares the agent schema plus attention fields
    // (see broadcastBlockedAttention in the relay); emulate it on top of the
    // agents fixture since the relay repo ships no blocked.json fixture.
    final snapshotMessage = _loadFixture('agents.json');
    final json = Map<String, dynamic>.from(
        (snapshotMessage['agents'] as List).first as Map);
    json.addAll({
      'type': 'blocked',
      'status': 'blocked',
      'event_id': 'evt-1',
      'attention_kind': 'approval',
      'command': 'git push',
      'options': ['Yes', 'No'],
    });
    final agent = HerdrAgent.fromJson(json);
    expect(agent.isBlocked, isTrue);
    expect(agent.eventId, 'evt-1');
    expect(agent.attentionKind, 'approval');
    expect(agent.command, 'git push');
    expect(agent.options, ['Yes', 'No']);
  });
}
