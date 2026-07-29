import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
    this.submitLabel = 'Submit',
    this.canGoBack = false,
    this.questionIndex = 0,
    this.questionTotal = 0,
  });

  bool get isMultiSelect => kind == 'multi_select';

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
    if (other is Map) {
      otherLabel = other['label'] as String? ?? '';
      otherSelected = other['selected'] as bool? ?? false;
    }
    return HerdrQuestionInteraction(
      id: id,
      kind: map['kind'] as String? ?? 'single_select',
      question: map['question'] as String? ?? '',
      options: options,
      otherLabel: otherLabel,
      otherSelected: otherSelected,
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
      );

  /// Apply an `agent_update`/`blocked` delta on top of this snapshot entry.
  /// Delta messages omit fields that did not change, so empty values in the
  /// delta keep the previous value (except [status], always authoritative).
  HerdrAgent merge(HerdrAgent delta) => HerdrAgent(
        paneId: paneId,
        rawPaneId: delta.rawPaneId.isNotEmpty ? delta.rawPaneId : rawPaneId,
        terminalId: delta.terminalId.isNotEmpty ? delta.terminalId : terminalId,
        tabId: delta.tabId.isNotEmpty ? delta.tabId : tabId,
        tabLabel: delta.tabLabel.isNotEmpty ? delta.tabLabel : tabLabel,
        tabNumber: delta.tabNumber != 0 ? delta.tabNumber : tabNumber,
        workspaceId:
            delta.workspaceId.isNotEmpty ? delta.workspaceId : workspaceId,
        agent: delta.agent.isNotEmpty ? delta.agent : agent,
        name: delta.name.isNotEmpty ? delta.name : name,
        status: delta.status.isNotEmpty ? delta.status : status,
        cwd: delta.cwd.isNotEmpty ? delta.cwd : cwd,
        project: delta.project.isNotEmpty ? delta.project : project,
        host: delta.host.isNotEmpty ? delta.host : host,
        session: delta.session.isNotEmpty ? delta.session : session,
        updatedAt: delta.updatedAt != 0 ? delta.updatedAt : updatedAt,
        // The attention block is taken WHOLE from a delta that carries a
        // status, never field-by-field.
        //
        // Merging it per field made it unclearable: an agent that went from a
        // structured question to a plain approval kept the old `interaction`
        // (`delta.interaction ?? interaction` cannot express "no question"),
        // so the phone rendered a form bound to a dead question id and the
        // answer was rejected by the host — with no way to reach the approval
        // buttons that were actually waiting.
        eventId: delta.status.isNotEmpty
            ? delta.eventId
            : (delta.eventId.isNotEmpty ? delta.eventId : eventId),
        attentionKind: delta.status.isNotEmpty
            ? delta.attentionKind
            : (delta.attentionKind.isNotEmpty
                ? delta.attentionKind
                : attentionKind),
        prompt: delta.status.isNotEmpty
            ? delta.prompt
            : (delta.prompt.isNotEmpty ? delta.prompt : prompt),
        command: delta.status.isNotEmpty
            ? delta.command
            : (delta.command.isNotEmpty ? delta.command : command),
        options: delta.status.isNotEmpty
            ? delta.options
            : (delta.options.isNotEmpty ? delta.options : options),
        interaction:
            delta.status.isNotEmpty ? delta.interaction : (delta.interaction ?? interaction),
      );
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

  const HerdrPaneContent({
    required this.paneId,
    this.content = '',
    this.format = 'plain',
    this.fingerprint = '',
    this.unchanged = false,
  });

  factory HerdrPaneContent.fromJson(Map<String, dynamic> json) =>
      HerdrPaneContent(
        paneId: json['pane_id'] as String? ?? '',
        content: herdrTailLines(json['content'] as String? ?? ''),
        format: json['format'] as String? ?? 'plain',
        fingerprint: json['content_fingerprint'] as String? ?? '',
      );

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
/// Top-level so it can be handed to [compute]. Trimming inside the isolate is
/// the point: the frame is up to 876 KB and only the ~38 KB tail is ever
/// rendered, so that is all that crosses back.
Map<String, dynamic> _herdrDecodeFrame(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map) return const {};
  final message = Map<String, dynamic>.from(decoded);
  final content = message['content'];
  if (content is String) message['content'] = herdrTailLines(content);
  return message;
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

  /// Full agent snapshot, re-emitted on every `agents`/`agent_update`/
  /// `blocked` message.
  Stream<List<HerdrAgent>> get agents => _agentsController.stream;

  /// Emits the agent (with attention payload) when it becomes blocked.
  Stream<HerdrAgent> get blocked => _blockedController.stream;

  Stream<HerdrPaneContent> get paneContent => _paneContentController.stream;
  Stream<HerdrActivity> get activity => _activityController.stream;
  Stream<HerdrPushConfig> get pushConfig => _configController.stream;
  Stream<HerdrConnectionState> get connectionState => _stateController.stream;

  HerdrConnectionState _state = HerdrConnectionState.connecting;
  HerdrConnectionState get state => _state;

  /// True once [close] ran. A closed client never reconnects, so the owner
  /// (HerdrConnectionManager) must build a new one instead of reusing it.
  bool get isClosed => _closed;

  /// Last received handshake; null until the first `push_config` arrives.
  HerdrPushConfig? config;

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
    try {
      // Bypass any system proxy with a custom HttpClient: some phones route
      // even localhost through a local proxy app (ad-blockers etc.), which
      // breaks the tunnel WebSocket with a "Connection refused" to the
      // proxy's own port, not ours.
      final httpClient = HttpClient()..findProxy = (_) => 'DIRECT';
      // pingInterval is what makes a HALF-OPEN tunnel detectable. The Rust
      // forwarder (src/port_forward.rs run_forward) only breaks when a side
      // yields None, so a peer leg that dies without a FIN leaves the loopback
      // socket open forever: the client stayed `connected`, every write went
      // into a dead socket, and each command failed 15s later with "the relay
      // did not answer" while the UI still claimed to be online. Pings turn
      // that silent freeze into a reconnect.
      final channel = IOWebSocketChannel.connect(
        _uri,
        customClient: httpClient,
        pingInterval: const Duration(seconds: 10),
        connectTimeout: const Duration(seconds: 20),
      );
      _channel = channel;
      // A relay that accepts the TCP connection but never completes the
      // upgrade used to pin the client in `connecting` forever, which the home
      // page does not render as down.
      await channel.ready.timeout(const Duration(seconds: 10));
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
      _scheduleReconnect();
    }
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
    await Future.wait([
      _agentsController.close(),
      _blockedController.close(),
      _paneContentController.close(),
      _activityController.close(),
      _configController.close(),
      _stateController.close(),
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

  Future<void> _onLargeData(String raw, int seq) async {
    Map<String, dynamic> message;
    try {
      message = await compute(_herdrDecodeFrame, raw);
    } catch (e) {
      debugPrint('[HerdrRelayClient] bad JSON frame: $e');
      return;
    }
    // A newer snapshot won the race, or we were closed while decoding.
    if (_closed || seq != _largeFrameSeq || message.isEmpty) return;
    _dispatch(message);
  }

  void _dispatch(Map<String, dynamic> message) {
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
        final merged = existing?.merge(delta) ?? delta;
        _agentsByPane[delta.paneId] = merged;
        _emitAgents();
        if (message['type'] == 'blocked') _blockedController.add(merged);
        break;
      case 'pane_content':
        final frame = HerdrPaneContent.fromJson(message);
        if (frame.fingerprint.isNotEmpty) {
          _paneFingerprints[frame.paneId] = frame.fingerprint;
        }
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
        if (completer != null && !completer.isCompleted) {
          if (result.ok || result.phase == 'advanced' || result.phase == 'navigated') {
            completer.complete(result);
          } else {
            completer.completeError(HerdrRelayException(
                result.error.isNotEmpty ? result.error : 'Command failed'));
          }
        }
        break;
      default:
        // inventory_status, slash_commands answers, push acks, ... not needed.
        break;
    }
  }

  void _emitAgents() {
    _agentsController.add(List.unmodifiable(_agentsByPane.values));
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

  void readPane(String paneId,
          {int lines = kHerdrPaneTailLines, bool force = false}) =>
      _sendRaw({
        'type': 'read_pane',
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
