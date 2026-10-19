import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/data/server_endpoint.dart';

void main() {
  group('ServerEndpoint.tryParse', () {
    test('裸 host:port（设计稿里的写法）', () {
      final endpoint = ServerEndpoint.tryParse('192.168.1.10:21077');
      expect(endpoint, isNotNull);
      expect(endpoint!.host, '192.168.1.10');
      expect(endpoint.port, 21077);
      expect(endpoint.secure, isFalse);
      expect(endpoint.webSocketPath, '/ws');
      expect(endpoint.display, '192.168.1.10:21077');
      expect(endpoint.httpBase.toString(), 'http://192.168.1.10:21077');
      expect(
        endpoint.webSocketUri(token: 'abc').toString(),
        'ws://192.168.1.10:21077/ws?token=abc',
      );
    });

    test('裸 host 使用默认端口 21077', () {
      final endpoint = ServerEndpoint.tryParse('link.example.com');
      expect(endpoint!.port, ServerEndpoint.defaultPort);
      expect(endpoint.secure, isFalse);
    });

    test('显式 scheme：ws / wss / http / https', () {
      expect(ServerEndpoint.tryParse('ws://10.0.0.5:9000')!.port, 9000);
      expect(ServerEndpoint.tryParse('ws://10.0.0.5')!.port, 80);

      final secure = ServerEndpoint.tryParse('wss://link.example.com')!;
      expect(secure.secure, isTrue);
      expect(secure.port, 443);
      expect(secure.webSocketUri().scheme, 'wss');
      expect(secure.httpBase.scheme, 'https');

      expect(
        ServerEndpoint.tryParse('https://link.example.com:8443')!.port,
        8443,
      );
      expect(ServerEndpoint.tryParse('http://link.example.com')!.port, 80);
    });

    test('ws/wss 的路径作为信令端点，http(s) 的路径忽略', () {
      expect(
        ServerEndpoint.tryParse('ws://host:21077/signal')!.webSocketPath,
        '/signal',
      );
      expect(
        ServerEndpoint.tryParse('http://host:21077/api/v1')!.webSocketPath,
        '/ws',
      );
    });

    test('忽略尾部斜杠与首尾空白', () {
      final endpoint = ServerEndpoint.tryParse('  192.168.1.10:21077/  ');
      expect(endpoint!.host, '192.168.1.10');
      expect(endpoint.webSocketPath, '/ws');
    });

    test('非法输入返回 null', () {
      expect(ServerEndpoint.tryParse(''), isNull);
      expect(ServerEndpoint.tryParse('   '), isNull);
      expect(ServerEndpoint.tryParse('ftp://host:21'), isNull);
      expect(ServerEndpoint.tryParse('host:'), isNull);
      expect(ServerEndpoint.tryParse('host:0'), isNull);
      expect(ServerEndpoint.tryParse('host:70000'), isNull);
      expect(ServerEndpoint.tryParse('host:abc'), isNull);
      expect(ServerEndpoint.tryParse('user@host:21077'), isNull);
      expect(ServerEndpoint.tryParse('host:21077?x=1'), isNull);
      expect(ServerEndpoint.tryParse('has space:21077'), isNull);
    });

    test('parse 失败抛 FormatException', () {
      // 注意 'nope' 本身是合法的裸主机名（走默认端口），必须用真正非法的输入
      expect(
        () => ServerEndpoint.parse('ftp://host:21'),
        throwsFormatException,
      );
      expect(() => ServerEndpoint.parse('   '), throwsFormatException);
    });

    test('相等性包含路径与加密标记', () {
      expect(
        ServerEndpoint.tryParse('wss://host:443/ws'),
        ServerEndpoint.tryParse('https://host'),
      );
      expect(
        ServerEndpoint.tryParse('ws://host:80/ws'),
        isNot(ServerEndpoint.tryParse('ws://host:80/signal')),
      );
    });
  });
}
