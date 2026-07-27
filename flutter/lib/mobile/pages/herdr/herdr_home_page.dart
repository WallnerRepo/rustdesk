import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';

import 'herdr_connection_manager.dart';
import 'herdr_agent_page.dart';
import 'herdr_fuzzy.dart';
import 'herdr_history.dart';
import 'herdr_history_store.dart';
import 'herdr_name_dialog.dart';
import 'herdr_quota.dart';
import 'herdr_relay_client.dart';
import 'herdr_search.dart';

/// Native herdr home: lists the agents running on the remote host, grouped
/// in collapsible workspaces, and lets the user jump into any of them,
/// manage them (rename / restart / stop) or launch new ones.
///
/// Replaces the old WebView-based page (herdr_app_page.dart): the UI talks
/// the relay WebSocket protocol directly through [HerdrRelayClient].
///
/// This page does NOT own the connection. The tunnel and the relay client
/// belong to [HerdrConnectionManager] and outlive it, so re-entering herdr is
/// instant; they are closed with the remote session (remote_page.dart).
class HerdrHomePage extends StatefulWidget {
  const HerdrHomePage({
    Key? key,
    required this.id,
    this.password,
    this.isSharedPassword,
    this.forceRelay,
    this.connToken,
  }) : super(key: key);

  final String id;
  final String? password;
  final bool? isSharedPassword;
  final bool? forceRelay;
  final String? connToken;

  @override
  State<HerdrHomePage> createState() => _HerdrHomePageState();
}

class _HerdrHomePageState extends State<HerdrHomePage> {
  HerdrRelayClient? _client;
  final List<StreamSubscription> _subs = [];

  bool _opening = true;
  String? _error;
  bool _socketDown = false;
  List<HerdrAgent> _agents = const [];

  /// aiuse quota per provider (worst window); empty or null hides the strip.
  List<HerdrQuotaEntry>? _quota;
  Timer? _quotaTimer;

  /// Workspaces the user collapsed; everything starts expanded.
  final Set<String> _collapsedWorkspaces = {};

  /// Recently opened agents and workspaces, persisted across restarts.
  late HerdrHistory _history;

  @override
  void initState() {
    super.initState();
    // Sync FFI read, cheap enough for initState (see herdr_history_store).
    _history = herdrLoadHistory();
    // The remote session disables the soft keyboard globally; the herdr UI
    // has regular text fields, so re-enable it while open and restore the
    // session's expectation on the way out.
    unawaited(gFFI.invokeMethod("enable_soft_keyboard", true));
    _open();
    _quotaTimer = Timer.periodic(
        const Duration(minutes: 5), (_) => unawaited(_loadQuota()));
  }

  @override
  void dispose() {
    unawaited(gFFI.invokeMethod("enable_soft_keyboard", false));
    _quotaTimer?.cancel();
    for (final sub in _subs) {
      sub.cancel();
    }
    // The tunnel and the relay client are owned by HerdrConnectionManager and
    // deliberately OUTLIVE this page, so returning to herdr is instant and the
    // connection stays up. They are torn down with the remote session itself
    // (remote_page.dart dispose). Only this page's own listeners go here.
    super.dispose();
  }

