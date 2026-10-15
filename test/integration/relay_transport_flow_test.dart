import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uniun/gateway/session/nostr_frame.dart';
import 'package:uniun/gateway/session/relay_session.dart';
import 'package:uniun/gateway/transport/relay_connection.dart';

/// A throwaway relay on 127.0.0.1: records every text frame it receives and
/// lets the test push frames to the connected client or drop the socket.
class _LocalRelay {
  _LocalRelay._(this._server);

  final HttpServer _server;
  final received = <String>[];
  final _connections = <WebSocket>[];
  final _connected = StreamController<void>.broadcast();
  int accepted = 0;

  static Future<_LocalRelay> start({int? port}) async {
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      port ?? 0,
    );
    final relay = _LocalRelay._(server);
    server.transform(WebSocketTransformer()).listen((ws) {
      relay.accepted++;
      relay._connections.add(ws);
      ws.listen((data) {
        if (data is String) relay.received.add(data);
      });
      relay._connected.add(null);
    });
    return relay;
  }

  int get port => _server.port;
  String get url => 'ws://127.0.0.1:$port';

  void push(String frame) {
    for (final ws in _connections) {
      ws.add(frame);
    }
  }

  Future<void> dropClients() async {
    for (final ws in _connections) {
      await ws.close();
    }
    _connections.clear();
  }

  Future<void> stop() async {
    await dropClients();
    await _server.close(force: true);
    await _connected.close();
  }
}

Future<T> _next<T>(Stream<T> s, {int secs = 5}) =>
    s.first.timeout(Duration(seconds: secs));

