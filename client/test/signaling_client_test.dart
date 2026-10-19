import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/data/server_endpoint.dart';
import 'package:omioclink_client/signaling/protocol.dart';
import 'package:omioclink_client/signaling/signaling_client.dart';

/// 内存传输层：把服务端下发的消息直接喂给客户端，并记录客户端发出的内容。
class FakeTransport implements SignalingTransport {
  FakeTransport(this.uri);

  final Uri uri;
  final StreamController<dynamic> _controller =
      StreamController<dynamic>.broadcast();
  final List<String> sent = <String>[];
  int? _closeCode;
  String? _closeReason;
  bool closed = false;

  @override
  Stream<dynamic> get messages => _controller.stream;

  @override
  void send(String data) => sent.add(data);

  @override
  Future<void> close([int? code, String? reason]) async {
    if (closed) {
      return;
    }
    closed = true;
    _closeCode = code;
    _closeReason = reason;
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }

  @override
  int? get closeCode => _closeCode;

  @override
  String? get closeReason => _closeReason;

  void emit(Map<String, dynamic> payload) {
    if (!_controller.isClosed) {
      _controller.add(jsonEncode(payload));
    }
  }

  void emitRaw(String raw) {
    if (!_controller.isClosed) {
      _controller.add(raw);
    }
  }

  void emitBinary(List<int> bytes) {
    if (!_controller.isClosed) {
      _controller.add(bytes);
    }
  }

  void emitError(Object error) {
    if (!_controller.isClosed) {
      _controller.addError(error);
    }
  }

  /// 模拟服务端关闭连接（带关闭码）。
  void serverClose(int code, [String? reason]) {
    _closeCode = code;
    _closeReason = reason;
    if (!_controller.isClosed) {
      _controller.close();
    }
  }

  /// 客户端发出的消息（已解码）。
  List<Map<String, dynamic>> get sentJson =>
      sent.map((item) => jsonDecode(item) as Map<String, dynamic>).toList();
}

const _endpoint = ServerEndpoint(host: '127.0.0.1', port: 21077);

Map<String, dynamic> helloPayload({
  int heartbeatInterval = 30,
}) => <String, dynamic>{
  'type': 'hello',
  'peerId': 'ac4b0391',
  'protocolVersion': 1,
  'heartbeatInterval': heartbeatInterval,
  'iceServers': <String>['stun:stun.example.com:3478'],
  'roomCapacity': 5,
  'server': <String, dynamic>{'name': 'OmiocLink', 'version': '0.1.0'},
  'user': <String, dynamic>{'id': 7, 'username': 'alice', 'displayName': '小明'},
};