  /// Attach to the peer's relay client, creating the tunnel only if there
  /// isn't one already. [force] rebuilds the whole stack — that is what the
  /// error screen's "Reintentar" needs.
  Future<void> _open({bool force = false}) async {
    // Drop this page's previous listeners; the client itself is not ours to
    // close.
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    _client = null;
    setState(() {
      _opening = true;
      _error = null;
    });
    if (force) {
      await HerdrConnectionManager.reset(widget.id);
    }
    final HerdrRelayClient client;
    try {
      client = await HerdrConnectionManager.client(
        peerId: widget.id,
        password: widget.password,
        isSharedPassword: widget.isSharedPassword,
        forceRelay: widget.forceRelay,
        connToken: widget.connToken,
      );
    } catch (e) {
      debugPrint('[HerdrHomePage] tunnel open failed: $e');
      if (!mounted) return;
      setState(() {
        _opening = false;
        // Surface the underlying error: "Connection refused" means the local
        // tunnel listener never came up; a timeout means the listener is up
        // but the host side is not answering (relay down or tunnel broken).
        _error = 'herdr relay no responde en el host\n\n$e';
      });
      return;
    }
    if (!mounted) return;
    _client = client;
    // Re-entry: the client is already connected and holds a snapshot, so paint
    // it now instead of showing an empty list until the next push.
    _agents = client.currentAgents;
    _socketDown = client.state == HerdrConnectionState.reconnecting;
    _subs.add(client.agents.listen((agents) {
      if (mounted) setState(() => _agents = agents);
    }));
    _subs.add(client.connectionState.listen((state) {
      if (!mounted) return;
      setState(() => _socketDown =
          state == HerdrConnectionState.reconnecting ||
              state == HerdrConnectionState.closed);
    }));
    // NOT client.connect(): the manager already connected it, and a second
    // connect on a live client would leak the first WebSocket. Ask for a fresh
    // snapshot instead — on re-entry the cached one can be minutes old.
    client.refreshAgents();
    setState(() => _opening = false);
    // The quota fetch needs the tunnel up: it runs only after _open.
    unawaited(_loadQuota());
  }

  Future<void> _refresh() async {
    _client?.refreshAgents();
    // Give the relay a moment to answer so the spinner doesn't feel broken.
    await Future.delayed(const Duration(milliseconds: 600));
  }

  /// Refresh the aiuse quota strip. Any failure hides it silently.
  Future<void> _loadQuota() async {
    try {
      final quota =
          await herdrFetchQuota(HerdrConnectionManager.kQuotaLocalUrl);
      if (mounted) setState(() => _quota = quota);
    } catch (_) {
      if (mounted) setState(() => _quota = null);
    }
  }

  // ---------------------------------------------------------------------------
  // Agent actions
  // ---------------------------------------------------------------------------

  Future<void> _runAction(Future<HerdrCommandResult> future) async {
    try {
      await future;
      _client?.refreshAgents();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _renameAgent(HerdrAgent agent) async {
    final client = _client;
    if (client == null) return;
    final name = await showHerdrRenameDialog(context, agent.name);
    if (name == null || name.isEmpty || name == agent.name) return;
    await _runAction(client.agentRename(agent.requestPaneId, name));
  }

  Future<void> _stopAgent(HerdrAgent agent) async {
    final client = _client;
    if (client == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Parar agente'),
        content: Text('¿Parar "${agent.displayName}"? Se cerrará su terminal.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Parar'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _runAction(client.agentStop(agent.requestPaneId));
  }

  Future<void> _createAgent({String? initialCwd}) async {
    final client = _client;
    if (client == null) return;
    final profiles = client.config?.agentProfiles ?? const [];
    final launched = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _CreateAgentSheet(
          client: client, profiles: profiles, initialCwd: initialCwd),
    );
    if (launched == true) _refresh();
  }

  void _openAgent(HerdrAgent agent) {
    final client = _client;
    if (client == null) return;
    _recordHistory(agent);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            HerdrAgentPage(client: client, initialAgent: agent),
      ),
    );
  }

  /// Remember an opened agent and, separately, the workspace it belongs to:
  /// agents are transient (a restart gives a new pane) while the workspace
  /// and its cwd survive, which is what makes "reopen" work later.
  void _recordHistory(HerdrAgent agent) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _history.record(HerdrHistoryEntry(
      kind: HerdrHistoryKind.agent,
      id: agent.displayName,
      label: agent.displayName,
      subtitle: [agent.agent, agent.project]
          .where((s) => s.isNotEmpty)
          .join(' · '),
      cwd: agent.cwd,
      workspaceId: agent.workspaceId,
      lastOpenedAt: now,
    ));
    if (agent.cwd.isNotEmpty) {
      _history.record(HerdrHistoryEntry(
        kind: HerdrHistoryKind.workspace,
        id: agent.cwd,
        label: agent.project.isNotEmpty
            ? agent.project
            : agent.cwd.split('/').last,
        subtitle: agent.cwd,
        cwd: agent.cwd,
        workspaceId: agent.workspaceId,
        lastOpenedAt: now,
      ));
    }
    unawaited(herdrSaveHistory(_history));
  }


