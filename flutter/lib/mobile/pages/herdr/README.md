# herdr — native agent-control UI (mobile)

Self-contained feature of this fork: control [herdr](https://herdr.dev) agents
running on the connected host, from the Android client. Everything lives in
this directory plus one button and one import in `../remote_page.dart` (search
for `herdr` there), plus a two-spot Rust patch to enable client-side
port-forwarding on mobile (see "Merge notes" below).

## Architecture

```
remote_page.dart (🤖 button)
  └─▶ herdr_home_page.dart        collapsible workspaces, agent cards,
        │                         rename/restart/stop, create-agent sheet
        │                         (profile + cwd picker + optional prompt)
        ├─▶ herdr_connection_manager.dart
        │     second FFI session per peer (isPortForward, fresh UUID —
        │     same pattern as ../../desktop/pages/terminal_connection_manager.dart)
        │     + sessionAddPortForward(18375 → 127.0.0.1:8375)
        ├─▶ herdr_history.dart + herdr_history_store.dart
        │     recientes/fijados: lógica pura | persistencia en local-options
        └─▶ herdr_agent_page.dart pane text + composer + special-keys bar
              │                   + approvals + adaptive polling
              ├─▶ herdr_reading_view.dart    pane as wrapped, coloured text
              ├─▶ herdr_ansi_text.dart       ANSI SGR -> styled spans
              ├─▶ herdr_name_dialog.dart  shared rename dialog (validated)
              └─▶ herdr_relay_client.dart
                    WebSocket ws://127.0.0.1:18375/ws  ──tunnel──▶  herdr-mobile-relay
                    (JSON protocol v2, see contracts/fixtures/ in the relay repo)
```

- **The tunnel's lifetime is the REMOTE SESSION's, not the herdr page's.**
  `HerdrConnectionManager` owns both the port-forward FFI session and the
  `HerdrRelayClient`, keyed by peer, and hands the same live client to every
  entry into the herdr UI. Popping the herdr screen only cancels that page's
  stream subscriptions. `remote_page.dart`'s `dispose` is the single place
  that calls `HerdrConnectionManager.close()`.
  Why: tearing the stack down on every pop meant re-entry paid the whole
  setup again — register forward, probe with retries, WebSocket handshake,
  re-fetch agents — seconds of "Conectando…" each time, with in-flight
  commands lost. Now re-entry is instant and the connection survives
  navigation. On re-entry the page seeds its list from
  `client.currentAgents` and calls `refreshAgents()`; it must NOT call
  `connect()` again, which would leak the live WebSocket.
  `_openTunnel` is private so a tunnel can never exist without the client
  that owns it; "Reintentar" passes `force: true` to rebuild the whole stack.
- The relay runs on the host at `127.0.0.1:8375` without a token: the only
  path to it is this tunnel, and anyone who can open it already has full
  RustDesk access to the host.
- Protocol reference: `internal/protocol/protocol.go` and
  `contracts/fixtures/{inbound,outbound}/*.json` in
  <https://github.com/0cv/herdr-mobile-relay>. Mutating messages require
  `"protocol": 2`. There is no streaming: the page polls `read_pane`, and the
  answer always carries the WHOLE scrollback — `lines`, `limit` and `source`
  are all ignored by the relay (verified against 0.10.6), so the client trims
  the tail itself (`herdrTailLines`).

## Features

- **Home**: agents grouped in collapsible workspaces (with blocked counters),
  status icon + color (working / idle / blocked), pull-to-refresh, reconnect
  banner, fuzzy search (lupa) over workspaces/agents ranked by score and
  recency (`herdr_fuzzy.dart`), and a *New agent* FAB.
- **Quota strip** (`herdr_quota.dart`): a second port-forward
  (18378 → host 127.0.0.1:8378, same DIRECT proxy bypass) exposes the
  host's aiuse `usage.json`; the home shows one chip per provider with its
  worst (lowest-remaining) window, colored green/amber/red, refreshed on
  open and every 5 min. Any failure hides the strip silently.
- **Agent lifecycle**: rename (`agent_rename`), restart (`agent_restart`),
  stop (`agent_stop`, with confirmation) and clear (`agent_clear`) from the
  home overflow menu or the agent page appbar menu. Names are validated
  client-side against the relay's own pattern (`^[a-z][a-z0-9_-]{0,31}$`,
  see `herdrAgentNameError`).
