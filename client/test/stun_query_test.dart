import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/media/stun_probe.dart';

void main() {
  test('探测没有监听的 UDP 端口时给出诊断，而不是抛未处理异常', () async {
    // 先占一个端口再释放，得到一个几乎肯定没人监听的端口号
    final probe = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    probe.close();

    final result = await StunProbe.query(
      'stun:127.0.0.1:$port',
      timeout: const Duration(seconds: 1),
    );

    expect(result.ok, isFalse);
    expect(result.error, isNotNull);
    expect(result.mappedAddress, isNull);

    // 给可能迟到的 socket 错误事件一点时间：如果没接住 onError，
    // 这里会冒出未处理的异步异常，测试随之失败（这正是要防的回归）
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });

  test('地址格式不支持时立即返回诊断', () async {
    final result = await StunProbe.query('http://example.com/stun');
    expect(result.ok, isFalse);
    expect(result.error, isNotNull);
  });
}