  Future<void> _openSearch() async {
    final selection = await showModalBottomSheet<_SearchSelection>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _SearchSheet(
        agents: _agents,
        history: _history,
        onHistoryChanged: () => unawaited(herdrSaveHistory(_history)),
      ),
    );
    if (!mounted || selection == null) return;
    // The sheet mutates _history in place (pins, removals); reflect that.
    setState(() {});
    final agent = selection.agent;
    if (agent != null) {
      _openAgent(agent);
    } else if (selection.cwd != null) {
      // A remembered place with nothing running in it: the useful action is
      // to start an agent there, pre-filled.
      await _createAgent(initialCwd: selection.cwd);
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final hasContent = !_opening && _error == null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('herdr'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Buscar e historial',
            // Usable with no agents running: the history is still there.
            onPressed:
                _agents.isEmpty && _history.isEmpty ? null : _openSearch,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Actualizar',
            onPressed: _client == null ? null : _refresh,
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: hasContent
          ? FloatingActionButton.extended(
              onPressed: _createAgent,
              icon: const Icon(Icons.add),
              label: const Text('Nuevo agente'),
            )
          : null,
    );
  }

  Widget _buildBody() {
    if (_opening) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Conectando con herdr…'),
          ],
        ),
      );
    }
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.smart_toy, size: 48, color: Colors.grey),
              const SizedBox(height: 16),
              Text(error, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                // Full rebuild: the existing tunnel is what failed.
                onPressed: () => _open(force: true),
                child: const Text('Reintentar'),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        if (_socketDown)
          MaterialBanner(
            content: const Text('Conexión perdida, reintentando…'),
            leading: const Icon(Icons.cloud_off),
            actions: [
              TextButton(
                  onPressed: () => _open(force: true),
                  child: const Text('Reintentar')),
            ],
          ),
        if (_quota != null && _quota!.isNotEmpty) _buildQuotaStrip(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: _agents.isEmpty ? _buildEmpty() : _buildAgentList(),
          ),
        ),
      ],
    );
  }

  /// aiuse quota strip: one chip per provider with ALL its windows sorted
  /// by severity, each measure colored by its own remaining headroom.
  Widget _buildQuotaStrip() {
    final entries = _quota!;
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Wrap(
        spacing: 14,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final entry in entries)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.bolt,
                    size: 14, color: _quotaColor(entry.worstRemaining)),
                const SizedBox(width: 3),
                Text(
                  entry.displayName,
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 5),
                for (var i = 0; i < entry.windows.length; i++) ...[
                  if (i > 0)
                    Text(' · ',
                        style: Theme.of(context).textTheme.labelMedium),
                  Text(
                    '${entry.windows[i].label} ${entry.windows[i].remaining.round()}%',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color:
                              _quotaColor(entry.windows[i].remaining),
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }

  static Color _quotaColor(double remaining) {
    if (remaining > 50) return Colors.green;
    if (remaining >= 20) return Colors.amber.shade800;
    return Colors.red;
  }

  Widget _buildEmpty() {
    // A scrollable is required for RefreshIndicator to work on empty lists.
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        Icon(Icons.smart_toy_outlined,
            size: 48, color: Theme.of(context).colorScheme.outline),
        const SizedBox(height: 16),
        const Center(child: Text('No hay agentes en ejecución')),
        const SizedBox(height: 8),
        Center(
          child: Text(
            'Pulsa "Nuevo agente" para lanzar uno',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  Widget _buildAgentList() {
    final groups = <String, List<HerdrAgent>>{};
    for (final agent in _agents) {
      final key = agent.workspaceId.isNotEmpty ? agent.workspaceId : 'default';
      groups.putIfAbsent(key, () => []).add(agent);
    }
    final keys = groups.keys.toList()..sort();
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: keys.length,
      itemBuilder: (context, index) =>
          _buildWorkspaceGroup(keys[index], groups[keys[index]]!),
    );
  }

  /// Collapsible workspace section: header with name, counters and a
  /// expand/collapse toggle, then one card per agent.
  Widget _buildWorkspaceGroup(String key, List<HerdrAgent> agents) {
    final collapsed = _collapsedWorkspaces.contains(key);
    final blockedCount = agents.where((a) => a.isBlocked).length;
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() {
            collapsed
                ? _collapsedWorkspaces.remove(key)
                : _collapsedWorkspaces.add(key);
          }),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 8, 4),
            child: Row(
              children: [
                Icon(
                  collapsed ? Icons.expand_more : Icons.expand_less,
                  size: 20,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 4),
                Icon(Icons.workspaces_outlined,
                    size: 18, color: colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    key == 'default' ? 'Workspace' : key,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(color: colorScheme.primary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (blockedCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Badge(
                      label: Text('$blockedCount'),
                      backgroundColor: colorScheme.error,
                    ),
                  ),
                Text(
                  '${agents.length}',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            ),
          ),
        ),
        if (!collapsed)
          ...agents.map((agent) => _AgentCard(
                agent: agent,
                onTap: () => _openAgent(agent),
                onRename: () => _renameAgent(agent),
                onRestart: () =>
                    _runAction(_client!.agentRestart(agent.requestPaneId)),
                onStop: () => _stopAgent(agent),
              )),
      ],
    );
  }
}

