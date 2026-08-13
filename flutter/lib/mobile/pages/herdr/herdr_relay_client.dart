import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// WebSocket client for the `herdr-mobile-relay` protocol (v2).
///
/// The relay is reached through the RustDesk TCP tunnel opened by
/// HerdrConnectionManager, so it always listens on loopback without a token.
///
/// Message reference: herdr-mobile-relay `internal/protocol/protocol.go` and
/// `contracts/fixtures/{inbound,outbound}/*.json`. Mutating messages MUST
/// carry `"protocol": 2` or the relay rejects them with a command_result
/// error (see `protocol.RequiresProtocol`).

/// Required protocol version for mutating messages (protocol.Version).
const int kHerdrProtocolVersion = 2;

/// Agent names accepted by the relay (agentNamePattern in
/// internal/coordinator/lifecycle.go): lowercase, starts with a letter.
final RegExp _agentNamePattern = RegExp(r'^[a-z][a-z0-9_-]{0,31}$');

/// Validate an agent name the way the relay does; returns an error message
/// or null when valid. Empty names are valid (optional field).
String? herdrAgentNameError(String name) {
  if (name.isEmpty) return null;
  if (!_agentNamePattern.hasMatch(name)) {
    return 'Minúsculas, números, "-" y "_"; empieza por letra (máx. 32)';
  }
  return null;
}

/// Connection lifecycle of [HerdrRelayClient].
enum HerdrConnectionState { connecting, connected, reconnecting, closed }

/// Agent profile advertised by `push_config` (e.g. `{"id":"claude","label":"Claude"}`).
class HerdrAgentProfile {
  final String id;
  final String label;

  const HerdrAgentProfile({required this.id, this.label = ''});

  factory HerdrAgentProfile.fromJson(Map<String, dynamic> json) =>
      HerdrAgentProfile(
        id: json['id'] as String? ?? '',
        label: json['label'] as String? ?? '',
      );
}

/// Snapshot of the `push_config` handshake message. Only the fields the
/// native UI needs are modeled; the rest is ignored on purpose.
class HerdrPushConfig {
  final String host;
  final int protocol;
  final String version;
  final List<String> capabilities;
  final List<HerdrAgentProfile> agentProfiles;

  const HerdrPushConfig({
    this.host = '',
    this.protocol = 0,
    this.version = '',
    this.capabilities = const [],
    this.agentProfiles = const [],
  });

