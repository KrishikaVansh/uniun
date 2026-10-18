import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniun/gateway/transport/relay_connection.dart';

/// A loopback "relay" that completes the WebSocket handshake and then never
/// answers anything, the close included. Before #281 a close waited on the
/// relay's answer; now it must not.
class _SilentRelay {
  _SilentRelay._(this._server);
  final ServerSocket _server;
  final _sockets = <Socket>[];

  static Future<_SilentRelay> start() async {
    final relay = _SilentRelay._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    relay._server.listen((socket) {
      relay._sockets.add(socket);
      var request = '';
      var upgraded = false;
      socket.listen((data) {
        if (upgraded) return; // swallow every frame, the close too
        request += latin1.decode(data);
        if (!request.contains('\r\n\r\n')) return;
        final key = RegExp(r'Sec-WebSocket-Key: (.+)\r\n', caseSensitive: false)
            .firstMatch(request)!
            .group(1)!
            .trim();
        final accept = base64.encode(
          sha1.convert(utf8.encode('${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11')).bytes,
        );
        socket.write(
          'HTTP/1.1 101 Switching Protocols\r\n'
          'Upgrade: websocket\r\nConnection: Upgrade\r\n'
          'Sec-WebSocket-Accept: $accept\r\n\r\n',
        );
        upgraded = true;
      });
    });
    return relay;
  }

  String get url => 'ws://127.0.0.1:${_server.port}';

  Future<void> stop() async {
    for (final s in _sockets) {
      s.destroy();
    }
    await _server.close();
  }
}

Future<String> _closedPortUrl() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final url = 'ws://127.0.0.1:${server.port}';
  await server.close();
  return url;
}

/// Covers: RelayConnection.disconnect() finishing in every state (never
/// connected, connecting to a closed port, malformed url, live, live but the
/// relay never answers the close), closing both streams, staying final, and
/// being safe to repeat (#281).
void main() {
  test('disconnect before connect finishes and closes both streams', () async {
    final c = RelayConnection(url: 'ws://127.0.0.1:1');
    var statesDone = false, framesDone = false;
    c.states.listen((_) {}, onDone: () => statesDone = true);
    c.frames.listen((_) {}, onDone: () => framesDone = true);

    await c.disconnect().timeout(const Duration(milliseconds: 500));

    expect(c.state, ConnectionState.disconnected);
    expect(statesDone, isTrue);
    expect(framesDone, isTrue);
  });

  test('disconnect while a closed port keeps failing finishes at once',
      () async {
    final c = RelayConnection(url: await _closedPortUrl());
    c.connect();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(c.isConnected, isFalse);

    final clock = Stopwatch()..start();
    await c.disconnect().timeout(const Duration(seconds: 1));

    expect(clock.elapsed, lessThan(RelayConnection.closeWait));
    expect(c.state, ConnectionState.disconnected);
  });

  test('disconnect after a malformed url finishes at once', () async {
    final c = RelayConnection(url: 'not a websocket url');
    expect(c.connect, returnsNormally);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await c.disconnect().timeout(const Duration(seconds: 1));
    expect(c.state, ConnectionState.disconnected);
  });

  test('disconnect while the first attempt is still in flight finishes',
      () async {
    final c = RelayConnection(url: await _closedPortUrl());
    c.connect();

    await c.disconnect().timeout(const Duration(seconds: 1));
    expect(c.state, ConnectionState.disconnected);
  });

  test('a live relay that never answers the close does not hold disconnect',
      () async {
    final relay = await _SilentRelay.start();
    final c = RelayConnection(url: relay.url);
    try {
      c.connect();
      final end = DateTime.now().add(const Duration(seconds: 5));
      while (!c.isConnected && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(c.isConnected, isTrue);

      final clock = Stopwatch()..start();
      await c.disconnect().timeout(
        RelayConnection.closeWait + const Duration(seconds: 2),
      );

      expect(clock.elapsed, lessThan(RelayConnection.closeWait));
      expect(c.state, ConnectionState.disconnected);
    } finally {
      await relay.stop();
    }
  });

  test('after disconnect, connect does nothing and send is a no-op', () async {
    final c = RelayConnection(url: await _closedPortUrl());
    await c.disconnect();

    c.connect();
    c.send('["REQ","x",{}]');
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(c.state, ConnectionState.disconnected);
    expect(c.isConnected, isFalse);
  });

  test('disconnecting twice is harmless', () async {
    final c = RelayConnection(url: await _closedPortUrl());
    c.connect();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    await c.disconnect();
    await c.disconnect().timeout(const Duration(milliseconds: 500));
    expect(c.state, ConnectionState.disconnected);
  });
}
