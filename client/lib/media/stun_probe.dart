import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../core/l10n_ext.dart';

/// STUN 探测结果：本机在某个 STUN 服务器看来是什么公网映射地址。
class StunProbeResult {
  const StunProbeResult({
    required this.server,
    this.mappedAddress,
    this.mappedPort,
    this.roundTrip,
    this.error,
  });

  final String server;
  final InternetAddress? mappedAddress;
  final int? mappedPort;
  final Duration? roundTrip;
  final String? error;

  bool get ok => mappedAddress != null && mappedPort != null;

  String get mapped => ok
      ? '${mappedAddress!.address}:$mappedPort'
      : (error ?? appL10n.stunNoResponse);
}

/// NAT 类型判定。
enum NatType {
  /// 尚未探测。
  unknown,

  /// UDP 完全不通（防火墙拦截或网络禁止）。
  blocked,

  /// 锥型（家用路由器绝大多数）：不同 STUN 看到的映射端口一致，打洞成功率高。
  cone,

  /// 对称型：每个目的地分配不同映射端口，打洞基本无法成功（无中继兜底）。
  symmetric,
}

/// 网络诊断结论。
class NatDiagnosis {
  const NatDiagnosis({
    required this.type,
    required this.results,
    required this.summary,
  });

  final NatType type;
  final List<StunProbeResult> results;
  final String summary;

  bool get canPunch => type == NatType.cone;
}

/// 纯 Dart 的 STUN 客户端。
///
/// 只做「我的公网映射地址是什么」这一步地址发现：本项目**不使用任何中继**，
/// 因此服务器上不存在 TURN，客户端也只配置 `stun:` 服务器。
abstract final class StunProbe {
  static const int _bindingRequest = 0x0001;
  static const int _bindingSuccess = 0x0101;
  static const int _magicCookie = 0x2112A442;
  static const int _attrXorMappedAddress = 0x0020;
  static const int _attrMappedAddress = 0x0001;

  /// 构造一个 STUN Binding Request（20 字节）。
  static Uint8List buildBindingRequest(List<int> transactionId) {
    final data = Uint8List(20);
    final view = ByteData.view(data.buffer);
    view.setUint16(0, _bindingRequest);
    view.setUint16(2, 0); // 无属性
    view.setUint32(4, _magicCookie);
    for (var i = 0; i < 12; i++) {
      data[8 + i] = i < transactionId.length ? transactionId[i] : 0;
    }
    return data;
  }

  /// 解析 Binding Success Response，返回 XOR-MAPPED-ADDRESS。
  ///
  /// 解析失败（类型不符 / 长度不足）返回 null，便于单测与容错。
  static ({InternetAddress address, int port})? parseBindingResponse(
    Uint8List data,
    List<int> transactionId,
  ) {
    if (data.length < 20) {
      return null;
    }
    final view = ByteData.view(data.buffer, data.offsetInBytes, data.length);
    if (view.getUint16(0) != _bindingSuccess) {
      return null;
    }
    if (view.getUint32(4) != _magicCookie) {
      return null;
    }
    for (var i = 0; i < 12 && i < transactionId.length; i++) {
      if (data[8 + i] != transactionId[i]) {
        return null;
      }
    }

    final declaredLength = view.getUint16(2);
    var offset = 20;
    final end = min(data.length, 20 + declaredLength);
    while (offset + 4 <= end) {
      final attributeType = view.getUint16(offset);
      final attributeLength = view.getUint16(offset + 2);
      final valueOffset = offset + 4;
      if (valueOffset + attributeLength > end) {
        break;
      }
      if (attributeType == _attrXorMappedAddress ||
          attributeType == _attrMappedAddress) {
        final parsed = _parseAddressAttribute(
          data,
          view,
          valueOffset,
          attributeLength,
          transactionId,
          xor: attributeType == _attrXorMappedAddress,
        );
        if (parsed != null) {
          return parsed;
        }
      }
      // 属性按 4 字节对齐
      offset = valueOffset + attributeLength + ((4 - attributeLength % 4) % 4);
    }
    return null;
  }

  static ({InternetAddress address, int port})? _parseAddressAttribute(
    Uint8List data,
    ByteData view,
    int offset,
    int length,
    List<int> transactionId, {
    required bool xor,
  }) {
    if (length < 4) {
      return null;
    }
    final family = data[offset + 1];
    var port = view.getUint16(offset + 2);
    if (xor) {
      port ^= _magicCookie >> 16;
    }
    if (family == 0x01) {
      if (length < 8) {
        return null;
      }
      final raw = Uint8List(4);
      for (var i = 0; i < 4; i++) {
        final byte = data[offset + 4 + i];
        raw[i] = xor ? byte ^ ((_magicCookie >> (8 * (3 - i))) & 0xFF) : byte;
      }
      return (address: InternetAddress.fromRawAddress(raw), port: port);
    }
    if (family == 0x02) {
      if (length < 20) {
        return null;
      }
      final raw = Uint8List(16);
      for (var i = 0; i < 16; i++) {
        final byte = data[offset + 4 + i];
        if (!xor) {
          raw[i] = byte;
          continue;
        }
        final mask = i < 4
            ? (_magicCookie >> (8 * (3 - i))) & 0xFF
            : (i - 4 < transactionId.length ? transactionId[i - 4] : 0);
        raw[i] = byte ^ mask;
      }
      return (address: InternetAddress.fromRawAddress(raw), port: port);
    }
    return null;
  }

