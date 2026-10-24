import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/media/call_keepalive.dart';

void main() {
  test('非 Android 平台：开关都是空操作，不会去碰原生通道', () async {
    // 单测跑在桌面上（Windows），这里验证「不该发出平台调用」这条守卫：
    // 一旦守卫失效，enable() 会在测试里抛 MissingPluginException。
    await CallKeepalive.enable();
    expect(CallKeepalive.isEnabled, isFalse);
    await CallKeepalive.disable();
    expect(CallKeepalive.isEnabled, isFalse);
  });
}
