import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/pages/herdr/herdr_local_transport.dart';

void main() {
  test('HTTP reaches the listener with its native token before the request',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<String>();
    final token = 'ab' * 32;
    final sub = server.listen((socket) {
      var data = '';
      socket.listen((chunk) {
        data += ascii.decode(chunk);
        if (data.contains('\r\n\r\n') && !received.isCompleted) {
          received.complete(data);
          socket.write(
              'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK');
          socket.close();
        }
      });
    });
    final client = herdrLocalHttpClient((port) async {
      expect(port, server.port);
      return token;
    });
    try {
      final request = await client
          .getUrl(Uri.parse('http://127.0.0.1:${server.port}/healthz'));
      final response = await request.close();
      expect(await response.transform(utf8.decoder).join(), 'OK');
      expect(await received.future,
          startsWith('${token}GET /healthz HTTP/1.1\r\n'));
    } finally {
      client.close(force: true);
      await sub.cancel();
      await server.close();
    }
  });

  test('an absent native listener or non-loopback destination fails closed',
      () async {
    final client = herdrLocalHttpClient((_) async => '');
    try {
      await expectLater(client.getUrl(Uri.parse('http://127.0.0.1:18375/')),
          throwsA(isA<SocketException>()));
      await expectLater(client.getUrl(Uri.parse('http://192.0.2.1:18375/')),
          throwsA(isA<SocketException>()));
    } finally {
      client.close(force: true);
    }
  });
}