  /// 向单个 STUN 服务器发起一次绑定请求。
  static Future<StunProbeResult> query(
    String server, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final target = _parseServer(server);
    if (target == null) {
      return StunProbeResult(
        server: server,
        error: appL10n.stunAddressUnsupported,
      );
    }

    RawDatagramSocket? socket;
    try {
      final resolved = await _resolveIpv4(target.host);
      if (resolved == null) {
        return StunProbeResult(server: server, error: appL10n.stunDnsFailed);
      }
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = false;
      final random = Random.secure();
      final transactionId = List<int>.generate(12, (_) => random.nextInt(256));
      final request = buildBindingRequest(transactionId);
      final stopwatch = Stopwatch()..start();

      final response = Completer<StunProbeResult>();
      final subscription = socket.listen(
        (event) {
          if (event != RawSocketEvent.read) {
            return;
          }
          final datagram = socket!.receive();
          if (datagram == null) {
            return;
          }
          final parsed = parseBindingResponse(datagram.data, transactionId);
          if (parsed == null || response.isCompleted) {
            return;
          }
          stopwatch.stop();
          response.complete(
            StunProbeResult(
              server: server,
              mappedAddress: parsed.address,
              mappedPort: parsed.port,
              roundTrip: stopwatch.elapsed,
            ),
          );
        },
        onError: (Object error) {
          // 必须接住 socket 错误事件：目标没有监听时（例如自建 STUN 没起来），
          // Windows 会因 ICMP 端口不可达把 WSAECONNRESET 作为错误事件抛出，
          // 没有 onError 就是一个未处理的异步异常（Flutter 里直接红屏），
          // 用户看到的应该是「无响应」这句诊断，而不是崩溃。
          if (response.isCompleted) {
            return;
          }
          final detail = error is SocketException
              ? (error.osError?.message ?? error.message)
              : '$error';
          response.complete(
            StunProbeResult(
              server: server,
              error: appL10n.stunNoResponseDetail(detail),
            ),
          );
        },
      );

      socket.send(request, resolved, target.port);

      return await response.future
          .timeout(
            timeout,
            onTimeout: () => StunProbeResult(
              server: server,
              error: appL10n.stunNoResponseUdpBlocked,
            ),
          )
          .whenComplete(() async {
            await subscription.cancel();
          });
    } on SocketException catch (error) {
      return StunProbeResult(
        server: server,
        error: appL10n.stunUdpUnavailable(
          error.osError?.message ?? error.message,
        ),
      );
    } on Object catch (error) {
      return StunProbeResult(server: server, error: '$error');
    } finally {
      socket?.close();
    }
  }

  /// 对多个 STUN 服务器并发探测并给出 NAT 类型判定。
  static Future<NatDiagnosis> diagnose(
    List<String> servers, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (servers.isEmpty) {
      return NatDiagnosis(
        type: NatType.unknown,
        results: <StunProbeResult>[],
        summary: appL10n.stunNoServers,
      );
    }
    final results = await Future.wait(
      servers.take(3).map((server) => query(server, timeout: timeout)),
    );
    final ok = results.where((result) => result.ok).toList();
    if (ok.isEmpty) {
      return NatDiagnosis(
        type: NatType.blocked,
        results: results,
        summary: appL10n.stunBlockedSummary,
      );
    }
    final ports = ok.map((result) => result.mappedPort).toSet();
    if (ports.length > 1) {
      return NatDiagnosis(
        type: NatType.symmetric,
        results: results,
        summary: appL10n.stunSymmetricSummary,
      );
    }
    return NatDiagnosis(
      type: NatType.cone,
      results: results,
      summary: appL10n.stunConeSummary,
    );
  }

  /// 解析 `stun:host:port`，返回主机名与端口（IPv4 字面量直接可用）。
  static ({String host, int port})? _parseServer(String server) {
    var text = server.trim();
    if (text.toLowerCase().startsWith('stun:')) {
      text = text.substring(5);
    }
    if (text.isEmpty || text.contains('/')) {
      return null;
    }
    var port = 3478;
    var host = text;
    final colon = text.lastIndexOf(':');
    if (colon > 0) {
      final parsedPort = int.tryParse(text.substring(colon + 1));
      if (parsedPort != null && parsedPort > 0 && parsedPort <= 65535) {
        port = parsedPort;
        host = text.substring(0, colon);
      }
    }
    host = host.trim();
    if (host.isEmpty) {
      return null;
    }
    return (host: host, port: port);
  }

  /// 解析为 IPv4 地址（UDP socket 绑在 IPv4 上）。
  static Future<InternetAddress?> _resolveIpv4(String host) async {
    if (_ipv4Pattern.hasMatch(host)) {
      return InternetAddress(host);
    }
    try {
      final addresses = await InternetAddress.lookup(host);
      for (final address in addresses) {
        if (address.type == InternetAddressType.IPv4) {
          return address;
        }
      }
    } on SocketException {
      return null;
    }
    return null;
  }

  static final RegExp _ipv4Pattern = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
}
