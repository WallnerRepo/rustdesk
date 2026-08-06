import 'dart:async';
import 'dart:io';


import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';
import '../../../models/model.dart';
import '../../../models/platform_model.dart';
import 'herdr_relay_client.dart';

/// Manages the TCP tunnel to the herdr relay running on the remote host.
///
/// One tunnel per peer: a dedicated port-forward FFI session plus a local
/// listener on 127.0.0.1:[kLocalPort] that reaches
/// 127.0.0.1:[kRemotePort] on the host, where `herdr-mobile-relay serve`
/// listens (loopback only, no token — whoever can open the tunnel already
/// has full RustDesk access to the host).
class HerdrConnectionManager {
  static const int kLocalPort = 18375;
  static const String kRemoteHost = '127.0.0.1';
  static const int kRemotePort = 8375;
  static const String kLocalUrl = 'http://127.0.0.1:$kLocalPort/';

  /// Second forward for the aiuse quota service on the host (serves
  /// ~/.cache/aiuse/usage.json over plain HTTP, loopback only).
  static const int kQuotaLocalPort = 18378;
  static const int kQuotaRemotePort = 8378;
  static const String kQuotaLocalUrl =
      'http://127.0.0.1:$kQuotaLocalPort/usage.json';

  /// Third forward for the host's directory list (zoxide, served by
  /// herdr-dirs-http.socket on loopback).
  ///
  /// The relay's `list_directories` takes a path and nothing else — no query,
  /// no recursion — so the picker could only walk one level at a time. zoxide
  /// already ranks the directories worth offering on this host, so the picker
  /// reads that instead of crawling the filesystem over the tunnel.
  static const int kDirsLocalPort = 18379;
  static const int kDirsRemotePort = 8379;
  static const String kDirsLocalUrl = 'http://127.0.0.1:$kDirsLocalPort/dirs';

  static final Map<String, FFI> _connections = {};

  /// Relay clients, one per peer, owned HERE rather than by the herdr page.
  ///
  /// The tunnel and its WebSocket are tied to the REMOTE SESSION, not to the
  /// herdr screen: leaving the herdr UI used to tear both down, so coming
  /// back paid the full tunnel setup again (register forward, probe with
  /// retries, WebSocket handshake, re-fetch the agent list) — seconds of
  /// "Conectando…" every time, and any in-flight command was lost. Keeping
  /// them alive makes re-entry instant and the connection stable across
  /// navigation, which is what the floating/always-connected behaviour needs.
  ///
  /// Teardown happens exactly once, when the remote session itself closes
  /// (`remote_page.dart` dispose → [close]).
  static final Map<String, HerdrRelayClient> _clients = {};

  /// Bumped by every [close]. Opening a tunnel takes seconds (register the
  /// forward, probe with retries), and the remote session can end inside that
  /// window: without this the finished tunnel would be registered AFTER the
  /// teardown that was supposed to remove it, orphaning a native session that
  /// nothing ever closes.
  static final Map<String, int> _epoch = {};

  /// In-flight [close] calls, one per peer.
  ///
  /// Teardown is ASYNCHRONOUS all the way down: `ffi.close()` returns a Future
  /// and the native `sessionClose` behind it takes a while to drop the io_loop.
  /// Re-opening before that finished used to corrupt the native session table:
  /// `sessions::insert_session` inserts with `entry().or_insert()`, so the NEW
  /// Session is silently DISCARDED and the new UUID is attached as a handler of
  /// the DYING one — no io_loop is ever spawned for it. Worse, the pending
  /// `sessionClose(oldUuid)` then finds a non-empty handler map and removes
  /// nothing, so the old io_loop and its 127.0.0.1:[kLocalPort] listener leak
  /// for the lifetime of the process.
  ///
  /// Every path that creates an FFI therefore waits here first.
  static final Map<String, Future<void>> _closing = {};

  /// Await any teardown still running for [peerId] (see [_closing]).
  static Future<void> _awaitPendingClose(String peerId) async {
    // Bounded loop: a close scheduled while we were awaiting the previous one
    // has to be drained too, but we must never spin.
    var guard = 0;
    while (guard++ < 4) {
      final pending = _closing[peerId];
      if (pending == null) return;
      try {
        await pending;
      } catch (_) {
        // A failed teardown still means the session is gone as far as we are
        // concerned; the point of waiting is the ordering, not the result.
      }
    }
  }