/// Agent row card: status icon with color, display name, agent and project,
/// attention badge when blocked and an overflow menu with the lifecycle
/// actions.
class _AgentCard extends StatelessWidget {
  const _AgentCard({
    required this.agent,
    required this.onTap,
    required this.onRename,
    required this.onRestart,
    required this.onStop,
  });

  final HerdrAgent agent;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onRestart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final subtitle = [
      if (agent.agent.isNotEmpty) agent.agent,
      if (agent.project.isNotEmpty) agent.project else agent.cwd,
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(
            children: [
              _StatusIcon(status: agent.status),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      agent.displayName,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              if (agent.isBlocked)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(Icons.notification_important_outlined,
                      color: colorScheme.error, size: 20),
                ),
              PopupMenuButton<String>(
                tooltip: 'Acciones',
                onSelected: (action) {
                  switch (action) {
                    case 'rename':
                      onRename();
                    case 'restart':
                      onRestart();
                    case 'stop':
                      onStop();
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'rename',
                    child: ListTile(
                      leading: Icon(Icons.edit_outlined),
                      title: Text('Renombrar'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  PopupMenuItem(
                    value: 'restart',
                    child: ListTile(
                      leading: Icon(Icons.restart_alt),
                      title: Text('Reiniciar'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  PopupMenuItem(
                    value: 'stop',
                    child: ListTile(
                      leading: Icon(Icons.stop_circle_outlined),
                      title: Text('Parar'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Colored status dot: green while working, red/amber when blocked waiting
/// for a decision, grey when idle.
class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (status) {
      'working' => (Icons.play_circle_fill, Colors.green),
      'blocked' => (Icons.error, Theme.of(context).colorScheme.error),
      'idle' => (Icons.pause_circle, Colors.grey),
      _ => (Icons.circle_outlined, Colors.grey),
    };
    return Icon(icon, color: color);
  }
}

/// Bottom sheet to launch a new agent: profile (from `push_config`), cwd
/// picked through `list_directories`, an optional name and an optional
/// initial prompt.
class _CreateAgentSheet extends StatefulWidget {
  const _CreateAgentSheet({
    required this.client,
    required this.profiles,
    this.initialCwd,
  });

  final HerdrRelayClient client;
  final List<HerdrAgentProfile> profiles;

  /// Pre-selected working directory, set when the sheet is opened from a
  /// history entry. Null falls back to the resolved home path.
  final String? initialCwd;

  @override
  State<_CreateAgentSheet> createState() => _CreateAgentSheetState();
}

class _CreateAgentSheetState extends State<_CreateAgentSheet> {
  late String _profileId;
  String _cwd = '';
  String _homePath = '';
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _promptController = TextEditingController();
  bool _nameTouched = false;
  String? _nameError;
  String? _launchError;
  bool _launching = false;

  /// 'auto': the relay groups by cwd (joins a matching workspace or creates
  /// one). 'new': only allow launching when the cwd matches no running
  /// agent, which guarantees a fresh workspace — the relay protocol has no
  /// force-new flag (see SelectWorkspaceForCwd in the relay).
  String _workspaceMode = 'auto';

  /// Whether the chosen cwd already runs an agent (same grouping rule the
  /// relay applies).
  bool get _cwdMatchesExisting =>
      widget.client.currentAgents.any((a) => a.cwd == _cwd);

  /// Label the relay would give a new workspace (filepath.Base(cwd)).
  String get _workspaceLabel {
    if (_cwd.isEmpty) return 'workspace';
    final trimmed = _cwd.length > 1 && _cwd.endsWith('/')
        ? _cwd.substring(0, _cwd.length - 1)
        : _cwd;
    final base = trimmed.split('/').last;
    return base.isEmpty || base == '.' ? 'workspace' : base;
  }

  bool get _newWorkspaceImpossible =>
      _workspaceMode == 'new' && _cwd.isNotEmpty && _cwdMatchesExisting;

  @override
  void initState() {
    super.initState();
    _profileId =
        widget.profiles.isNotEmpty ? widget.profiles.first.id : '';
    _cwd = widget.initialCwd ?? '';
    _resolveHomeCwd();
  }

  /// The relay REJECTS an empty cwd ("working directory is required"), so
  /// the picker defaults to the actual home path learned from
  /// `list_directories`. The bare home is not a valid project directory
  /// either (resolveCwd), so launching requires a subdirectory below it.
  Future<void> _resolveHomeCwd() async {
    try {
      final listing = await widget.client.listDirectories('');
      if (mounted && listing.currentPath.isNotEmpty) {
        setState(() {
          _homePath = listing.currentPath;
          // A cwd handed in from history wins: the home path is only the
          // fallback for a cold "New agent".
          if (_cwd.isEmpty) _cwd = listing.currentPath;
        });
      }
    } catch (_) {
      // The picker still works; an empty cwd shows its own launch error.
    }
  }

  /// The bare home is rejected by the relay (resolveCwd: "cwd must be a
  /// project directory below the home directory").
  bool get _cwdIsBareHome => _homePath.isNotEmpty && _cwd == _homePath;

  @override
  void dispose() {
    _nameController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  String _profileLabel(String id) {
    for (final profile in widget.profiles) {
      if (profile.id == id) {
        return profile.label.isNotEmpty ? profile.label : profile.id;
      }
    }
    return id;
  }

  Future<void> _pickDirectory() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => _DirectoryPickerDialog(client: widget.client),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _cwd = selected;
      // Mirror the relay web app: suggest the launch name from the folder.
      if (!_nameTouched) {
        final suggested = _suggestedName(selected);
        if (suggested != null) _nameController.text = suggested;
      }
    });
  }

  /// Sanitized folder basename usable as an agent name, or null when it
  /// cannot start with a lowercase letter (relay pattern).
  static String? _suggestedName(String path) {
    final trimmed = path.length > 1 && path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    final base = trimmed.split('/').last.toLowerCase();
    final sanitized = base.replaceAll(RegExp('[^a-z0-9_-]'), '-');
    if (sanitized.isEmpty || !RegExp('^[a-z]').hasMatch(sanitized)) {
      return null;
    }
    return sanitized;
  }

  /// Explains where the agent will land: the relay groups agents into
  /// workspaces by cwd, creating a new workspace (named after the folder)
  /// when no running agent uses that directory.
  String _workspaceHint() {
    if (_cwdIsBareHome) {
      return 'El relay exige un directorio de proyecto bajo la home: '
          'elige una subcarpeta con el selector.';
    }
    if (_workspaceMode == 'new') {
      if (_newWorkspaceImpossible) {
        return 'Esa carpeta ya tiene agentes: el relay reutilizaría su '
            'workspace. Elige otra carpeta para crear uno nuevo.';
      }
      if (_cwd.isEmpty) {
        return 'Elige una carpeta con el selector para garantizar un '
            'workspace nuevo (la home puede reutilizar uno existente).';
      }
      return 'Se creará el workspace nuevo «$_workspaceLabel».';
    }
    if (_cwd.isEmpty) {
      return 'Automático: el relay agrupa por carpeta (home).';
    }
    return _cwdMatchesExisting
        ? 'Automático: se añadirá al workspace existente de esa carpeta.'
        : 'Automático: se creará el workspace nuevo «$_workspaceLabel».';
  }

  Future<void> _launch() async {
    if (_profileId.isEmpty || _launching) return;
    // The relay requires a non-empty, pattern-valid name AND a cwd.
    final name = _nameController.text.trim();
    final nameError = name.isEmpty
        ? 'El relay exige un nombre'
        : herdrAgentNameError(name);
    if (nameError != null) {
      setState(() => _nameError = nameError);
      return;
    }
    setState(() {
      _launching = true;
      _launchError = null;
    });
    try {
      await widget.client.agentStart(
        profileId: _profileId,
        name: name,
        cwd: _cwd,
        prompt: _promptController.text.trim(),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      // Show inside the sheet: a SnackBar would be hidden behind it.
      setState(() {
        _launching = false;
        _launchError = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          16, 0, 16, MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Nuevo agente', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          if (widget.profiles.isEmpty)
            const Text('El relay no anuncia perfiles de agente')
          else
            DropdownButtonFormField<String>(
              value: _profileId,
              decoration: const InputDecoration(
                labelText: 'Perfil',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final profile in widget.profiles)
                  DropdownMenuItem(
                    value: profile.id,
                    child: Text(_profileLabel(profile.id)),
                  ),
              ],
              onChanged: (value) =>
                  setState(() => _profileId = value ?? _profileId),
            ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _pickDirectory,
            icon: const Icon(Icons.folder_outlined),
            label: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _cwd.isEmpty ? 'Directorio de trabajo (home)' : _cwd,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'auto',
                label: Text('Workspace automático'),
                icon: Icon(Icons.auto_awesome_mosaic_outlined),
              ),
              ButtonSegment(
                value: 'new',
                label: Text('Nuevo workspace'),
                icon: Icon(Icons.create_new_folder_outlined),
              ),
            ],
            selected: {_workspaceMode},
            onSelectionChanged: (selection) =>
                setState(() => _workspaceMode = selection.first),
          ),
          const SizedBox(height: 6),
          Text(
            _workspaceHint(),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: _newWorkspaceImpossible || _cwdIsBareHome
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _nameController,
            decoration: InputDecoration(
              labelText: 'Nombre',
              hintText: 'mi-agente',
              helperText: 'Minúsculas, números, "-" y "_" (obligatorio)',
              errorText: _nameError,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) {
              _nameTouched = true;
              if (_nameError != null) setState(() => _nameError = null);
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _promptController,
            decoration: const InputDecoration(
              labelText: 'Prompt inicial (opcional)',
              border: OutlineInputBorder(),
            ),
            maxLines: 3,
            minLines: 1,
          ),
          const SizedBox(height: 16),
          if (_launchError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _launchError!,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.error),
              ),
            ),
          FilledButton.icon(
            onPressed: _profileId.isEmpty ||
                _launching ||
                _newWorkspaceImpossible ||
                _cwdIsBareHome
                ? null
                : _launch,
            icon: _launching
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.rocket_launch_outlined),
            label: Text(_launching ? 'Lanzando…' : 'Lanzar agente'),
          ),
        ],
      ),
    );
  }
}

/// Directory browser backed by `list_directories`: starts at the home
/// directory, navigates into subdirectories and back to the parent, and
/// returns the selected absolute path.
class _DirectoryPickerDialog extends StatefulWidget {
  const _DirectoryPickerDialog({required this.client});

  final HerdrRelayClient client;

  @override
  State<_DirectoryPickerDialog> createState() => _DirectoryPickerDialogState();
}

class _DirectoryPickerDialogState extends State<_DirectoryPickerDialog> {
  HerdrDirListing? _listing;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load('');
  }

  Future<void> _load(String path) async {
    setState(() {
      _listing = null;
      _error = null;
    });
    try {
      final listing = await widget.client.listDirectories(path);
      if (mounted) setState(() => _listing = listing);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final listing = _listing;
    final error = _error;
    return AlertDialog(
      title: const Text('Elegir directorio'),
      content: SizedBox(
        width: double.maxFinite,
        height: 320,
        child: listing == null
            ? Center(
                child: error != null
                    ? Text(error, textAlign: TextAlign.center)
                    : const CircularProgressIndicator(),
              )
            : Column(
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      listing.currentLabel.isNotEmpty
                          ? listing.currentLabel
                          : listing.currentPath,
                      style: Theme.of(context).textTheme.labelLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Divider(),
                  Expanded(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        if (listing.parent.isNotEmpty)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.arrow_upward),
                            title: const Text('..'),
                            onTap: () => _load(listing.parent),
                          ),
                        for (final dir in listing.directories)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.folder_outlined),
                            title: Text(dir.name),
                            onTap: () => _load(dir.path),
                          ),
                        if (listing.directories.isEmpty &&
                            listing.parent.isEmpty)
                          const ListTile(
                            dense: true,
                            title: Text('Sin subdirectorios'),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: listing == null
              ? null
              : () => Navigator.pop(context, listing.currentPath),
          child: const Text('Seleccionar'),
        ),
      ],
    );
  }
}

/// Fuzzy search over all known agents and workspaces: live subsequence
/// matching (see herdr_fuzzy.dart) ranked by score and recency; Enter opens
/// the top result, tap opens any of them.
/// What the search sheet hands back: either a live agent to open, or a
/// remembered [cwd] with nothing running in it (start an agent there).
class _SearchSelection {
  const _SearchSelection.agent(HerdrAgent this.agent) : cwd = null;
  const _SearchSelection.cwd(String this.cwd) : agent = null;

  final HerdrAgent? agent;
  final String? cwd;
}

/// Global search: live agents and persisted history in one list, with the
/// history grouped by date while the query is empty.
///
/// Everything is one tap away — no tab bar and no mode switch — which is the
/// point of a Raycast-style palette on a phone.
class _SearchSheet extends StatefulWidget {
  const _SearchSheet({
    required this.agents,
    required this.history,
    required this.onHistoryChanged,
  });

  final List<HerdrAgent> agents;
  final HerdrHistory history;

  /// Called after a pin/remove so the caller can persist.
  final VoidCallback onHistoryChanged;

  @override
  State<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<_SearchSheet> {
  final TextEditingController _queryController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  /// Live agents first, then history rows that are not already represented
  /// (see herdr_search.dart for the dedup rules).
  List<HerdrSearchRow> get _rows => herdrSearchRows(
        agents: widget.agents,
        history: widget.history.entries,
      );

  List<HerdrFuzzyResult<HerdrSearchRow>> get _results => herdrFuzzyFilter(
        _query,
        _rows,
        (row) => row.haystack,
        (row) => row.sortAt,
        maxResults: 30,
        // Typo tolerance only matters where the user is typing a half-
        // remembered name; exact matches still rank first (herdrTypoPenalty).
        allowTypo: true,
      );

  void _select(HerdrSearchRow row) {
    final agent = row.agent;
    if (agent != null) {
      Navigator.pop(context, _SearchSelection.agent(agent));
      return;
    }
    final cwd = row.entry?.cwd ?? '';
    if (cwd.isNotEmpty) Navigator.pop(context, _SearchSelection.cwd(cwd));
  }

  void _togglePin(HerdrHistoryEntry entry) {
    setState(() => widget.history.togglePin(entry.key));
    widget.onHistoryChanged();
  }

  void _remove(HerdrHistoryEntry entry) {
    setState(() => widget.history.remove(entry.key));
    widget.onHistoryChanged();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          16, 0, 16, MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _queryController,
            autofocus: true,
            decoration: InputDecoration(
              hintText: 'Buscar agente, workspace, proyecto…',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      tooltip: 'Limpiar',
                      onPressed: () {
                        _queryController.clear();
                        setState(() => _query = '');
                      },
                    ),
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            textInputAction: TextInputAction.go,
            onChanged: (value) => setState(() => _query = value),
            onSubmitted: (_) {
              final results = _results;
              if (results.isNotEmpty) _select(results.first.item);
            },
          ),
          const SizedBox(height: 8),
          Flexible(
            child: _query.isEmpty ? _buildHistoryView() : _buildResultsView(),
          ),
        ],
      ),
    );
  }

  /// Empty query: live agents on top, then history grouped by date.
  Widget _buildHistoryView() {
    final groups = widget.history.grouped(DateTime.now());
    final live = _rows.where((r) => r.isLive && r.entry == null).toList();

    if (groups.isEmpty && live.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'Todavía no hay historial.\nAbre un agente y aparecerá aquí.',
          textAlign: TextAlign.center,
        ),
      );
    }

