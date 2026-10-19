import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/core/system_proxy.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseProxyAddress', () {
    test('接受 host:port', () {
      expect(SystemProxy.parseProxyAddress('127.0.0.1:7890'), '127.0.0.1:7890');
    });

    test('剥掉协议前缀与路径', () {
      expect(
        SystemProxy.parseProxyAddress('http://127.0.0.1:7890/'),
        '127.0.0.1:7890',
      );
    });

    test('系统那种 http=/https= 写法取第一段', () {
      expect(
        SystemProxy.parseProxyAddress('http=127.0.0.1:7890;https=127.0.0.1:7891'),
        '127.0.0.1:7890',
      );
    });

    test('只有主机名时补默认端口', () {
      expect(SystemProxy.parseProxyAddress('proxy.local'), 'proxy.local:80');
    });

    test('空值一律当作没有代理', () {
      expect(SystemProxy.parseProxyAddress('   '), isNull);
      expect(SystemProxy.parseProxyAddress(''), isNull);
      expect(SystemProxy.parseProxyAddress(null), isNull);
    });
  });

  group('自定义代理', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      SystemProxy.debugReset();
    });

    tearDown(SystemProxy.debugReset);

    test('设置过自定义代理时优先用它（压过环境变量与系统设置）', () async {
      await SystemProxy.setOverride('127.0.0.1:7899');
      SystemProxy.debugReset();
      // 测试里关掉本地代理自动探测：那是网络行为，不该出现在单测里
      await SystemProxy.load(detectLocal: false);

      expect(SystemProxy.address, '127.0.0.1:7899');
      expect(SystemProxy.source, '自定义');
    });

    test('清空自定义代理后回落到系统探测', () async {
      await SystemProxy.setOverride('127.0.0.1:7899');
      await SystemProxy.setOverride('  ');
      SystemProxy.debugReset();
      await SystemProxy.load(detectLocal: false);

      expect(SystemProxy.override, isNull);
      expect(SystemProxy.source, isNot('自定义'));
    });
  });
}
