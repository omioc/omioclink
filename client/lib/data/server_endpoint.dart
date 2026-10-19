/// 用户填写的服务器地址。
///
/// 设计稿里是 `192.168.1.10:21077` 这种裸地址；也允许显式写 scheme：
/// `ws://host:21077/ws`、`wss://link.example.com`、`https://host`。
class ServerEndpoint {
  const ServerEndpoint({
    required this.host,
    required this.port,
    this.secure = false,
    this.webSocketPath = defaultWebSocketPath,
  });

  static const int defaultPort = 21077;
  static const String defaultWebSocketPath = '/ws';

  final String host;
  final int port;

  /// true 表示 HTTPS/WSS。
  final bool secure;

  /// 信令 WebSocket 的路径（反代场景下可能不是 `/ws`）。
  final String webSocketPath;

  /// 解析用户输入；无法解析时返回 null（调用方负责提示）。
  static ServerEndpoint? tryParse(String raw) {
    var text = raw.trim();
    if (text.isEmpty) {
      return null;
    }
    while (text.endsWith('/')) {
      text = text.substring(0, text.length - 1);
    }
    if (text.isEmpty) {
      return null;
    }

    bool secure = false;
    int fallbackPort = defaultPort;
    var wsPath = defaultWebSocketPath;

    final schemeSeparator = text.indexOf('://');
    if (schemeSeparator >= 0) {
      final scheme = text.substring(0, schemeSeparator).toLowerCase();
      final rest = text.substring(schemeSeparator + 3);
      switch (scheme) {
        case 'ws':
          fallbackPort = 80;
        case 'http':
          fallbackPort = 80;
        case 'wss':
          secure = true;
          fallbackPort = 443;
        case 'https':
          secure = true;
          fallbackPort = 443;
        default:
          return null;
      }
      text = rest;
      final slash = text.indexOf('/');
      if (slash >= 0) {
        final path = text.substring(slash);
        text = text.substring(0, slash);
        // 只有 ws/wss 的路径才代表信令端点；http(s) 的路径无意义
        if (scheme == 'ws' || scheme == 'wss') {
          wsPath = path.isEmpty ? defaultWebSocketPath : path;
        }
      }
    }

    if (text.isEmpty ||
        text.contains('@') ||
        text.contains('?') ||
        text.contains(' ')) {
      return null;
    }

    String host = text;
    int port = fallbackPort;
    final colon = text.lastIndexOf(':');
    if (colon >= 0) {
      host = text.substring(0, colon);
      final portText = text.substring(colon + 1);
      if (portText.isEmpty) {
        return null;
      }
      final parsed = int.tryParse(portText);
      if (parsed == null || parsed < 1 || parsed > 65535) {
        return null;
      }
      port = parsed;
    }

    host = host.trim();
    if (host.isEmpty) {
      return null;
    }
    return ServerEndpoint(
      host: host,
      port: port,
      secure: secure,
      webSocketPath: wsPath,
    );
  }

  /// 解析并抛 [FormatException]。
  static ServerEndpoint parse(String raw) {
    final endpoint = tryParse(raw);
    if (endpoint == null) {
      throw FormatException('无法解析服务器地址：$raw');
    }
    return endpoint;
  }

  /// REST 根地址。
  Uri get httpBase =>
      Uri(scheme: secure ? 'https' : 'http', host: host, port: port);

  /// 信令地址（带鉴权 token）。
  Uri webSocketUri({String? token}) => Uri(
    scheme: secure ? 'wss' : 'ws',
    host: host,
    port: port,
    path: webSocketPath,
    queryParameters: token == null ? null : <String, String>{'token': token},
  );

  /// 用于界面展示的 `host:port`。
  String get display => '$host:$port';

  @override
  String toString() => '${secure ? 'wss' : 'ws'}://$display$webSocketPath';

  @override
  bool operator ==(Object other) =>
      other is ServerEndpoint &&
      other.host == host &&
      other.port == port &&
      other.secure == secure &&
      other.webSocketPath == webSocketPath;

  @override
  int get hashCode => Object.hash(host, port, secure, webSocketPath);
}