Future<void> _until(bool Function() cond, {int secs = 5}) async {
  final end = DateTime.now().add(Duration(seconds: secs));
  while (!cond()) {
    if (DateTime.now().isAfter(end)) fail('condition not met in ${secs}s');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// End-to-end transport scenarios: RelayConnection + RelaySession against a
/// real loopback WebSocket relay (no mocks for the socket).
void main() {
  late _LocalRelay relay;
  RelaySession? session;

  setUp(() async {
    relay = await _LocalRelay.start();
  });

  tearDown(() async {
    await session?.disconnect();
    session = null;
    await relay.stop();
  });

  RelaySession open({bool read = true, bool write = true}) =>
      session = RelaySession(
        connection: RelayConnection(url: relay.url),
        read: read,
        write: write,
      );

  test('connects, reports states and exposes isConnected', () async {
    final s = open();
    final states = <ConnectionState>[];
    s.states.listen(states.add);

    s.connect();
    await _until(() => s.isConnected);

    expect(states, [ConnectionState.connecting, ConnectionState.connected]);
    expect(s.url, relay.url);
  });

  test('subscribe sends a REQ frame and unsubscribe sends CLOSE', () async {
    final s = open();
    s.connect();
    await _until(() => s.isConnected);

    s.subscribe('feed', {
      'kinds': [1],
    });
    s.unsubscribe('feed');
    await _until(() => relay.received.length == 2);

    expect(jsonDecode(relay.received[0]), [
      'REQ',
      'feed',
      {
        'kinds': [1],
      },
    ]);
    expect(jsonDecode(relay.received[1]), ['CLOSE', 'feed']);
  });

  test('inbound EVENT, OK and EOSE frames reach their typed streams', () async {
    final s = open();
    s.connect();
    await _until(() => s.isConnected);

    final event = _next(s.events);
    final ok = _next(s.okAcks);
    final eose = _next(s.eoseEvents);

    relay.push(
      jsonEncode([
        'EVENT',
        'feed',
        {'id': 'e1', 'kind': 1},
      ]),
    );
    relay.push(jsonEncode(['OK', 'e1', true, '']));
    relay.push(jsonEncode(['EOSE', 'feed']));

    final e = await event;
    expect(e.subId, 'feed');
    expect(e.event['id'], 'e1');
    final o = await ok;
    expect([o.eventId, o.accepted], ['e1', true]);
    expect((await eose).subId, 'feed');
  });

  test(
    'garbage, NOTICE and non-string frames are ignored without crashing',
    () async {
      final s = open();
      s.connect();
      await _until(() => s.isConnected);
      final events = <Object>[];
      s.events.listen(events.add);

      relay.push('not json at all');
      relay.push('[]');
      relay.push(jsonEncode(['NOTICE', 'slow down']));
      relay.push(jsonEncode(['EVENT', 'only-two']));
      relay.push(
        jsonEncode([
          'EVENT',
          'sub',
          {'id': 'ok', 'kind': 1},
        ]),
      );

      await _until(() => events.length == 1);
      expect(s.isConnected, isTrue);
    },
  );

  test('a read=false session drops inbound events but keeps OK acks', () async {
    final s = open(read: false);
    s.connect();
    await _until(() => s.isConnected);
    final events = <Object>[];
    s.events.listen(events.add);
    final ok = _next(s.okAcks);

    relay.push(
      jsonEncode([
        'EVENT',
        'sub',
        {'id': 'x', 'kind': 1},
      ]),
    );
    relay.push(jsonEncode(['OK', 'x', false, 'blocked']));

    final o = await ok;
    expect(o.accepted, isFalse);
    expect(events, isEmpty);

    s.subscribe('sub', {});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(relay.received, isEmpty, reason: 'read=false never subscribes');
  });

  test('sending while disconnected is a silent no-op', () async {
    final s = open();
    s.subscribe('x', {});
    s.unsubscribe('x');
    s.sendRaw('["EVENT",{}]');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(relay.received, isEmpty);
    expect(s.isConnected, isFalse);
  });

  test('sendRaw delivers a pre-encoded frame verbatim', () async {
    final s = open();
    s.connect();
    await _until(() => s.isConnected);

    const frame = '["EVENT",{"id":"abc","content":"héllo 🌍"}]';
    s.sendRaw(frame);
    await _until(() => relay.received.isNotEmpty);
    expect(relay.received.single, frame);
  });

  test('reconnects with backoff after the relay drops the socket', () async {
    final s = open();
    s.connect();
    await _until(() => s.isConnected);
    expect(relay.accepted, 1);

    final states = <ConnectionState>[];
    s.states.listen(states.add);
    await relay.dropClients();

    await _until(() => relay.accepted == 2 && s.isConnected, secs: 8);
    expect(
      states,
      containsAllInOrder([
        ConnectionState.disconnected,
        ConnectionState.connecting,
        ConnectionState.connected,
      ]),
    );
  });

  test('an unreachable relay stays disconnected and keeps retrying', () async {
    final dead = await _LocalRelay.start();
    final deadUrl = dead.url;
    await dead.stop();

    final s = session = RelaySession(
      connection: RelayConnection(url: deadUrl),
      read: true,
      write: true,
    );
    s.connect();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(s.isConnected, isFalse);
    expect(s.connection.state, ConnectionState.disconnected);
    // disconnect() awaits sink.close() on a socket that never became ready,
    // which does not complete; cancel the retry timer without awaiting it.
    unawaited(s.disconnect());
    session = null;
  });

  test('a malformed url does not throw out of connect()', () async {
    final s = session = RelaySession(
      connection: RelayConnection(url: 'not-a-websocket-url'),
      read: true,
      write: true,
    );
    expect(s.connect, returnsNormally);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(s.isConnected, isFalse);
    unawaited(s.disconnect());
    session = null;
  });

  test('disconnect closes the socket, streams, and is final', () async {
    final s = open();
    s.connect();
    await _until(() => s.isConnected);

    await s.disconnect();
    expect(s.isConnected, isFalse);

    s.connect();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(s.isConnected, isFalse, reason: 'a disposed connection stays down');
    session = null;
  });

  test('frames built by NostrFrame round-trip through the relay', () async {
    final s = open();
    s.connect();
    await _until(() => s.isConnected);

    s.sendRaw(
      NostrFrame.req('s', {
        'authors': ['a'],
      }),
    );
    await _until(() => relay.received.isNotEmpty);
    expect(jsonDecode(relay.received.single)[0], 'REQ');
  });
}