  /// Enforce AT MOST ONE herdr tunnel at a time, across peers.
  ///
  /// The local ports are compile-time constants ([kLocalPort] and friends) and
  /// RustDesk's TCP listener sets SO_REUSEPORT on unix
  /// (`libs/hbb_common/src/tcp.rs`), so two tunnels to DIFFERENT peers would
  /// both successfully bind 127.0.0.1:[kLocalPort] and the kernel would
  /// round-robin incoming connections between them: a command could land on
  /// the wrong machine, and [_probeRelay] cannot detect it because BOTH
  /// listeners answer. Per-peer ports are the real fix; until then the second
  /// peer's tunnel replaces the first instead of racing it.
  static Future<void> _closeOtherPeers(String peerId) async {
    final others = <String>{
      ..._connections.keys,
      ..._clients.keys,
    }..remove(peerId);
    for (final other in others) {
      debugPrint('[HerdrConnectionManager] closing tunnel for $other: only one'
          ' herdr tunnel can own 127.0.0.1:$kLocalPort');
      await close(other);
    }
  }

  /// Open the tunnel to [peerId]. Returns the local port the herdr app is
  /// reachable on. Throws if the session can't be established or the relay
  /// doesn't answer on the remote side.
  ///
  /// Private on purpose: every caller must go through [client], so a tunnel
  /// can never exist without the relay client that owns its lifetime.
  static Future<int> _openTunnel({
    required String peerId,
    String? password,
    bool? isSharedPassword,
    bool? forceRelay,
  }) async {
    await _closeOtherPeers(peerId);
    await _awaitPendingClose(peerId);
    final existing = _connections[peerId];
    if (existing != null && !existing.closed) {
      debugPrint(
          '[HerdrConnectionManager] Reusing existing tunnel for peer $peerId');
      // Re-arm and probe even on the reuse path. "Alive" is not "working": the
      // TimeoutException branch below KEEPS the session on purpose, so the very
      // next attempt lands here — and returning [kLocalPort] straight away
      // meant no forward was ever re-registered and nothing was ever probed, so
      // a cold tunnel that timed out once stayed broken forever while the UI
      // reported success. Costs one loopback GET when the tunnel is warm.
      await _ensureTunnel(existing);
      return kLocalPort;
    }

    // IMPORTANT: pass a fresh SessionID. On mobile FFI(null) reuses a shared
    // constant SessionID, which would collide with the active video session's
    // FFI (same pitfall as TerminalConnectionManager, see its comment).
    debugPrint(
        '[HerdrConnectionManager] Creating new tunnel connection for peer $peerId');
    final ffi = FFI(const Uuid().v4obj());
    // Track the connection BEFORE start() so a throw can't leave an orphaned,
    // half-started native session that nothing ever closes.
    _connections[peerId] = ffi;
    Get.put<FFI>(ffi, tag: 'herdr_$peerId');
    try {
      ffi.start(
        peerId,
        password: password,
        isSharedPassword: isSharedPassword,
        forceRelay: forceRelay,
          isPortForward: true,
      );
      // Do NOT wait for peer info here: a port-forward session has no
      // initial host connection at all. The native io_loop only opens a
      // local listener once sessionAddPortForward registers the forward,
      // and only dials kRemoteHost:kRemotePort when a client connects to
      // the local port — so there is no "ready" signal to wait for.
      // Register the forward and let the probe (with retries) be the
      // readiness check.
      await _ensureTunnel(ffi);
      return kLocalPort;
    } on TimeoutException {
      // KEEP the session. It is not broken, just not converged yet: the peer
      // handshake carries on in the background and is usually ready seconds
      // later. Closing it here meant every retry restarted the whole
      // rendezvous from zero, which is why the first open failed and the user
      // had to try three or four times.
      debugPrint('[HerdrConnectionManager] tunnel for $peerId still converging;'
          ' keeping the session so a retry can reuse it');
      rethrow;
    } catch (e) {
      debugPrint('[HerdrConnectionManager] open failed for $peerId: $e');
      // Remove BY IDENTITY, never by key. This path runs after several awaits,
      // long enough for a newer open to have installed its own FFI under the
      // same key and the same Get tag: a blind `remove(peerId)` +
      // `Get.delete(tag:)` would deregister the NEWER session and orphan its
      // tunnel (native session and local listener still up, nothing tracking
      // them). Same pattern as the [_opening] cleanup below.
      if (identical(_connections[peerId], ffi)) {
        _connections.remove(peerId);
        Get.delete<FFI>(tag: 'herdr_$peerId', force: true);
      }
      await ffi.close();
      rethrow;
    }
  }