  factory HerdrPushConfig.fromJson(Map<String, dynamic> json) {
    final profiles = <HerdrAgentProfile>[];
    final raw = json['agent_profiles'];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          profiles.add(
              HerdrAgentProfile.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return HerdrPushConfig(
      host: json['host'] as String? ?? '',
      protocol: json['protocol'] as int? ?? 0,
      version: json['version'] as String? ?? '',
      capabilities: (json['capabilities'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      agentProfiles: profiles,
    );
  }
}

/// `inventory_status`: whether the relay can see herdr at all.
///
/// The relay sends it right BEFORE the `agents` list on every refresh
/// (server.go `refresh_agents`, and inventoryStatusMessage on every poll
/// change). When [state] is not `ready` the agent list that follows is empty
/// because the relay could not enumerate herdr — not because nothing is
/// running, which is the difference between "herdr is down" and the cheerful
/// "no agents" empty state.
class HerdrInventoryStatus {
  final String state;
  final String errorCode;
  final String message;
  final bool stale;

  const HerdrInventoryStatus({
    this.state = '',
    this.errorCode = '',
    this.message = '',
    this.stale = false,
  });

  /// Unknown (no frame yet) counts as ready: the relay only started sending
  /// this in 0.12, and an older one must not paint a permanent error.
  bool get isReady => state.isEmpty || state == 'ready';

  /// What to show the user, best effort.
  String get displayMessage {
    if (message.isNotEmpty) return message;
    if (errorCode.isNotEmpty) return errorCode;
    return 'El relay no pudo consultar herdr (estado "$state")';
  }

  factory HerdrInventoryStatus.fromJson(Map<String, dynamic> json) =>
      HerdrInventoryStatus(
        state: json['state'] as String? ?? '',
        errorCode: json['error_code'] as String? ?? '',
        message: json['message'] as String? ?? '',
        stale: json['stale'] as bool? ?? false,
      );
}

/// One option of a structured question (`single_select` / `multi_select`).
class HerdrQuestionOption {
  final int index;
  final String label;
  final String description;
  final bool selected;

  const HerdrQuestionOption({
    required this.index,
    this.label = '',
    this.description = '',
    this.selected = false,
  });

  factory HerdrQuestionOption.fromJson(Map<String, dynamic> json) =>
      HerdrQuestionOption(
        index: json['index'] as int? ?? 0,
        label: json['label'] as String? ?? '',
        description: json['description'] as String? ?? '',
        selected: json['selected'] as bool? ?? false,
      );
}

/// Structured question attached to a blocked agent (`interaction` field of the
/// `blocked` message or of a question command_result).
class HerdrQuestionInteraction {
  final String id;
  final String kind; // 'single_select' | 'multi_select'
  final String question;
  final List<HerdrQuestionOption> options;
  final String otherLabel;
  final bool otherSelected;

  /// Text the host already has for the "other" answer (`other.text`), used to
  /// seed the field so re-opening a question does not lose what was typed.
  final String otherText;

  /// Hint for the "other" field (`other.placeholder`).
  final String otherPlaceholder;

  /// The host says the "other" row must not be offered at all
  /// (`other.hidden`). Several classifiers emit `Other{Hidden: true}`.
  final bool otherHidden;

  /// The host accepts an empty "other" answer (`other.allow_empty`).
  final bool otherAllowEmpty;

  /// The question also accepts a free-form chat reply (`can_chat`). Parsed so
  /// callers can tell; the clarify-question chat UI is deliberately not built.
  final bool canChat;

  final String submitLabel;
  final bool canGoBack;
  final int questionIndex;
  final int questionTotal;

  const HerdrQuestionInteraction({
    required this.id,
    this.kind = 'single_select',
    this.question = '',
    this.options = const [],
    this.otherLabel = '',
    this.otherSelected = false,
    this.otherText = '',
    this.otherPlaceholder = '',
    this.otherHidden = false,
    this.otherAllowEmpty = false,
    this.canChat = false,
    this.submitLabel = 'Submit',
    this.canGoBack = false,
    this.questionIndex = 0,
    this.questionTotal = 0,
  });

  bool get isMultiSelect => kind == 'multi_select';

  /// Whether the "other" row is worth rendering.
  ///
  /// It used to be gated on a non-empty label alone, so a question whose
  /// `other` block carries only a placeholder (the relay emits exactly that —
  /// see internal/question/parser.go) rendered NO row at all: with no option
  /// matching what the user wanted, the question became unanswerable from the
  /// phone.
  bool get hasOther =>
      !otherHidden && (otherLabel.isNotEmpty || otherPlaceholder.isNotEmpty);

  static HerdrQuestionInteraction? fromJson(dynamic json) {
    if (json is! Map) return null;
    final map = Map<String, dynamic>.from(json);
    final id = map['id'] as String? ?? '';
    if (id.isEmpty) return null;
    final options = <HerdrQuestionOption>[];
    if (map['options'] is List) {
      for (final item in map['options'] as List) {
        if (item is Map) {
          options.add(
              HerdrQuestionOption.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    final other = map['other'];
    String otherLabel = '';
    bool otherSelected = false;
    String otherText = '';
    String otherPlaceholder = '';
    bool otherHidden = false;
    bool otherAllowEmpty = false;
    if (other is Map) {
      otherLabel = other['label'] as String? ?? '';
      otherSelected = other['selected'] as bool? ?? false;
      otherText = other['text'] as String? ?? '';
      otherPlaceholder = other['placeholder'] as String? ?? '';
      otherHidden = other['hidden'] as bool? ?? false;
      otherAllowEmpty = other['allow_empty'] as bool? ?? false;
    }
    return HerdrQuestionInteraction(
      id: id,
      kind: map['kind'] as String? ?? 'single_select',
      question: map['question'] as String? ?? '',
      options: options,
      otherLabel: otherLabel,
      otherSelected: otherSelected,
      otherText: otherText,
      otherPlaceholder: otherPlaceholder,
      otherHidden: otherHidden,
      otherAllowEmpty: otherAllowEmpty,
      canChat: map['can_chat'] as bool? ?? false,
      submitLabel: map['submit_label'] as String? ?? 'Submit',
      canGoBack: map['can_go_back'] as bool? ?? false,
      questionIndex: map['question_index'] as int? ?? 0,
      questionTotal: map['question_total'] as int? ?? 0,
    );
  }
}

/// An agent as reported by the `agents` snapshot, `agent_update` deltas and
/// `blocked` events. Field names mirror the relay JSON.
class HerdrAgent {
  final String paneId;
  final String rawPaneId;
  final String terminalId;
  final String tabId;
  final String tabLabel;
  final int tabNumber;
  final String workspaceId;
  final String agent;
  final String name;
  final String status;
  final String cwd;
  final String project;
  final String host;
  final String session;

  /// Last activity timestamp (ms since epoch, from `updated_at`); 0 when
  /// the relay has not reported any.
  final int updatedAt;

  /// Attention payload, only set while [status] == 'blocked'.
  final String eventId;
  final String attentionKind; // 'approval' | 'question' | 'chat' | 'unknown'
  final String prompt;
  final String command;
  final List<String> options;
  final HerdrQuestionInteraction? interaction;

  /// `pane_revision`: the relay's own state revision for this pane. Deltas
  /// carry it on every agent frame and the relay drops any whose revision is
  /// behind its committed one (server.go deltaRevision / StateRevision); we do
  /// the same, or a queued delta can regress state the relay already left.
  final int revision;

  /// Keys that were actually present in the JSON this was parsed from.
  ///
  /// A delta OMITS what did not change, so "absent" and "present but empty"
  /// mean opposite things and only the raw map can tell them apart. See
  /// [merge].
  final Set<String> presentKeys;

  const HerdrAgent({
    required this.paneId,
    this.rawPaneId = '',
    this.terminalId = '',
    this.tabId = '',
    this.tabLabel = '',
    this.tabNumber = 0,
    this.workspaceId = '',
    this.agent = '',
    this.name = '',
    this.status = '',
    this.cwd = '',
    this.project = '',
    this.host = '',
    this.session = '',
    this.updatedAt = 0,
    this.eventId = '',
    this.attentionKind = '',
    this.prompt = '',
    this.command = '',
    this.options = const [],
    this.interaction,
    this.revision = 0,
    this.presentKeys = const {},
  });

  /// Pane identifier to use in requests (matches what the relay expects).
  String get requestPaneId => rawPaneId.isNotEmpty ? rawPaneId : paneId;

  /// Same agent with a different question attached — used to apply the next
  /// interaction the relay returns from `answer_question`/`navigate_question`
  /// without waiting for a `blocked` push.
  HerdrAgent withInteraction(HerdrQuestionInteraction? next) => HerdrAgent(
        paneId: paneId,
        rawPaneId: rawPaneId,
        terminalId: terminalId,
        tabId: tabId,
        tabLabel: tabLabel,
        tabNumber: tabNumber,
        workspaceId: workspaceId,
        agent: agent,
        name: name,
        status: status,
        cwd: cwd,
        project: project,
        host: host,
        session: session,
        updatedAt: updatedAt,
        eventId: eventId,
        attentionKind: attentionKind,
        prompt: prompt,
        command: command,
        options: options,
        interaction: next,
        revision: revision,
      );

  /// Same agent with the attention block the relay re-classified for us on a
  /// `pane_content` frame (see server.go preparePaneResponse). Used to recover
  /// an attention block a delta dropped, without waiting for the next snapshot.
  HerdrAgent withAttention({
    required String attentionKind,
    required String prompt,
    required String command,
    required List<String> options,
    required HerdrQuestionInteraction? interaction,
  }) =>
      HerdrAgent(
        paneId: paneId,
        rawPaneId: rawPaneId,
        terminalId: terminalId,
        tabId: tabId,
        tabLabel: tabLabel,
        tabNumber: tabNumber,
        workspaceId: workspaceId,
        agent: agent,
        name: name,
        status: status,
        cwd: cwd,
        project: project,
        host: host,
        session: session,
        updatedAt: updatedAt,
        eventId: eventId,
        attentionKind: attentionKind,
        prompt: prompt,
        command: command,
        options: options,
        interaction: interaction,
        revision: revision,
      );

  bool get isBlocked => status == 'blocked';
  bool get isWorking => status == 'working';

  /// Display name: agent name, falling back to the tab label or pane id.
  String get displayName =>
      name.isNotEmpty ? name : (tabLabel.isNotEmpty ? tabLabel : paneId);

  factory HerdrAgent.fromJson(Map<String, dynamic> json) => HerdrAgent(
        paneId: json['pane_id'] as String? ?? '',
        rawPaneId: json['raw_pane_id'] as String? ?? '',
        terminalId: json['terminal_id'] as String? ?? '',
        tabId: json['tab_id'] as String? ?? '',
        tabLabel: json['tab_label'] as String? ?? '',
        tabNumber: json['tab_number'] as int? ?? 0,
        workspaceId: json['workspace_id'] as String? ?? '',
        agent: json['agent'] as String? ?? '',
        name: json['name'] as String? ?? '',
        status: json['status'] as String? ?? '',
        cwd: json['cwd'] as String? ?? '',
        project: json['project'] as String? ?? '',
        host: json['host'] as String? ?? '',
        session: json['session'] as String? ?? '',
        updatedAt: json['updated_at'] as int? ?? 0,
        eventId: json['event_id'] as String? ?? '',
        attentionKind: json['attention_kind'] as String? ?? '',
        prompt: json['prompt'] as String? ?? '',
        command: json['command'] as String? ?? '',
        options:
            (json['options'] as List?)?.map((e) => e.toString()).toList() ??
                const [],
        interaction: HerdrQuestionInteraction.fromJson(json['interaction']),
        revision: (json['pane_revision'] as num?)?.toInt() ?? 0,
        // Recorded so [merge] can tell "field omitted" from "field cleared".
        presentKeys: json.keys.toSet(),
      );

  /// Apply an `agent_update`/`blocked` delta on top of this snapshot entry.
  ///
  /// Every field is decided on KEY PRESENCE in the delta's raw JSON, exactly
  /// like the relay's own `applyAgentDelta` (internal/app/server.go): a delta
  /// omits what did not change, so an absent key keeps the previous value and
  /// a key that IS there is authoritative even when its value is empty or null.
  ///
  /// Neither of the two rules this replaces worked:
  ///
  /// * Per-field on EMPTINESS made the attention block unclearable — an agent
  ///   that went from a structured question to a plain approval kept the old
  ///   `interaction`, so the phone rendered a form bound to a dead question id.
  /// * Taking the block WHOLE from any delta carrying a status wiped it
  ///   instead: the relay routinely sends an `agent_update` with a status but
  ///   no attention payload (the UDP-driven one, and the implicit acknowledge
  ///   of every `read_pane`), so a blocked agent's buttons vanished ~1.5s after
  ///   appearing and answering sent `event_id: ""`, which the host rejects.
  ///
  /// Presence expresses both: the `blocked` frame carries `interaction: null`
  /// explicitly (cleared), the status-only updates carry no attention key at
  /// all (kept).
  ///
  /// Presence alone is not the whole rule, though. The relay also enforces a
  /// COHERENCE pass keyed on `attention_kind` (the `else` arm of the same
  /// function): while blocked, options belong to an approval and interaction
  /// belongs to a question, so whichever does not match the current kind is
  /// dropped. Without it, a question followed by an approval — both `blocked`,
  /// and the approval delta carries no `interaction` key to clear — left the
  /// phone rendering a form bound to a dead question id, which is the exact
  /// failure the presence rule above was introduced to kill. Presence fixed it
  /// only across a status CHANGE; blocked→blocked slipped through.
  HerdrAgent merge(HerdrAgent delta) {
    bool has(String key) => delta.presentKeys.contains(key);
    final mergedStatus = has('status') ? delta.status : status;
    // Only a blocked agent has an attention block; the relay drops it on any
    // other status (applyAgentDelta), so mirror that or a stale banner
    // survives the agent going back to work.
    final blocked = mergedStatus == 'blocked';
    final mergedKind =
        has('attention_kind') ? delta.attentionKind : attentionKind;
    // The relay's coherence pass, mirrored: options are an approval's, the
    // interaction is a question's.
    final keepOptions = blocked && mergedKind == 'approval';
    final keepInteraction = blocked && mergedKind == 'question';
    return HerdrAgent(
      paneId: paneId,
      rawPaneId: has('raw_pane_id') ? delta.rawPaneId : rawPaneId,
      terminalId: has('terminal_id') ? delta.terminalId : terminalId,
      tabId: has('tab_id') ? delta.tabId : tabId,
      tabLabel: has('tab_label') ? delta.tabLabel : tabLabel,
      tabNumber: has('tab_number') ? delta.tabNumber : tabNumber,
      workspaceId: has('workspace_id') ? delta.workspaceId : workspaceId,
      agent: has('agent') ? delta.agent : agent,
      name: has('name') ? delta.name : name,
      status: mergedStatus,
      cwd: has('cwd') ? delta.cwd : cwd,
      project: has('project') ? delta.project : project,
      host: has('host') ? delta.host : host,
      session: has('session') ? delta.session : session,
      updatedAt: has('updated_at') ? delta.updatedAt : updatedAt,
      eventId: has('event_id') ? delta.eventId : eventId,
      attentionKind: !blocked ? '' : mergedKind,
      prompt: !blocked ? '' : (has('prompt') ? delta.prompt : prompt),
      command: !blocked ? '' : (has('command') ? delta.command : command),
      options: !keepOptions
          ? const []
          : (has('options') ? delta.options : options),
      interaction: !keepInteraction
          ? null
          : (has('interaction') ? delta.interaction : interaction),
      revision: has('pane_revision') ? delta.revision : revision,
    );
  }
}

/// One slash command of an agent (`list_slash_commands` catalog).
class HerdrSlashCommand {
  final String command;
  final String description;
  final String source;
  final String argumentHint;

  const HerdrSlashCommand({
    required this.command,
    this.description = '',
    this.source = '',
    this.argumentHint = '',
  });

  factory HerdrSlashCommand.fromJson(Map<String, dynamic> json) =>
      HerdrSlashCommand(
        command: json['command'] as String? ?? '',
        description: json['description'] as String? ?? '',
        source: json['source'] as String? ?? '',
        argumentHint: json['argument_hint'] as String? ?? '',
      );
}

/// One subdirectory of a `list_directories` result.
class HerdrDirEntry {
  final String name;
  final String path;

  const HerdrDirEntry({required this.name, required this.path});

  factory HerdrDirEntry.fromJson(Map<String, dynamic> json) => HerdrDirEntry(
        name: json['name'] as String? ?? '',
        path: json['path'] as String? ?? '',
      );
}

/// Directory listing for the cwd picker (command_result `data` of
/// `list_directories`). Listings are confined to the host home directory;
/// [parent] is empty when already at home.
class HerdrDirListing {
  final String currentPath;
  final String currentLabel;
  final String parent;
  final List<HerdrDirEntry> directories;

  const HerdrDirListing({
    this.currentPath = '',
    this.currentLabel = '',
    this.parent = '',
    this.directories = const [],
  });

  factory HerdrDirListing.fromJson(Map<String, dynamic> json) {
    final current = json['current'];
    final dirs = <HerdrDirEntry>[];
    if (json['directories'] is List) {
      for (final item in json['directories'] as List) {
        if (item is Map) {
          dirs.add(HerdrDirEntry.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return HerdrDirListing(
      currentPath: current is Map ? current['path'] as String? ?? '' : '',
      currentLabel: current is Map ? current['label'] as String? ?? '' : '',
      parent: json['parent'] as String? ?? '',
      directories: dirs,
    );
  }
}

/// Result of a request correlated by `request_id`.
class HerdrCommandResult {
  final String requestId;
  final String action;
  final bool ok;
  final String phase;
  final String error;
  final String paneId;

  /// Raw `data` payload (e.g. the next question interaction).
  final Map<String, dynamic>? data;

  const HerdrCommandResult({
    this.requestId = '',
    this.action = '',
    this.ok = false,
    this.phase = '',
    this.error = '',
    this.paneId = '',
    this.data,
  });

  /// Whether this answer should resolve the request instead of failing it.
  ///
  /// `answer_question` and `navigate_question` report progress through a
  /// sequence with `phase` rather than `ok`, so those two phases count. They
  /// used to count UNCONDITIONALLY, which also swallowed their FAILURES: a
  /// rejected answer arrived as `ok:false, phase:"advanced", error:"…"` and was
  /// completed as a success, so the form moved on and the error was never
  /// shown. Require the error to be empty.
  bool get isSuccess =>
      ok || ((phase == 'advanced' || phase == 'navigated') && error.isEmpty);

  factory HerdrCommandResult.fromJson(Map<String, dynamic> json) =>
      HerdrCommandResult(
        requestId: json['request_id'] as String? ?? '',
        action: json['action'] as String? ?? '',
        ok: json['ok'] as bool? ?? false,
        phase: json['phase'] as String? ?? '',
        error: json['error'] as String? ?? '',
        paneId: json['pane_id'] as String? ?? '',
        data: json['data'] is Map
            ? Map<String, dynamic>.from(json['data'] as Map)
            : null,
      );
}

/// Response to `read_pane`: either a `pane_content` frame, or the cheap
/// `pane_unchanged` answer the relay sends when the fingerprint we quoted is
/// still current ([unchanged] true, no content).
class HerdrPaneContent {
  final String paneId;
  final String content;
  final String format;

  /// Server-side hash of the pane. Quoted back on the next `read_pane` so an
  /// unchanged pane costs a few bytes instead of the whole scrollback.
  final String fingerprint;

  /// True for a `pane_unchanged` answer: [content] is empty and means
  /// "no news", NOT "the pane is empty".
  final bool unchanged;

  /// Set when the relay could not read the pane. It answers with a
  /// `pane_content` frame whose content is EMPTY plus this field
  /// (internal/coordinator/dispatch.go HandleReadPane): "Unable to read the
  /// agent pane", or — routinely, because a read races the poller — "The agent
  /// state changed while the pane was being read".
  ///
  /// Indistinguishable from a genuinely empty pane without it, which is how a
  /// mid-session console used to blank itself back to "Cargando…".
  final String error;

  const HerdrPaneContent({
    required this.paneId,
    this.content = '',
    this.format = 'plain',
    this.fingerprint = '',
    this.unchanged = false,
    this.error = '',
  });

  bool get hasError => error.isNotEmpty;

  /// [trim] is false for frames that came back from the decode isolate: it
  /// already ran [herdrTailLines] on the content there, and running it again
  /// on the trimmed string is a second full scan for nothing.
  factory HerdrPaneContent.fromJson(Map<String, dynamic> json,
      {bool trim = true}) {
    final raw = json['content'] as String? ?? '';
    return HerdrPaneContent(
      paneId: json['pane_id'] as String? ?? '',
      content: trim ? herdrTailLines(raw) : raw,
      format: json['format'] as String? ?? 'plain',
      fingerprint: json['content_fingerprint'] as String? ?? '',
      error: json['error'] as String? ?? '',
    );
  }

  factory HerdrPaneContent.unchangedFrom(Map<String, dynamic> json) =>
      HerdrPaneContent(
        paneId: json['pane_id'] as String? ?? '',
        fingerprint: json['content_fingerprint'] as String? ?? '',
        unchanged: true,
      );
}

/// Lines asked for, and kept, from a `read_pane` answer.
///
/// This is the scrollback you can reach on the phone. Relay 0.12.0 honours
/// `lines` (see [herdrTailLines]), so it is now also exactly what a changed
/// poll costs: ~155 bytes per line, measured, i.e. ~93 KB here — against the
/// 728 KB the whole scrollback used to cost for the same 240 usable rows.
/// That is what pays for a history worth scrolling.
const int kHerdrPaneTailLines = 600;

/// Keep only the tail of a pane snapshot.
///
/// **Relay 0.10.6 ignored the `lines` (and `limit`) parameter of `read_pane`
/// and always answered with the ENTIRE scrollback** — asking for 60 lines
/// returned 728 KB across 4641 lines, identical with `limit`, identical with
/// no parameter at all. That whole payload reached the view on EVERY poll,
/// every 1.5s while an agent works, which is why this trim exists.
///
/// **Relay 0.12.0 honours it.** Measured against the live relay: `lines: 60`
/// returns 60 lines / 5.7 KB, `lines: 2000` returns 1645 lines / 254 KB. The
/// client had been asking for 60 *because* the parameter was inert, so the
/// upgrade silently cut the visible scrollback to 60 raw rows — a handful of
/// messages once the chrome filter has run. [kHerdrPaneTailLines] is what we
/// ask for now, and this stays as the safety net: it bounds the answer from an
/// older relay, and the byte ceiling bounds a pane that printed a blob.
///
/// Only the tail is ever visible (the view pins to the bottom edge of the
/// pane), so trimming here costs nothing and keeps the cost bounded for every
/// consumer downstream.
/// Decode a relay frame off the UI isolate, trimming the pane snapshot there.
///
/// Top-level so it can run in the worker isolate. Trimming inside the isolate
/// is the point: the frame is up to 876 KB and only the ~38 KB tail is ever
/// rendered, so that is all that crosses back.
Map<String, dynamic> _herdrDecodeFrame(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map) return const {};
  final message = Map<String, dynamic>.from(decoded);
  final content = message['content'];
  if (content is String) message['content'] = herdrTailLines(content);
  return message;
}

/// Entry point of the decode worker: answers `[id, decodedMap]` for every
/// `[id, rawFrame]` it is sent, and shuts down on `null`.
void _herdrDecodeWorkerMain(SendPort reply) {
  final inbox = ReceivePort();
  reply.send(inbox.sendPort);
  inbox.listen((request) {
    if (request == null) {
      inbox.close();
      return;
    }
    if (request is! List || request.length != 2) return;
    final id = request[0];
    Map<String, dynamic> decoded;
    try {
      decoded = _herdrDecodeFrame(request[1] as String);
    } catch (_) {
      // The caller cannot tell a bad frame from an empty one, and neither
      // matters: both are dropped.
      decoded = const {};
    }
    reply.send([id, decoded]);
  });
}

/// ONE long-lived isolate that decodes every large frame.
///
/// This used to be `compute()`, which spawns a fresh isolate per call, waits
/// for it to boot and tears it down again. That is a fine trade for a rare
/// heavy computation and a bad one here: the threshold is crossed by routine
/// pane snapshots at a 1.5s cadence while an agent works, so the spawn was
/// costing more than the 25ms decode it was meant to move off the UI thread.
/// One worker, spawned on the first big frame and reused for the session.
class _HerdrDecodeWorker {
  Isolate? _isolate;
  SendPort? _outbox;
  ReceivePort? _inbox;
  Future<void>? _spawning;
  bool _closed = false;

  /// Set when spawning failed: the client then decodes inline forever rather
  /// than retrying an isolate the platform will not give it.
  bool _unavailable = false;

  int _seq = 0;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};

  Future<Map<String, dynamic>> decode(String raw) async {
    if (!_closed && !_unavailable) {
      await (_spawning ??= _spawn());
    }
    final outbox = _outbox;
    if (_closed || outbox == null) {
      // No worker (closed, or the platform refused one): decoding inline is
      // slower for the UI but always correct.
      return _herdrDecodeFrame(raw);
    }
    final id = ++_seq;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    outbox.send([id, raw]);
    return completer.future;
  }

  Future<void> _spawn() async {
    final inbox = ReceivePort();
    final handshake = Completer<SendPort>();
    inbox.listen((message) {
      if (message is SendPort) {
        if (!handshake.isCompleted) handshake.complete(message);
        return;
      }
      if (message is! List || message.length != 2) return;
      final completer = _pending.remove(message[0]);
      if (completer == null || completer.isCompleted) return;
      final payload = message[1];
      completer.complete(payload is Map
          ? Map<String, dynamic>.from(payload)
          : const <String, dynamic>{});
    });
    try {
      _isolate = await Isolate.spawn(_herdrDecodeWorkerMain, inbox.sendPort);
    } catch (e) {
      debugPrint('[HerdrRelayClient] decode isolate unavailable: $e');
      inbox.close();
      _unavailable = true;
      return;
    }
    _inbox = inbox;
    _outbox = await handshake.future;
    if (_closed) close();
  }

  void close() {
    _closed = true;
    _outbox?.send(null);
    _outbox = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _inbox?.close();
    _inbox = null;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.complete(const <String, dynamic>{});
    }
    _pending.clear();
  }
}

/// Hard ceiling on a trimmed snapshot, in code units.
///
/// The line trim alone does not bound cost: 240 lines of a pane that printed a
/// minified bundle or a base64 blob is still megabytes, and every consumer
/// downstream (the ANSI parse, the TextSpan tree, SelectableText's paragraph
/// layout) pays per character. 240 rows of a 181-column pane is ~43 KB, so
/// this is several times the worst legitimate case.
const int kHerdrPaneMaxBytes = 192 * 1024;

String herdrTailLines(String content,
    {int keep = kHerdrPaneTailLines, int maxBytes = kHerdrPaneMaxBytes}) {
  if (content.isEmpty) return content;
  var out = content;
  var cut = content.length;
  var seen = 0;
  while (cut > 0) {
    final next = content.lastIndexOf('\n', cut - 1);
    if (next < 0) break;
    seen++;
    if (seen > keep) {
      out = content.substring(next + 1);
      break;
    }
    cut = next;
  }
  if (out.length <= maxBytes) return out;
  // Keep the tail: the view pins to the bottom edge, so that is what is shown.
  // Cut on a line boundary when there is one nearby, to avoid slicing an
  // escape sequence in half.
  final hardCut = out.length - maxBytes;
  final boundary = out.indexOf('\n', hardCut);
  return boundary < 0 ? out.substring(hardCut) : out.substring(boundary + 1);
}

/// One entry of `activity_history` / `activity` messages (only the fields the
/// UI lists).
class HerdrActivity {
  final String id;
  final int timestamp;
  final String kind;
  final String status;
  final String summary;
  final String paneId;
  final String agent;
  final String project;

  const HerdrActivity({
    this.id = '',
    this.timestamp = 0,
    this.kind = '',
    this.status = '',
    this.summary = '',
    this.paneId = '',
    this.agent = '',
    this.project = '',
  });

  factory HerdrActivity.fromJson(Map<String, dynamic> json) => HerdrActivity(
        id: json['id'] as String? ?? '',
        timestamp: json['timestamp'] as int? ?? 0,
        kind: json['kind'] as String? ?? '',
        status: json['status'] as String? ?? '',
        summary: json['summary'] as String? ?? '',
        paneId: json['pane_id'] as String? ?? '',
        agent: json['agent'] as String? ?? '',
        project: json['project'] as String? ?? '',
      );
}

/// Exception raised when a command fails or the connection drops mid-request.
class HerdrRelayException implements Exception {
  final String message;
  const HerdrRelayException(this.message);

  @override
  String toString() => message;
}

/// Stateful WebSocket client for one relay endpoint.
///
/// Usage: create with the local tunnel port, [connect], then listen to
/// [agents], [blocked], [paneContent] and [connectionState]. If the socket
/// drops (e.g. the RustDesk connection dies, killing the tunnel) the client
/// reconnects with exponential backoff until [close] is called.
class HerdrRelayClient {
  HerdrRelayClient({required this.port, this.host = '127.0.0.1'});

  final int port;
  final String host;

  static const Duration _commandTimeout = Duration(seconds: 15);
  static const Duration _initialBackoff = Duration(seconds: 1);
  static const Duration _maxBackoff = Duration(seconds: 15);

  WebSocketChannel? _channel;
  StreamSubscription? _socketSub;
  bool _closed = false;
  int _requestSeq = 0;
  Duration _backoff = _initialBackoff;

  final Map<String, HerdrAgent> _agentsByPane = {};
  final Map<String, Completer<HerdrCommandResult>> _pending = {};

  final _agentsController =
      StreamController<List<HerdrAgent>>.broadcast();
  final _blockedController = StreamController<HerdrAgent>.broadcast();
  final _paneContentController = StreamController<HerdrPaneContent>.broadcast();
  final _activityController = StreamController<HerdrActivity>.broadcast();
  final _configController = StreamController<HerdrPushConfig>.broadcast();
  final _stateController =
      StreamController<HerdrConnectionState>.broadcast();
  final _inventoryController =
      StreamController<HerdrInventoryStatus>.broadcast();
  final _commandErrorController =
      StreamController<HerdrCommandResult>.broadcast();

  /// Full agent snapshot, re-emitted on every `agents`/`agent_update`/
  /// `blocked` message.
  Stream<List<HerdrAgent>> get agents => _agentsController.stream;

  /// Emits the agent (with attention payload) when it becomes blocked.
  Stream<HerdrAgent> get blocked => _blockedController.stream;

  Stream<HerdrPaneContent> get paneContent => _paneContentController.stream;
  Stream<HerdrActivity> get activity => _activityController.stream;
  Stream<HerdrPushConfig> get pushConfig => _configController.stream;
  Stream<HerdrConnectionState> get connectionState => _stateController.stream;

  /// Whether the relay can enumerate herdr (`inventory_status`).
  Stream<HerdrInventoryStatus> get inventoryStatus =>
      _inventoryController.stream;

  /// Failures of fire-and-forget requests, which carry a `request_id` but have
  /// no completer waiting on them (today: `read_pane`). Without this the
  /// relay's answer is dropped on the floor.
  Stream<HerdrCommandResult> get commandErrors =>
      _commandErrorController.stream;

  HerdrConnectionState _state = HerdrConnectionState.connecting;
  HerdrConnectionState get state => _state;

  /// True once [close] ran. A closed client never reconnects, so the owner
  /// (HerdrConnectionManager) must build a new one instead of reusing it.
  bool get isClosed => _closed;

  /// Last received handshake; null until the first `push_config` arrives.
  HerdrPushConfig? config;

  /// Last `inventory_status`; unknown (and therefore "ready") until one lands.
  HerdrInventoryStatus inventory = const HerdrInventoryStatus();

  /// Current agent snapshot (unmodifiable view).
  List<HerdrAgent> get currentAgents =>
      List.unmodifiable(_agentsByPane.values);

  Uri get _uri => Uri.parse('ws://$host:$port/ws');

  /// Connect (or reconnect) to the relay. Returns once the socket is open;
  /// the handshake messages arrive asynchronously on the streams.
  Future<void> connect() async {
    if (_closed) return;
    _setState(_state == HerdrConnectionState.connecting
        ? HerdrConnectionState.connecting
        : HerdrConnectionState.reconnecting);
    // Bypass any system proxy with a custom HttpClient: some phones route
    // even localhost through a local proxy app (ad-blockers etc.), which
    // breaks the tunnel WebSocket with a "Connection refused" to the
    // proxy's own port, not ours.
    //
    // Declared out here so the failure path can close it: it used to be
    // created inside the try and simply abandoned on error, together with the
    // channel, leaving the dead pair alive AND `_channel` pointing at it — one
    // leaked pair per reconnect attempt, ~40 of them after ten minutes of a
    // relay being down.
    final httpClient = HttpClient()..findProxy = (_) => 'DIRECT';
    WebSocketChannel? channel;
    try {
      // pingInterval is what makes a HALF-OPEN tunnel detectable. The Rust
      // forwarder (src/port_forward.rs run_forward) only breaks when a side
      // yields None, so a peer leg that dies without a FIN leaves the loopback
      // socket open forever: the client stayed `connected`, every write went
      // into a dead socket, and each command failed 15s later with "the relay
      // did not answer" while the UI still claimed to be online. Pings turn
      // that silent freeze into a reconnect.
      channel = IOWebSocketChannel.connect(
        _uri,
        customClient: httpClient,
        pingInterval: const Duration(seconds: 10),
        connectTimeout: const Duration(seconds: 20),
      );
      // A relay that accepts the TCP connection but never completes the
      // upgrade used to pin the client in `connecting` forever, which the home
      // page does not render as down.
      await channel.ready.timeout(const Duration(seconds: 10));
      // close() may have landed during that await. It cancelled a subscription
      // and closed a channel that did not exist yet, so without this re-check
      // the socket we are about to adopt outlives the client: nothing ever
      // reaps it (onDone early-returns on `_closed`) and it keeps the tunnel
      // and its ping timer alive for the process lifetime.
      if (_closed) {
        await _discard(channel, httpClient);
        return;
      }
      _channel = channel;
      _backoff = _initialBackoff;
      _setState(HerdrConnectionState.connected);
      _socketSub = channel.stream.listen(
        _onData,
        // An error on the socket is as terminal as a close: treat it the same
        // way, or a failed connection sits there never reconnecting.
        onError: (e) {
          debugPrint('[HerdrRelayClient] socket error: $e');
          _onSocketDone();
        },
        onDone: _onSocketDone,
        cancelOnError: false,
      );
    } catch (e) {
      debugPrint('[HerdrRelayClient] connect failed: $e');
      _channel = null;
      // Schedule BEFORE reaping. `sink.close()` on a channel whose `ready`
      // never completed does not always return: awaiting it here left the
      // reconnect unscheduled forever, so one failed attempt (a WS opened
      // while the tunnel was still converging) silently ended all recovery —
      // no retries, no logs, a UI frozen on stale state, and the dead socket
      // still parked on the relay. Cleanup must never gate reconnection.
      _scheduleReconnect();
      unawaited(_discard(channel, httpClient));
    }
  }

  /// Reap a channel/HttpClient pair we are not going to use.
  ///
  /// Every step is bounded: this runs detached on the failure path, and a
  /// close that never completes would otherwise leak the pair it is meant
  /// to reap.
  Future<void> _discard(WebSocketChannel? channel, HttpClient httpClient) async {
    try {
      await channel?.sink.close().timeout(const Duration(seconds: 3));
    } catch (_) {}
    try {
      httpClient.close(force: true);
    } catch (_) {}
  }

  /// Tear down the client: no more reconnects, pending requests fail.
  Future<void> close() async {
    _closed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _setState(HerdrConnectionState.closed);
    _failPending(const HerdrRelayException('Connection closed'));
    await _socketSub?.cancel();
    _socketSub = null;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _decoder.close();
    await Future.wait([
      _agentsController.close(),
      _blockedController.close(),
      _paneContentController.close(),
      _activityController.close(),
      _configController.close(),
      _stateController.close(),
      _inventoryController.close(),
      _commandErrorController.close(),
    ]);
  }

  void _onSocketDone() {
    if (_closed) return;
    debugPrint('[HerdrRelayClient] socket closed, scheduling reconnect');
    _failPending(const HerdrRelayException('Connection lost'));
    _scheduleReconnect();
  }

  /// Pending reconnect, held so it can never be scheduled twice.
  Timer? _reconnectTimer;

  void _scheduleReconnect() {
    if (_closed) return;
    // With cancelOnError: false a broken socket delivers onError AND onDone,
    // and this used to schedule an untracked Timer per call — two concurrent
    // connect()s, two live WebSockets, one of them orphaned and reconnecting
    // for the process lifetime.
    _reconnectTimer?.cancel();
    _setState(HerdrConnectionState.reconnecting);
    final delay = _backoff;
    _backoff = _backoff * 2 > _maxBackoff ? _maxBackoff : _backoff * 2;
    _reconnectTimer = Timer(delay, () {
      if (!_closed) connect();
    });
  }

  void _setState(HerdrConnectionState next) {
    if (_state == next) return;
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  void _failPending(HerdrRelayException error) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }

  // -------------------------------------------------------------------------
  // Incoming messages
  // -------------------------------------------------------------------------

  /// Sequence of the last large frame handed to the decode isolate, so a slow
  /// decode can never overwrite a newer snapshot that already landed.
  int _largeFrameSeq = 0;

  void _onData(dynamic raw) {
    if (raw is! String) return;
    // Decoding a pane snapshot is the single biggest main-thread stall in the
    // feature: 25.5ms for a 793 KB frame, measured. Small frames (everything
    // except pane_content) stay inline — an isolate hop would cost more than
    // it saves — but a big one goes to a worker, which also trims there so
    // only the visible tail crosses back.
    if (raw.length > _largeFrameBytes) {
      final seq = ++_largeFrameSeq;
      unawaited(_onLargeData(raw, seq));
      return;
    }
    Map<String, dynamic> message;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      message = Map<String, dynamic>.from(decoded);
    } catch (e) {
      debugPrint('[HerdrRelayClient] bad JSON frame: $e');
      return;
    }
    _dispatch(message);
  }

  /// Frames above this go through the decode isolate. Comfortably above every
  /// non-pane message the relay sends.
  static const int _largeFrameBytes = 64 * 1024;

  /// The one worker isolate every large frame is decoded on.
  final _HerdrDecodeWorker _decoder = _HerdrDecodeWorker();

  Future<void> _onLargeData(String raw, int seq) async {
    Map<String, dynamic> message;
    try {
      message = await _decoder.decode(raw);
    } catch (e) {
      debugPrint('[HerdrRelayClient] bad JSON frame: $e');
      return;
    }
    // A newer snapshot won the race, or we were closed while decoding.
    if (_closed || seq != _largeFrameSeq || message.isEmpty) return;
    // The worker already ran herdrTailLines on `content`; running it again on
    // the trimmed string is a second full scan of the tail for nothing.
    _dispatch(message, preTrimmed: true);
  }

  void _dispatch(Map<String, dynamic> message, {bool preTrimmed = false}) {
    switch (message['type'] as String? ?? '') {
      case 'push_config':
        config = HerdrPushConfig.fromJson(message);
        _configController.add(config!);
        break;
      case 'agents':
        _agentsByPane.clear();
        final list = message['agents'];
        if (list is List) {
          for (final item in list) {
            if (item is Map) {
              final agent =
                  HerdrAgent.fromJson(Map<String, dynamic>.from(item));
              _agentsByPane[agent.paneId] = agent;
            }
          }
        }
        _emitAgents();
        break;
      case 'agent_update':
      case 'blocked':
        final delta = HerdrAgent.fromJson(message);
        if (delta.paneId.isEmpty) return;
        final existing = _agentsByPane[delta.paneId];
        // Ordering guard, same as the relay's own (server.go: it applies a
        // delta only while `deltaRevision >= agent.StateRevision`). Frames can
        // queue up behind a slow decode or a reconnect, and an old one must
        // not walk state back to somewhere the relay has already left. Only
        // `agents` snapshots are authoritative regardless of revision.
        if (existing != null &&
            delta.presentKeys.contains('pane_revision') &&
            delta.revision < existing.revision) {
          return;
        }
        final merged = existing?.merge(delta) ?? delta;
        _agentsByPane[delta.paneId] = merged;
        _emitAgents();
        if (message['type'] == 'blocked') _blockedController.add(merged);
        break;
      case 'inventory_status':
        inventory = HerdrInventoryStatus.fromJson(message);
        _inventoryController.add(inventory);
        break;
      case 'pane_content':
        final frame = HerdrPaneContent.fromJson(message, trim: !preTrimmed);
        if (frame.fingerprint.isNotEmpty) {
          _paneFingerprints[frame.paneId] = frame.fingerprint;
        }
        _applyPaneAttention(message);
        _paneContentController.add(frame);
        break;
      case 'pane_unchanged':
        // The pane is byte-identical to what we already hold. Forward it so
        // the poller can back off, but there is nothing to re-render.
        final frame = HerdrPaneContent.unchangedFrom(message);
        if (frame.fingerprint.isNotEmpty) {
          _paneFingerprints[frame.paneId] = frame.fingerprint;
        }
        _paneContentController.add(frame);
        break;
      case 'pane_resync':
        // The relay lost its own baseline: force a full read next time.
        _paneFingerprints.remove(message['pane_id'] as String? ?? '');
        break;
      case 'activity_history':
        final list = message['activities'];
        if (list is List) {
          for (final item in list) {
            if (item is Map) {
              _activityController.add(
                  HerdrActivity.fromJson(Map<String, dynamic>.from(item)));
            }
          }
        }
        break;
      case 'activity':
        final item = message['activity'];
        if (item is Map) {
          _activityController
              .add(HerdrActivity.fromJson(Map<String, dynamic>.from(item)));
        }
        break;
      case 'command_result':
        final result = HerdrCommandResult.fromJson(message);
        final completer = _pending.remove(result.requestId);
        if (completer == null) {
          // No one is waiting: a fire-and-forget request (read_pane) whose
          // answer used to be dropped entirely.
          if (!result.isSuccess && _paneReadRequests.remove(result.requestId)) {
            _commandErrorController.add(result);
          }
          break;
        }
        if (!completer.isCompleted) {
          if (result.isSuccess) {
            completer.complete(result);
          } else {
            completer.completeError(HerdrRelayException(
                result.error.isNotEmpty ? result.error : 'Command failed'));
          }
        }
        break;
      default:
        // slash_commands answers, push acks, update_status, ... not needed.
        break;
    }
  }

  void _emitAgents() {
    _agentsController.add(List.unmodifiable(_agentsByPane.values));
  }

  /// Fold the attention block the relay attaches to every successful
  /// `pane_content` into the agent we track for that pane.
  ///
  /// The relay re-runs its classifier on the pane it just read and enriches the
  /// answer with `attention_kind` / `prompt` / `command` / `options` /
  /// `interaction` (server.go preparePaneResponse). The client used to throw
  /// all of it away, even though it is the FRESHEST classification available —
  /// it arrives every poll, whereas an `agents` snapshot is seconds away — and
  /// it is what recovers an attention block a delta dropped.
  ///
  /// Only applied to an agent the relay still reports as blocked, and only when
  /// something actually changed: re-emitting the snapshot every 1.5s would
  /// rebuild the whole agent list for nothing.
  void _applyPaneAttention(Map<String, dynamic> message) {
    if (message['error'] != null) return;
    if (!message.containsKey('interaction') && !message.containsKey('options')) {
      return;
    }
    final paneId = message['pane_id'] as String? ?? '';
    if (paneId.isEmpty) return;
    String? key;
    if (_agentsByPane.containsKey(paneId)) {
      key = paneId;
    } else {
      // Requests quote `raw_pane_id` when there is one, so the answer comes
      // back keyed differently from the snapshot.
      for (final entry in _agentsByPane.entries) {
        if (entry.value.rawPaneId == paneId) {
          key = entry.key;
          break;
        }
      }
    }
    if (key == null) return;
    final existing = _agentsByPane[key]!;
    if (!existing.isBlocked) return;

    final interaction =
        HerdrQuestionInteraction.fromJson(message['interaction']);
    final options =
        (message['options'] as List?)?.map((e) => e.toString()).toList() ??
            const <String>[];
    final attentionKind = message['attention_kind'] as String? ?? '';
    final prompt = message['prompt'] as String? ?? '';
    final command = message['command'] as String? ?? '';
    // An enrichment that found nothing at all is not evidence the block is
    // over — the pane may simply have scrolled the prompt out of the tail.
    if (interaction == null && options.isEmpty) return;
    final unchanged = existing.attentionKind == attentionKind &&
        existing.prompt == prompt &&
        existing.command == command &&
        existing.interaction?.id == interaction?.id &&
        _sameOptions(existing.options, options);
    if (unchanged) return;
    _agentsByPane[key] = existing.withAttention(
      attentionKind: attentionKind,
      prompt: prompt,
      command: command,
      options: options,
      interaction: interaction,
    );
    _emitAgents();
  }

  static bool _sameOptions(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // -------------------------------------------------------------------------
  // Outgoing messages
  // -------------------------------------------------------------------------

  String _nextRequestId() => 'flutter-${++_requestSeq}';

  bool get _isOpen => _channel != null && _state == HerdrConnectionState.connected;

  /// Fire-and-forget send (used for `read_pane` / `refresh_agents`, whose
  /// answers arrive on dedicated streams instead of command_result).
  void _sendRaw(Map<String, dynamic> payload) {
    if (!_isOpen) return;
    _channel!.sink.add(jsonEncode(payload));
  }

  /// Send a command and wait for its `command_result`, correlated by
  /// `request_id`. Mutating commands get `"protocol": 2` automatically.
  Future<HerdrCommandResult> _sendCommand(Map<String, dynamic> payload,
      {bool mutating = true}) {
    if (!_isOpen) {
      return Future.error(const HerdrRelayException('Relay is not connected'));
    }
    final requestId = _nextRequestId();
    final completer = Completer<HerdrCommandResult>();
    _pending[requestId] = completer;
    _channel!.sink.add(jsonEncode({
      if (mutating) 'protocol': kHerdrProtocolVersion,
      ...payload,
      'request_id': requestId,
    }));
    return completer.future.timeout(_commandTimeout, onTimeout: () {
      _pending.remove(requestId);
      throw const HerdrRelayException('Relay did not answer in time');
    });
  }

  /// Ask for the latest agent snapshot.
  void refreshAgents() => _sendRaw({'type': 'refresh_agents'});

  /// Request the last [lines] of a pane in `ansi` format. There is no
  /// streaming: callers poll this (the PWA polls every ~3 s).
  /// Whether the relay can reflow a pane to a width we ask for
  /// (`pane_size_lease`, relay 0.12.0+). False on older relays, and the caller
  /// must simply not offer it.
  bool get supportsPaneSizeLease =>
      config?.capabilities.contains('pane_size_lease') ?? false;

  /// Reflow [paneId] to [columns] and return the width the relay actually
  /// applied (it clamps, and may know better than we do).
  ///
  /// The lease is held until [releasePaneSize] or until the relay drops it, and
  /// it resizes the REAL pane — the same terminal reflows on the desktop.
  Future<int> leasePaneSize(String paneId, int columns) async {
    final result = await _sendCommand({
      'type': 'lease_pane_size',
      'pane_id': paneId,
      'columns': columns,
    });
    final applied = result.data?['columns'];
    if (applied is! int || applied <= 0) {
      throw const HerdrRelayException(
          'El relay no confirmó el ancho aplicado al pane');
    }
    return applied;
  }

  /// Give the pane its original width back.
  Future<HerdrCommandResult> releasePaneSize(String paneId) =>
      _sendCommand({'type': 'release_pane_size', 'pane_id': paneId});

  /// Latest pane fingerprint per pane id, quoted back so the relay can answer
  /// `pane_unchanged` instead of resending the scrollback.
  final Map<String, String> _paneFingerprints = {};

  /// Drop the cached fingerprint so the next read is a full one.
  void forgetPaneFingerprint(String paneId) => _paneFingerprints.remove(paneId);

  /// Request ids of the `read_pane` calls still in flight.
  ///
  /// Bounded: the answer arrives on the pane_content stream and carries no
  /// request id, so the only thing this can be pruned by is age. A handful is
  /// plenty — polls are 1.5s apart and the relay answers in milliseconds.
  final Set<String> _paneReadRequests = <String>{};
  static const int _maxTrackedPaneReads = 8;

  void readPane(String paneId,
      {int lines = kHerdrPaneTailLines, bool force = false}) {
    // The contract carries one (contracts/fixtures/inbound/read_pane.json) and
    // the relay implicitly acknowledges the pane on every read, correlating the
    // failure with this id. Without it, "Agent is unavailable" from that path
    // had no request to attach to and was dropped on the floor.
    final requestId = _nextRequestId();
    if (_paneReadRequests.length >= _maxTrackedPaneReads) {
      _paneReadRequests.remove(_paneReadRequests.first);
    }
    _paneReadRequests.add(requestId);
    _sendRaw({
      'type': 'read_pane',
      'request_id': requestId,
      'pane_id': paneId,
      'lines': lines,
      'format': 'ansi',
      // Relay 0.12.0 (`pane_realtime_delta` era) compares this and answers
      // `pane_unchanged` when it still matches. Without it EVERY poll — one
      // every 1.5s while an agent works — dragged the entire scrollback
      // (measured 728 KB) through the tunnel and decoded it on the UI
      // isolate, whether or not a single character had changed.
      'content_fingerprint': force ? '' : (_paneFingerprints[paneId] ?? ''),
    });
  }

  /// Send raw text to the pane (no implicit Enter).
  Future<HerdrCommandResult> sendText(String paneId, String text) =>
      _sendCommand({'type': 'send_text', 'pane_id': paneId, 'text': text});

  /// Send named keys, e.g. `['Enter']`, `['Escape']`, `['Ctrl+C']`.
  Future<HerdrCommandResult> sendKeys(String paneId, List<String> keys) =>
      _sendCommand({'type': 'send_keys', 'pane_id': paneId, 'keys': keys});

  /// Type [text] and submit it (the relay appends Enter).
  Future<HerdrCommandResult> submitPrompt(String paneId, String text) =>
      _sendCommand({'type': 'submit_prompt', 'pane_id': paneId, 'text': text});

  /// Answer an approval prompt: option [index] of the given [eventId].
  Future<HerdrCommandResult> respond(
          String paneId, String eventId, int index) =>
      _sendCommand({
        'type': 'respond',
        'pane_id': paneId,
        'event_id': eventId,
        'index': index,
      });

  /// Answer a structured question.
  Future<HerdrCommandResult> answerQuestion(
    String paneId,
    String interactionId, {
    List<int> selectedIndices = const [],
    bool otherSelected = false,
    String otherText = '',
  }) =>
      _sendCommand({
        'type': 'answer_question',
        'pane_id': paneId,
        'interaction_id': interactionId,
        'selected_indices': selectedIndices,
        'other_selected': otherSelected,
        'other_text': otherText,
      });

  /// Move inside a multi-step question (`previous` / `next`).
  Future<HerdrCommandResult> navigateQuestion(
          String paneId, String interactionId, String direction) =>
      _sendCommand({
        'type': 'navigate_question',
        'pane_id': paneId,
        'interaction_id': interactionId,
        'direction': direction,
      });

  /// Launch a new agent from a profile.
  Future<HerdrCommandResult> agentStart(
          {required String profileId,
          String name = '',
          String cwd = '',
          String prompt = ''}) =>
      _sendCommand({
        'type': 'agent_start',
        'profile_id': profileId,
        if (name.isNotEmpty) 'name': name,
        'cwd': cwd,
        'prompt': prompt,
      });

  Future<HerdrCommandResult> agentStop(String paneId) =>
      _sendCommand({'type': 'agent_stop', 'pane_id': paneId});

  Future<HerdrCommandResult> agentRestart(String paneId) =>
      _sendCommand({'type': 'agent_restart', 'pane_id': paneId});

  /// Rename an agent tab.
  Future<HerdrCommandResult> agentRename(String paneId, String name) =>
      _sendCommand({'type': 'agent_rename', 'pane_id': paneId, 'name': name});

  /// Clear the agent pane scrollback.
  Future<HerdrCommandResult> agentClear(String paneId) =>
      _sendCommand({'type': 'agent_clear', 'pane_id': paneId});

  /// List the subdirectories of [path] (empty for the home directory) for the
  /// cwd picker. Read-only command, so it does not carry `"protocol": 2`.
  Future<HerdrDirListing> listDirectories([String path = '']) async {
    final result = await _sendCommand(
      {'type': 'list_directories', if (path.isNotEmpty) 'path': path},
      mutating: false,
    );
    return HerdrDirListing.fromJson(result.data ?? const {});
  }

  /// Slash command catalog of one agent (`list_slash_commands`; read-only).
  /// Empty when the agent does not advertise commands.
  Future<List<HerdrSlashCommand>> listSlashCommands(String paneId) async {
    final result = await _sendCommand(
      {'type': 'list_slash_commands', 'pane_id': paneId},
      mutating: false,
    );
    final raw = result.data?['commands'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map)
          HerdrSlashCommand.fromJson(Map<String, dynamic>.from(item)),
    ];
  }
}
