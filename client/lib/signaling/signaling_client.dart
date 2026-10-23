import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/app_log.dart';
import '../core/l10n_ext.dart';
import '../data/server_endpoint.dart';
import 'protocol.dart';

/// 信令连接阶段。
enum SignalingPhase {
  /// 尚未启动。
  idle,

  /// 首次建连中。
  connecting,

  /// 已收到 `hello`，可用。
  connected,

  /// 断线后指数退避重连中。
  reconnecting,

  /// 主动关闭。
  closed,

  /// 不可恢复的失败（鉴权失败 / 被顶下线 / 房间解散）。
  failed,
}

/// 不可恢复的失败原因。
enum SignalingFailure {
  unauthorized,
  duplicateSession,
  roomClosed,
  kickedByAdmin,
  protocolMismatch,
}

/// 传输层抽象：便于对信令客户端做纯 Dart 单测（注入内存实现）。
abstract interface class SignalingTransport {
  Stream<dynamic> get messages;
  void send(String data);
  Future<void> close([int? code, String? reason]);
  int? get closeCode;
  String? get closeReason;
}

class WebSocketChannelTransport implements SignalingTransport {
  WebSocketChannelTransport(this._channel);

  final WebSocketChannel _channel;

  @override
  Stream<dynamic> get messages => _channel.stream;

  @override
  void send(String data) => _channel.sink.add(data);

  @override
  Future<void> close([int? code, String? reason]) =>
      _channel.sink.close(code, reason);

  @override
  int? get closeCode => _channel.closeCode;

  @override
  String? get closeReason => _channel.closeReason;
}

typedef SignalingTransportFactory = SignalingTransport Function(Uri uri);

/// 信令客户端：WSS 连接 + 心跳 + 指数退避重连。
///
/// 职责边界：只负责「把 JSON 消息可靠地送达/取出」。房间语义、成员状态、媒体协商
/// 全部由 `RoomSession` 负责。
class SignalingClient {
  SignalingClient({
    required this.endpoint,
    required this.accessToken,
    SignalingTransportFactory? transportFactory,
    this.connectTimeout = const Duration(seconds: 12),
    this.maxReconnectDelay = const Duration(seconds: 30),
    Random? random,
  }) : _transportFactory =
           transportFactory ??
           ((uri) => WebSocketChannelTransport(WebSocketChannel.connect(uri))),
       _random = random ?? Random();

  final ServerEndpoint endpoint;

  /// 访问令牌。改密码后服务端会作废旧令牌，因此这里可以热替换——
  /// 不必重建整个客户端（那会顺带丢掉当前的通话）。
  String accessToken;
  final Duration connectTimeout;
  final Duration maxReconnectDelay;
  final SignalingTransportFactory _transportFactory;
  final Random _random;

  final _messages = StreamController<ServerMessage>.broadcast();

  /// 连接阶段。
  final phase = ValueNotifier<SignalingPhase>(SignalingPhase.idle);

  /// 最近一次不可恢复的失败原因。
  final failure = ValueNotifier<SignalingFailure?>(null);

  /// 最近一次心跳往返时延（用于信号格展示）。
  final latency = ValueNotifier<Duration?>(null);

  /// 最近一次错误的可读描述。
  final lastError = ValueNotifier<String?>(null);

  SignalingTransport? _transport;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  Timer? _connectTimer;
  int _attempt = 0;
  bool _disposed = false;

  /// 服务器下发的会话身份与能力（收到 hello 后可用）。
  ServerHello? hello;

  Stream<ServerMessage> get messages => _messages.stream;
  bool get isConnected => phase.value == SignalingPhase.connected;

  /// 换用新的访问令牌。
  ///
  /// 改密码后服务端会作废旧令牌，必须在这里热替换：否则一旦掉线重连，
  /// 就会拿着一张已失效的令牌被 4401 拒掉。
  void updateAccessToken(String token) {
    accessToken = token;
  }

  /// 建立连接（可重复调用；已连接时为 no-op）。
  void connect() {
    if (_disposed || _transport != null) {
      return;
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    phase.value = _attempt == 0
        ? SignalingPhase.connecting
        : SignalingPhase.reconnecting;
    lastError.value = null;

    final uri = endpoint.webSocketUri(token: accessToken);
    AppLog.info('信令连接 $uri（第 ${_attempt + 1} 次尝试）');
    try {
      final transport = _transportFactory(uri);
      _transport = transport;
      _subscription = transport.messages.listen(
        _onData,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: false,
      );
      _armConnectTimeout();
    } on Object catch (error) {
      AppLog.warn('信令建连失败', error: error);
      _handleDisconnected(description: appL10n.dataConnectFailed);
    }
  }

  /// 主动断开，不再重连。
  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _connectTimer?.cancel();
    _connectTimer = null;
    await _teardownTransport();
    if (!_disposed) {
      phase.value = SignalingPhase.closed;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await disconnect();
    await _messages.close();
    phase.dispose();
    failure.dispose();
    latency.dispose();
    lastError.dispose();
  }

  /// 发送一条消息；未连接时返回 false（信令不做离线排队：重连后由 RoomSession 重新进房）。
  bool send(Map<String, dynamic> message) {
    final transport = _transport;
    if (transport == null || phase.value != SignalingPhase.connected) {
      return false;
    }
    try {
      transport.send(jsonEncode(message));
      return true;
    } on Object catch (error) {
      AppLog.warn('发送信令失败：${message['type']}', error: error);
      return false;
    }
  }

  // ------------------------------------------------------------------ 内部
  Future<void> _teardownTransport() async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    final transport = _transport;
    _transport = null;
    if (transport != null) {
      try {
        await transport.close(SignalingCloseCode.normal, 'client_closed');
      } on Object catch (error) {
        AppLog.warn('关闭信令连接失败', error: error);
      }
    }
  }