  /// The live relay client for [peerId], opening the tunnel and connecting
  /// the WebSocket on first use and REUSING both afterwards.
  ///
  /// The returned client may already be connected and holding a full agent
  /// snapshot ([HerdrRelayClient.currentAgents]) — callers should seed their
  /// UI from it instead of waiting for the next push.
  /// In-flight `client()` calls, so overlapping callers share one build.
  ///
  /// Without this, two calls that raced (the herdr page connecting while the
  /// quota strip fetches, or a double tap on the robot button) both ran the
  /// whole path and both assigned `_clients[peerId]`. The loser was dropped
  /// WITHOUT close(), leaving an orphan WebSocket reconnecting every 15s for
  /// the lifetime of the process.
  static final Map<String, Future<HerdrRelayClient>> _opening = {};

  static Future<HerdrRelayClient> client({
    required String peerId,
    String? password,
    bool? isSharedPassword,
    bool? forceRelay,
  }) {
    final inFlight = _opening[peerId];
    if (inFlight != null) return inFlight;
    final future = _client(
      peerId: peerId,
      password: password,
      isSharedPassword: isSharedPassword,
      forceRelay: forceRelay,
    );
    _opening[peerId] = future;
    return future.whenComplete(() {
      if (identical(_opening[peerId], future)) _opening.remove(peerId);
    });
  }

  static Future<HerdrRelayClient> _client({
    required String peerId,
    String? password,
    bool? isSharedPassword,
    bool? forceRelay,
  }) async {
    // Before looking at (let alone building) this peer's stack: drop any tunnel
    // belonging to a DIFFERENT peer (see [_closeOtherPeers] — the loopback
    // ports are shared and SO_REUSEPORT makes the collision silent), and let
    // any teardown of THIS peer finish (see [_closing]).
    await _closeOtherPeers(peerId);
    await _awaitPendingClose(peerId);
    final existing = _clients[peerId];
    if (existing != null && !existing.isClosed && hasConnection(peerId)) {
      // `ffi.closed` is not enough. The port-forward session can die with the
      // peer connection (a RustDesk auto-reconnect gives a NEW session) while
      // this FFI object still reports open — reusing it would leave the client
      // retrying forever against a local port with nothing behind it. Probing
      // costs one loopback GET when healthy and is the only honest liveness
      // check we have.
      try {
        await _probeRelay();
        // The probe is an await: a close() can land inside it, which would
        // otherwise hand back a client that never reconnects.
        if (!existing.isClosed && identical(_clients[peerId], existing)) {
          debugPrint(
              '[HerdrConnectionManager] Reusing relay client for $peerId');
          return existing;
        }
      } catch (e) {
        // The cached tunnel really is dead (nothing answers on the local
        // port), so tear the whole stack down before rebuilding it.
        debugPrint(
            '[HerdrConnectionManager] Cached tunnel for $peerId is dead ($e); rebuilding');
        await close(peerId);
      }
    }
    // Drop a stale client but KEEP the tunnel session: _openTunnel reuses a
    // live one, and a session that timed out is usually still converging.
    // Closing it here defeated the whole point of keeping it — every retry
    // restarted the peer rendezvous from zero.
    _clients.remove(peerId)?.close();

    final epoch = _epoch[peerId] ?? 0;
    final port = await _openTunnel(
      peerId: peerId,
      password: password,
      isSharedPassword: isSharedPassword,
      forceRelay: forceRelay,
    );
    if ((_epoch[peerId] ?? 0) != epoch) {
      // close() landed while the tunnel was coming up. Do not resurrect it:
      // tear down what _openTunnel just built and let the caller fail.
      await close(peerId);
      throw StateError('herdr: la sesión se cerró mientras se conectaba');
    }
    final client = HerdrRelayClient(port: port);
    _clients[peerId] = client;
    // Deliberately NOT awaited. `connect()` awaits `channel.ready`, which has
    // no timeout: if the tunnel accepts the TCP connection but the relay never
    // completes the WebSocket upgrade, awaiting it pins the caller forever —
    // the herdr page sat on "Conectando…" until it gave up. It also never
    // throws (it catches and schedules its own backoff retry), so there is
    // nothing to await for error handling either.
    //
    // The readiness gate is the tunnel probe inside [_openTunnel]; the socket
    // state reaches the UI through `connectionState`, which drives the
    // reconnect banner.
    unawaited(client.connect());
    return client;
  }