- **Create agent**: bottom sheet with profile selector (from
  `push_config.agent_profiles`), a cwd picker driven by `list_directories`
  (confined to the host home), and an optional initial prompt
  (`agent_start`). The relay REQUIRES a non-empty name (matching
  `^[a-z][a-z0-9_-]{0,31}$`, validated inline) and a non-empty cwd, so the
  sheet resolves the actual home path as the default and reports launch
  errors inside the sheet (a SnackBar would be hidden behind it). A
  workspace selector exposes the relay's grouping rule (`SelectWorkspaceForCwd`): "Automático" previews the destination
  (join the workspace of a matching cwd, or create one named after the
  folder); "Nuevo workspace" refuses to launch when the cwd already has
  agents, which is the only way to GUARANTEE a fresh workspace — the
  protocol has no force-new flag.
- **Pane view** (`herdr_reading_view.dart`): `read_pane` polling is adaptive —
  1.5 s while the agent is working/blocked or the pane keeps changing, backing
  off to 8 s when static and idle, paused entirely while the app is
  backgrounded (`WidgetsBindingObserver`). The pane is rendered as WRAPPED
  TEXT, not as a terminal: a herdr pane is desktop-wide (181 columns measured)
  and a phone is ~360 logical pixels, so a faithful terminal can only ever be
  legible-and-panned or complete-and-unreadable. Decoration is filtered
  (separator rules, spinners, the agent's own prompt box and status bar) and
  the rest is coloured from its ANSI by `herdr_ansi_text.dart`. Same approach
  `dcolinmorgan/herdr-remote` takes for its phone UI.
  Backgrounds are dropped on purpose: Claude Code paints full-width blocks
  behind its boxes and once the text is re-wrapped they land on the wrong
  cells. The filters match on the SHAPE of a line, never on the words in it —
  matching bare phrases silently ate a diff line that merely mentioned one.
- **Special-keys bar**: Termux-style extra keys with sticky CTRL/ALT/SHIFT
  modifiers (`herdr_keymap.dart`): tap cycles off → armed → locked → off,
  one-shot modifiers apply to the next key only. Ctrl+letter sends the
  control byte (\x01-\x1a, so Ctrl+C is \x03), Ctrl/Alt/Shift+arrows,
  Home/End and PageUp/PageDown send the matching xterm modifier sequences
  (\x1b[1;<param>X, \x1b[<n>;<param>~), Alt+char sends ESC+char, Shift+Tab
  is backtab. The prompt field honors armed modifiers for both hardware
  keys and IME commits (a committed 'c' with CTRL armed becomes \x03).
  The bar is the SHARED widget `common/widgets/terminal_extra_keys.dart`, the
  same one the inline terminal panel uses: one scrolling row, caps that never
  take focus and hand it back afterwards (otherwise the soft keyboard closes
  and an armed modifier has no next key), F1-F12 behind a `fn` cap.
  Layout note: the Scaffold must NOT resize for the keyboard
  (`resizeToAvoidBottomInset: false`); the column is padded by the measured
  keyboard height instead. Letting it resize re-laid out the page mid-IME
  animation, focus was lost and Android cancelled the keyboard outright, so
  nothing could be typed at all.
  Note: the remote session disables the soft keyboard globally, so the home
  page re-enables it on entry (`enable_soft_keyboard`) and restores it on
  dispose.
- **Hardware keyboard**: the composer forwards only Escape/Tab/arrows to the
  agent and lets everything else reach the TextField. It used to intercept
  printable characters, Enter and Backspace too — a workaround for physical
  keyboards that ate the soft keyboard's IME commits, so the composer accepted
  nothing at all on a phone.
- **Approvals**: when the agent blocks, a banner offers the relay-provided
  options (`respond`) or a structured question form (`answer_question` /
  `navigate_question`).
- **Slash commands**: the agent page loads the `list_slash_commands`
  catalog once; when non-empty, a "/" button (or typing "/" in the prompt
  field) opens a fuzzy-filtered picker that leaves the command in the
  prompt for arguments. Agents without a catalog hide the button.
- **History + global search** (`herdr_history.dart`, `herdr_history_store.dart`):
  the search button opens one palette over BOTH live agents and persisted
  history. Empty query shows "En marcha" followed by history grouped by date
  (Fijados / Hoy / Ayer / Esta semana / Este mes / Hace tiempo); typing runs a
  single fuzzy pass over everything. Swipe a history row to forget it, tap or
  long-press the star to pin (pinned rows are never pruned). Opening an agent
  records two entries — the agent and its cwd — because agents are transient
  across restarts while the directory is not; tapping a remembered directory
  with nothing running opens the create-agent sheet pre-filled with it.
  Persistence is the core's local options under the `herdr-history` key (the
  `ab_model`/`printer_model` mechanism), so no new pubspec dependency. The
  store caps unpinned entries at 60 and never throws: a corrupt payload
  decodes to an empty history and one bad row does not discard the good ones.
  Only two kinds exist (`agent`, `workspace`) because the relay has only two
  things worth remembering: an agent IS its session, and a workspace IS its
  project cwd.
- **Fuzzy typo tolerance** (`herdr_fuzzy.dart`): `allowTypo` retries a failed
  match once per position with that character dropped, which covers the common
  typo classes (extra char, wrong char, transposition) without an edit-distance
  table. Results are penalised by `herdrTypoPenalty` so an exact match always
  ranks first, and queries under 4 characters stay strict — at 1-3 characters a
  typo budget matches nearly everything.
- **The composer is the only input**, and there is no mode to switch. See
  "Why there is no keystroke mode" below.
- **Not available — subscription quota over the relay**: the relay protocol
  exposes no usage/quota message (the only `subscription` field in
  `protocol.go` is the web-push subscription). The quota strip therefore does
  NOT come from the relay: it uses a second port-forward to the host's own
  aiuse HTTP service (see **Quota strip** above).

## Why there is no keystroke mode

There used to be a faithful xterm view with per-key input, mirroring the inline
terminal. It was removed: over this transport every keystroke is a round trip
to the host plus a `read_pane` answer carrying the whole scrollback (measured
at 876 KB — the relay ignores `lines`, `limit` AND `source` alike), so there is
no local echo and the letters land late. The composer shows what you type
immediately and sends it in one go, which is simply better here. Removing the
mode also removed a class of bugs: switching between the two left neither
surface holding focus and typing stopped working entirely.

`../../desktop/pages/inline_terminal_panel.dart` remains the right tool when
you want a real terminal on the host — it is a live PTY, not a poller.


## Merge notes (upstream rustdesk)

- Upstream-touching Flutter diff is intentionally tiny: in `remote_page.dart`
  two imports, one method, one `IconButton` and one line in `dispose`
  (`HerdrConnectionManager.close`), plus `web_socket_channel` and the version
  line in `pubspec.yaml`. Everything else is this directory and the
  `test/herdr_*_test.dart` files (+ `test/fixtures/herdr/`).
- One **Rust patch** was unavoidable: upstream compiles the whole client-side
  port-forward out on Android/iOS (`#[cfg(not(any(target_os = "android",
  target_os = "ios")))]`). The patch has two parts: in `src/lib.rs` we enable
  `mod port_forward` on mobile (the module itself, `src/port_forward.rs`, has
  no platform cfgs and compiles as-is — only `run_rdp` is unreachable there),
  and in `src/ui_session_interface.rs` we enable `start_one_port_forward` and
  the tunnel branch of `io_loop` on mobile (RDP stays desktop-only). Both are
  minimal, upstreamable changes — candidate for a PR ("enable TCP tunneling
  on mobile clients").
  **Symptom when missing**: without the `io_loop` branch the port-forward
  session falls through to the generic `Remote::io_loop`, which logs in with
  `PortForward{host: "", port: 0}`; the host then fails with
  `Failed to access remote localhost:0`. And without the `lib.rs` change the
  Android build breaks (`crate::port_forward` unresolved) — invisible to a
  host-only `cargo check`, so verify with
  `cargo ndk --platform 21 --target aarch64-linux-android check --features flutter,hwcodec`.
- `herdr_connection_manager.dart` does not wait for peer info before calling
  `sessionAddPortForward`: a port-forward session has no initial host
  connection, so that signal never arrives. It registers the forward right
  away and uses the relay probe (with retries) as the readiness check.
- When merging upstream, re-apply conflicts only in those four files
  (`remote_page.dart`, `pubspec.yaml`, `src/lib.rs`,
  `src/ui_session_interface.rs`); the herdr directory is self-contained.

## Build

Use Flutter 3.24.5 (NOT the snap 3.44.2) and the local Android SDK.

**IMPORTANT — the Rust core is NOT rebuilt by `flutter build apk`.** Gradle
just packages `flutter/android/app/src/main/jniLibs/arm64-v8a/librustdesk.so`
as-is, so after touching `src/` you MUST rebuild it manually first AND put it
in jniLibs, or the APK will silently ship the stale library:

```bash
cd rustdesk   # repo root
ANDROID_NDK_HOME=/home/hyt/android-ndk-r28c VCPKG_ROOT=/home/hyt/vcpkg \
  cargo ndk --platform 21 --target aarch64-linux-android build --release --features flutter
cp target/aarch64-linux-android/release/liblibrustdesk.so \
  flutter/android/app/src/main/jniLibs/arm64-v8a/librustdesk.so
# sanity check that your change is really in the .so:
strings flutter/android/app/src/main/jniLibs/arm64-v8a/librustdesk.so | grep -F "port forward ("

cd flutter
/home/hyt/flutter-3.24.5/bin/flutter build apk --release --split-per-abi \
  --target-platform android-arm64   # sdk.dir=/home/hyt/android-sdk (local.properties)
```