  void _armConnectTimeout() {
    _connectTimer?.cancel();
    _connectTimer = Timer(connectTimeout, () {
      if (phase.value == SignalingPhase.connected) {
        return;
      }
      AppLog.warn('信令握手超时');
      _handleDisconnected(description: appL10n.dataConnectTimeout);
    });
  }

  void _onData(dynamic raw) {
    if (raw is! String) {
      return; // 协议只使用文本帧
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      AppLog.warn('收到无法解析的信令消息');
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      return;
    }

    final message = ServerMessage.fromJson(decoded);
    switch (message) {
      case ServerHello():
        hello = message;
        _attempt = 0;
        lastError.value = null;
        phase.value = SignalingPhase.connected;
        _connectTimer?.cancel();
        _connectTimer = null;
        _startHeartbeat(message.heartbeatInterval);
      case ServerPingMessage(:final t):
        // 服务端心跳：立即回 pong
        send({'v': kProtocolVersion, 'type': 'pong', 't': ?t});
      case PongMessage(:final t):
        if (t != null) {
          final roundTrip = DateTime.now().millisecondsSinceEpoch - t.toInt();
          if (roundTrip >= 0 && roundTrip < 60000) {
            latency.value = Duration(milliseconds: roundTrip);
          }
        }
      default:
        break;
    }

    if (!_messages.isClosed) {
      _messages.add(message);
    }
  }

  void _onError(Object error, StackTrace stackTrace) {
    AppLog.warn('信令连接出错', error: error);
    _handleDisconnected(description: appL10n.dataLinkInterrupted);
  }

  void _onDone() {
    final transport = _transport;
    final code = transport?.closeCode;
    final reason = transport?.closeReason;
    AppLog.info('信令连接关闭 code=$code reason=$reason');

    switch (code) {
      case SignalingCloseCode.unauthorized:
        failure.value = SignalingFailure.unauthorized;
        lastError.value = appL10n.dataSessionExpired;
        _stopPermanently();
      case SignalingCloseCode.duplicateSession:
        failure.value = SignalingFailure.duplicateSession;
        lastError.value = appL10n.dataSignedInElsewhere;
        _stopPermanently();
      case SignalingCloseCode.roomClosed:
        failure.value = SignalingFailure.roomClosed;
        lastError.value = appL10n.roomsDissolved;
        _stopPermanently();
      case SignalingCloseCode.kickedByAdmin:
        failure.value = SignalingFailure.kickedByAdmin;
        lastError.value = appL10n.roomsKickedByAdmin;
        _stopPermanently();
      default:
        _handleDisconnected(description: appL10n.dataLinkClosed);
    }
  }

  void _stopPermanently() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _connectTimer?.cancel();
    _connectTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final transport = _transport;
    _transport = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(transport?.close(SignalingCloseCode.normal, null));
    phase.value = SignalingPhase.failed;
  }

  void _handleDisconnected({required String description}) {
    if (_disposed || phase.value == SignalingPhase.failed) {
      return;
    }
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _connectTimer?.cancel();
    _connectTimer = null;
    lastError.value = description;
    unawaited(_teardownTransport());
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed || _reconnectTimer != null) {
      return;
    }
    _attempt += 1;
    final exponential = 1000 * pow(2, min(_attempt - 1, 6)).toInt();
    final cappedMs = min(exponential, maxReconnectDelay.inMilliseconds);
    final delay = Duration(milliseconds: cappedMs + _random.nextInt(400));
    phase.value = SignalingPhase.reconnecting;
    AppLog.info('${delay.inMilliseconds}ms 后重连（第 $_attempt 次）');
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (!_disposed) {
        connect();
      }
    });
  }

  void _startHeartbeat(int intervalSeconds) {
    _heartbeatTimer?.cancel();
    final interval = Duration(seconds: intervalSeconds.clamp(5, 300));
    _heartbeatTimer = Timer.periodic(interval, (_) {
      send(pingMessage(t: DateTime.now().millisecondsSinceEpoch.toDouble()));
    });
  }
}