  /// Close the tunnel, its relay client and the FFI session.
  ///
  /// Call this when the REMOTE SESSION ends, not when the herdr screen is
  /// popped — see [_clients].
  ///
  /// The returned Future completes only once the native session is really
  /// gone; whoever re-opens afterwards MUST await it (see [_closing]).
  static Future<void> close(String peerId) {
    // Overlapping closes share one teardown instead of racing it (dispose +
    // an explicit close, or the rebuild path inside [_client]).
    final inFlight = _closing[peerId];
    if (inFlight != null) return inFlight;
    final future = _close(peerId);
    _closing[peerId] = future;
    return future.whenComplete(() {
      if (identical(_closing[peerId], future)) _closing.remove(peerId);
    });
  }

  static Future<void> _close(String peerId) async {
    // Invalidate any tunnel still being opened for this peer (see [_epoch]).
    _epoch[peerId] = (_epoch[peerId] ?? 0) + 1;
    _clients.remove(peerId)?.close();
    final ffi = _connections.remove(peerId);
    if (ffi == null) return;
    debugPrint('[HerdrConnectionManager] Closing tunnel for peer $peerId');
    if (!ffi.closed) {
      // ALL THREE forwards, independently. This used to drop only kLocalPort
      // and kQuotaLocalPort, leaving kDirsLocalPort behind — and RustDesk
      // PERSISTS forwards into the on-disk PeerConfig, so the leftover showed
      // up as a phantom row in the desktop Port Forward UI, was replayed on
      // every future port-forward session to this peer, and made a later
      // sessionAddPortForward for that port a silent no-op (the native side
      // dedups against the saved config and returns without sending anything).
      // One try per port so a failure on the first cannot skip the rest.
      for (final localPort in const [
        kLocalPort,
        kQuotaLocalPort,
        kDirsLocalPort
      ]) {
        try {
          await bind.sessionRemovePortForward(
              sessionId: ffi.sessionId, localPort: localPort);
        } catch (e) {
          debugPrint(
              '[HerdrConnectionManager] removePortForward($localPort) failed: $e');
        }
      }
    }
    // The awaits above are three native round-trips: a fresh open can have
    // installed a NEW session under the same Get tag meanwhile (its `Get.put`
    // already replaced ours). Only deregister the tag when the slot is still
    // empty, otherwise this teardown would pull the new session's registration
    // out from under it.
    if (_connections[peerId] == null) {
      Get.delete<FFI>(tag: 'herdr_$peerId', force: true);
    }
    // AWAITED: see [_closing]. Returning before the native session is gone is
    // what let a re-open collide with the dying one and leak its io_loop.
    //
    // Guarded because this future is now what everyone waits on: callers use
    // `unawaited(close(id))` (remote_page's dispose), so letting it complete
    // with an error would surface as an unhandled async error instead of a
    // logged teardown hiccup.
    try {
      await ffi.close();
    } catch (e) {
      debugPrint('[HerdrConnectionManager] ffi.close failed for $peerId: $e');
    }
  }

  static bool hasConnection(String peerId) {
    final ffi = _connections[peerId];
    return ffi != null && !ffi.closed;
  }

