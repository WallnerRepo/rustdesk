import 'dart:convert';
import 'dart:io';

/// The native listener owns its token and publishes it only after binding.
/// It consumes this preamble locally; the relay never sees the credential.
HttpClient herdrLocalHttpClient(Future<String> Function(int) tokenForPort) {
  final client = HttpClient()..findProxy = (_) => 'DIRECT';
  client.connectionFactory = (uri, proxyHost, proxyPort) async {
    if (uri.host != '127.0.0.1' || proxyHost != null) {
      throw const SocketException('Herdr transport requires direct loopback');
    }
    final token = await tokenForPort(uri.port);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(token)) {
      throw const SocketException('Herdr listener is not ready');
    }
    final task = await Socket.startConnect(uri.host, uri.port);
    return ConnectionTask.fromSocket(task.socket.then((socket) {
      socket.add(ascii.encode(token));
      return socket;
    }), task.cancel);
  };
  return client;
}