Future<void> pump([int times = 4]) async {
  for (var index = 0; index < times; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late List<FakeTransport> transports;

  SignalingClient buildClient({List<String>? iceServers}) {
    transports = <FakeTransport>[];
    return SignalingClient(
      endpoint: _endpoint,
      accessToken: 'test-token',
      random: Random(7),
      connectTimeout: const Duration(seconds: 3),
      maxReconnectDelay: const Duration(seconds: 2),
      transportFactory: (uri) {
        final transport = FakeTransport(uri);
        transports.add(transport);
        return transport;
      },
    );
  }

  test('建连后收到 hello 才算连上，并且 token 走查询参数', () async {
    final client = buildClient();
    expect(client.phase.value, SignalingPhase.idle);

    client.connect();
    expect(client.phase.value, SignalingPhase.connecting);
    expect(transports, hasLength(1));
    expect(
      transports.first.uri.toString(),
      'ws://127.0.0.1:21077/ws?token=test-token',
    );
    expect(client.isConnected, isFalse, reason: '握手完成前不算连上');

    transports.first.emit(helloPayload());
    await pump();

    expect(client.phase.value, SignalingPhase.connected);
    expect(client.hello!.peerId, 'ac4b0391');
    expect(client.hello!.iceServers, <String>['stun:stun.example.com:3478']);
    expect(client.lastError.value, isNull);

    await client.dispose();
  });

  test('未连接时 send 返回 false（信令不做离线排队）', () async {
    final client = buildClient();
    expect(client.send(pingMessage()), isFalse);

    client.connect();
    transports.first.emit(helloPayload());
    await pump();
    expect(client.send(pingMessage()), isTrue);

    await client.dispose();
  });

  test('回应服务端心跳，并用 pong 计算往返时延', () async {
    final client = buildClient();
    client.connect();
    transports.first.emit(helloPayload());
    await pump();

    final sentAt = DateTime.now().millisecondsSinceEpoch - 30;
    transports.first.emit(<String, dynamic>{'type': 'ping', 't': sentAt});
    await pump();

    expect(transports.first.sentJson.last, <String, dynamic>{
      'v': 1,
      'type': 'pong',
      't': sentAt,
    });

    transports.first.emit(<String, dynamic>{'type': 'pong', 't': sentAt});
    await pump();
    expect(client.latency.value, isNotNull);
    expect(client.latency.value!.inMilliseconds, greaterThanOrEqualTo(0));

    await client.dispose();
  });

  test('消息流同时下发 ping 与业务消息；非 JSON 与二进制帧被忽略', () async {
    final client = buildClient();
    final received = <ServerMessage>[];
    final subscription = client.messages.listen(received.add);

    client.connect();
    transports.first.emit(helloPayload());
    await pump();
    transports.first.emit(<String, dynamic>{
      'type': 'member_left',
      'peerId': 'p1',
    });
    transports.first.emitRaw('not json');
    transports.first.emitBinary(<int>[1, 2, 3]);
    await pump();

    expect(received.whereType<ServerHello>(), hasLength(1));
    expect(received.whereType<MemberLeftMessage>(), hasLength(1));

    await subscription.cancel();
    await client.dispose();
  });

  test('鉴权失败（4401）不重连', () async {
    final client = buildClient();
    client.connect();
    transports.first.serverClose(
      SignalingCloseCode.unauthorized,
      'unauthorized',
    );
    await pump();

    expect(client.phase.value, SignalingPhase.failed);
    expect(client.failure.value, SignalingFailure.unauthorized);
    expect(client.lastError.value, contains('登录状态'));

    await Future<void>.delayed(const Duration(milliseconds: 1400));
    expect(transports, hasLength(1), reason: '不可恢复失败不应重连');
    await client.dispose();
  });

  test('被顶下线（4409）不重连', () async {
    final client = buildClient();
    client.connect();
    transports.first.serverClose(
      SignalingCloseCode.duplicateSession,
      'duplicate_session',
    );
    await pump();

    expect(client.phase.value, SignalingPhase.failed);
    expect(client.failure.value, SignalingFailure.duplicateSession);

    await Future<void>.delayed(const Duration(milliseconds: 1400));
    expect(transports, hasLength(1));
    await client.dispose();
  });

  test('被管理员移出（4410）不重连', () async {
    final client = buildClient();
    client.connect();
    transports.first.serverClose(
      SignalingCloseCode.kickedByAdmin,
      'kicked_by_admin',
    );
    await pump();

    expect(client.phase.value, SignalingPhase.failed);
    expect(client.failure.value, SignalingFailure.kickedByAdmin);
    expect(client.lastError.value, contains('管理员'));

    await Future<void>.delayed(const Duration(milliseconds: 1400));
    expect(transports, hasLength(1), reason: '被踢不应自动重连');
    await client.dispose();
  });

  test('普通断开进入重连并在退避后重新建连', () async {
    final client = buildClient();
    client.connect();
    transports.first.emit(helloPayload());
    await pump();
    expect(client.phase.value, SignalingPhase.connected);

    transports.first.serverClose(SignalingCloseCode.normal, 'server_restart');
    await pump();
    expect(client.phase.value, SignalingPhase.reconnecting);
    expect(transports, hasLength(1));

    await Future<void>.delayed(const Duration(milliseconds: 1600));
    expect(transports, hasLength(2), reason: '退避后应重新建连');

    transports.last.emit(helloPayload());
    await pump();
    expect(client.phase.value, SignalingPhase.connected);

    await client.dispose();
  });

  test('连接出错也会触发重连', () async {
    final client = buildClient();
    client.connect();
    transports.first.emitError(StateError('socket reset'));
    await pump();

    expect(client.phase.value, SignalingPhase.reconnecting);
    await client.dispose();
  });

  test('disconnect 后不再重连', () async {
    final client = buildClient();
    client.connect();
    transports.first.emit(helloPayload());
    await pump();

    await client.disconnect();
    expect(client.phase.value, SignalingPhase.closed);
    expect(transports.first.closed, isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 1400));
    expect(transports, hasLength(1));

    await client.dispose();
  });

  test('反复 connect 不会建立多条连接', () async {
    final client = buildClient();
    client.connect();
    client.connect();
    client.connect();
    expect(transports, hasLength(1));
    await client.dispose();
  });
}