  /// Registers the local forward and verifies end-to-end connectivity,
  /// retrying until the native listener and the host relay both answer.
  ///
  /// The probe doubles as the readiness check: it fails while the local
  /// listener is not up yet (the native io_loop starts asynchronously) and
  /// also when the host doesn't run the relay — the tunnel only dials
  /// kRemoteHost:kRemotePort once a client connects, so without this probe
  /// a missing relay would surface as an opaque WebView load error later.
  static Future<void> _ensureTunnel(FFI ffi) async {
    // A COLD tunnel is slow: this is a second, independent session that has to
    // do its own rendezvous and handshake with the peer, even though the video
    // session is already up. Measured on device: 20s when it succeeds, and
    // >30s often enough that the old 30s budget failed the FIRST open almost
    // every time while every later attempt (warm session) looked instant.
    final deadline = DateTime.now().add(const Duration(seconds: 75));
    Object? lastError;
    DateTime? lastRearm;
    while (!ffi.closed && DateTime.now().isBefore(deadline)) {
      // Register ONCE, then re-arm only occasionally.
      //
      // This used to remove+add on every attempt, i.e. ~60 times in 30s. The
      // AddPortForward message is dropped if the io_loop has not installed its
      // channel sender yet, so a re-arm is needed — but doing it every 500ms
      // tore down a forward that was still being established, so a cold tunnel
      // could never finish converging inside the budget.
      //
      // The re-arm is paced by ELAPSED TIME, not by attempt count. Attempts
      // cost wildly different amounts: a refused connect returns in ~0ms, while
      // a peer leg that is still converging stalls the probe for its full 5s
      // timeout. Counting attempts meant "every 10th" landed after ~5s in the
      // refused regime but only after ~55s in the stalled one — i.e. never,
      // inside a 75s budget, which is exactly the case that needs the re-arm.
      if (lastRearm == null ||
          DateTime.now().difference(lastRearm) >= _rearmInterval) {
        await _registerForwards(ffi);
        // Measured from when the re-arm FINISHED, so a slow round-trip cannot
        // trigger the next one immediately.
        lastRearm = DateTime.now();
      }
      try {
        await _probeRelay();
        return;
      } catch (e) {
        lastError = e;
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    if (ffi.closed) {
      throw StateError('herdr: la sesión del túnel se cerró mientras se abría');
    }
    throw TimeoutException(
        'Timed out setting up the tunnel to the herdr relay: $lastError');
  }

  /// Minimum wall-clock gap between re-registrations of the forwards.
  static const Duration _rearmInterval = Duration(seconds: 5);

  /// (Re)register both forwards. The native add dedups against the saved peer
  /// config, so a remove+add cycle is the only reliable re-arm.
  static Future<void> _registerForwards(FFI ffi) async {
    try {
      await bind.sessionRemovePortForward(
          sessionId: ffi.sessionId, localPort: kLocalPort);
    } catch (_) {}
    try {
      await bind.sessionAddPortForward(
          sessionId: ffi.sessionId,
          localPort: kLocalPort,
          remoteHost: kRemoteHost,
          remotePort: kRemotePort);
    } catch (e) {
      debugPrint('[HerdrConnectionManager] addPortForward failed: $e');
    }
    // The quota service is optional: register its forward too but never fail
    // the tunnel over it.
    try {
      await bind.sessionRemovePortForward(
          sessionId: ffi.sessionId, localPort: kQuotaLocalPort);
    } catch (_) {}
    try {
      await bind.sessionAddPortForward(
          sessionId: ffi.sessionId,
          localPort: kQuotaLocalPort,
          remoteHost: kRemoteHost,
          remotePort: kQuotaRemotePort);
    } catch (_) {}
    // Likewise optional: without it the picker just browses level by level.
    try {
      await bind.sessionRemovePortForward(
          sessionId: ffi.sessionId, localPort: kDirsLocalPort);
    } catch (_) {}
    try {
      await bind.sessionAddPortForward(
          sessionId: ffi.sessionId,
          localPort: kDirsLocalPort,
          remoteHost: kRemoteHost,
          remotePort: kDirsRemotePort);
    } catch (_) {}
  }

  static Future<void> _probeRelay() async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 5);
    // Bypass any system proxy: some phones route even localhost through a
    // local proxy app (ad-blockers etc.), which breaks the probe with a
    // "Connection refused" to the proxy's own port, not ours.
    client.findProxy = (_) => 'DIRECT';
    try {
      final request = await client.getUrl(Uri.parse(kLocalUrl));
      final response =
          await request.close().timeout(const Duration(seconds: 5));
      await response.drain();
    } finally {
      client.close(force: true);
    }
  }
}