    return ListView(
      shrinkWrap: true,
      children: [
        if (live.isNotEmpty) ...[
          _sectionHeader('En marcha'),
          for (final row in live) _liveTile(row),
        ],
        for (final group in groups) ...[
          _sectionHeader(group.title),
          for (final entry in group.entries) _historyTile(entry),
        ],
      ],
    );
  }

  Widget _buildResultsView() {
    final results = _results;
    if (results.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text('Sin resultados'),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: results.length,
      itemBuilder: (context, index) {
        final row = results[index].item;
        final entry = row.entry;
        return entry == null ? _liveTile(row) : _historyTile(entry);
      },
    );
  }

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
        child: Text(
          title.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                letterSpacing: 1.1,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).hintColor,
              ),
        ),
      );

  Widget _liveTile(HerdrSearchRow row) => ListTile(
        dense: true,
        leading: _StatusIcon(status: row.agent?.status ?? ''),
        title:
            Text(row.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: row.subtitle.isEmpty
            ? null
            : Text(row.subtitle,
                maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: () => _select(row),
      );

  /// History row: swipe away to forget, long-press or tap the star to pin.
  /// A remembered entry whose agent is running again shows its live status
  /// instead of the history icon.
  Widget _historyTile(HerdrHistoryEntry entry) {
    final live = herdrLiveAgentFor(entry, widget.agents);
    final row = HerdrSearchRow(
      title: entry.label,
      subtitle: entry.subtitle,
      haystack: entry.haystack,
      sortAt: entry.lastOpenedAt,
      agent: live,
      entry: entry,
    );
    return Dismissible(
      key: ValueKey(entry.key),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: Theme.of(context).colorScheme.errorContainer,
        child: const Icon(Icons.delete_outline),
      ),
      onDismissed: (_) => _remove(entry),
      child: ListTile(
        dense: true,
        leading: live != null
            ? _StatusIcon(status: live.status)
            : Icon(
                entry.kind == HerdrHistoryKind.workspace
                    ? Icons.folder_outlined
                    : Icons.history,
                size: 18,
                color: Theme.of(context).hintColor,
              ),
        title: Text(entry.label,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: entry.subtitle.isEmpty
            ? null
            : Text(entry.subtitle,
                maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: IconButton(
          icon: Icon(entry.pinned ? Icons.star : Icons.star_border, size: 20),
          tooltip: entry.pinned ? 'Quitar de fijados' : 'Fijar',
          onPressed: () => _togglePin(entry),
        ),
        onTap: () => _select(row),
        onLongPress: () => _togglePin(entry),
      ),
    );
  }
}
