import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/data/avatar_cache.dart';

void main() {
  late List<({int userId, String version})> requests;
  late Map<String, Uint8List?> results;
  late AvatarCache cache;

  setUp(() {
    requests = <({int userId, String version})>[];
    results = <String, Uint8List?>{};
    cache = AvatarCache(
      loader: (userId, version) async {
        requests.add((userId: userId, version: version));
        return results['$userId:$version'];
      },
    );
  });

  test('没拉过时返回 null，拉完就能命中缓存', () async {
    results['7:abc'] = Uint8List.fromList(<int>[1, 2, 3]);

    expect(cache.bytesFor(7, 'abc'), isNull);

    cache.ensure(7, 'abc');
    expect(requests, hasLength(1));
    await pumpEventQueue();

    expect(cache.bytesFor(7, 'abc'), <int>[1, 2, 3]);
  });

  test('重复 ensure 只发一次请求', () async {
    results['7:abc'] = Uint8List.fromList(<int>[1]);

    cache.ensure(7, 'abc');
    cache.ensure(7, 'abc');
    cache.ensure(7, 'abc');
    await pumpEventQueue();

    expect(requests, hasLength(1));

    // 已有缓存后再 ensure 也不该再发
    cache.ensure(7, 'abc');
    await pumpEventQueue();
    expect(requests, hasLength(1));
  });

  test('拉到之后会通知界面重建', () async {
    results['7:abc'] = Uint8List.fromList(<int>[9]);
    var notifications = 0;
    cache.addListener(() => notifications++);

    cache.ensure(7, 'abc');
    await pumpEventQueue();

    expect(notifications, 1);
  });

  test('版本号变化 = 换头像，会重新拉', () async {
    results['7:v1'] = Uint8List.fromList(<int>[1]);
    results['7:v2'] = Uint8List.fromList(<int>[2]);

    cache.ensure(7, 'v1');
    await pumpEventQueue();
    cache.ensure(7, 'v2');
    await pumpEventQueue();

    expect(cache.bytesFor(7, 'v1'), <int>[1]);
    expect(cache.bytesFor(7, 'v2'), <int>[2]);
    expect(requests, hasLength(2));
  });

  test('拉取失败不重试、不抛异常（界面退回首字头像）', () async {
    results['7:abc'] = null;

    cache.ensure(7, 'abc');
    await pumpEventQueue();

    expect(cache.bytesFor(7, 'abc'), isNull);
    cache.ensure(7, 'abc');
    await pumpEventQueue();
    expect(requests, hasLength(1), reason: '失败过就不再反复打接口');
  });

  test('空版本号 / 非法 id 直接当没有头像，不发请求', () async {
    cache.ensure(7, null);
    cache.ensure(7, '');
    cache.ensure(0, 'abc');
    await pumpEventQueue();

    expect(requests, isEmpty);
    expect(cache.bytesFor(7, null), isNull);
  });

  test('clear 之后重新拉（换账号/换服务器）', () async {
    results['7:abc'] = Uint8List.fromList(<int>[1]);
    cache.ensure(7, 'abc');
    await pumpEventQueue();
    expect(cache.bytesFor(7, 'abc'), isNotNull);

    cache.clear();
    expect(cache.bytesFor(7, 'abc'), isNull);

    cache.ensure(7, 'abc');
    await pumpEventQueue();
    expect(requests, hasLength(2));
  });
}
