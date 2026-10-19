import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/media/share_policy.dart';

void main() {
  group('SharePolicy', () {
    test('三档都有名字、适用场景与补充说明', () {
      for (final policy in SharePolicy.values) {
        expect(policy.label, isNotEmpty);
        expect(policy.scene, isNotEmpty);
        expect(policy.detail, isNotEmpty);
      }
    });

    test('默认档是均衡：寻常场景不该逼用户先做选择', () {
      expect(SharePolicy.fallback, SharePolicy.balanced);
    });

    test('三档的名字互不重复（卡片上并排，撞名就没法选）', () {
      final labels = SharePolicy.values.map((policy) => policy.label).toSet();
      expect(labels, hasLength(SharePolicy.values.length));
    });

    test('三档的顺序固定：帧率优先、分辨率优先、均衡', () {
      expect(SharePolicy.values, <SharePolicy>[
        SharePolicy.fpsFirst,
        SharePolicy.resolutionFirst,
        SharePolicy.balanced,
      ]);
    });
  });
}
