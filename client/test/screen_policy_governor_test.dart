import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/media/screen_policy_governor.dart';
import 'package:omioclink_client/media/share_policy.dart';

void main() {
  final start = DateTime(2026);
  DateTime at(int seconds) => start.add(Duration(seconds: seconds));

  group('ScreenPolicyGovernor', () {
    test('高动态要连续 3 次才切到帧率优先', () {
      final governor = ScreenPolicyGovernor();
      expect(governor.sample(avgQp: 40, now: at(0)), isNull);
      expect(governor.sample(avgQp: 40, now: at(2)), isNull);
      expect(governor.sample(avgQp: 40, now: at(4)), SharePolicy.fpsFirst);
      expect(governor.effective, SharePolicy.fpsFirst);
    });

    test('中间夹一次静止就重新计数（单次抖动不算数）', () {
      final governor = ScreenPolicyGovernor();
      governor.sample(avgQp: 40, now: at(0));
      governor.sample(avgQp: 40, now: at(2));
      expect(governor.sample(avgQp: 10, now: at(4)), isNull);
      expect(governor.sample(avgQp: 40, now: at(6)), isNull);
      expect(governor.sample(avgQp: 40, now: at(8)), isNull);
      expect(governor.sample(avgQp: 40, now: at(10)), SharePolicy.fpsFirst);
    });

    test('切到帧率优先之后，静止界面要等锁定过去才切回分辨率优先', () {
      final governor = ScreenPolicyGovernor();
      for (var i = 0; i < 3; i++) {
        governor.sample(avgQp: 40, now: at(i * 2));
      }
      expect(governor.effective, SharePolicy.fpsFirst);

      // t=6/8/10 已经攒够静止样本，但还锁在 8 秒的冷却里
      for (var i = 0; i < 3; i++) {
        expect(governor.sample(avgQp: 8, now: at(6 + i * 2)), isNull);
      }
      // t=12 恰好够 8 秒，这回真的切
      expect(governor.sample(avgQp: 8, now: at(12)), SharePolicy.resolutionFirst);
    });

    test('拿不到 QP 时保持现状，绝不瞎猜', () {
      final governor = ScreenPolicyGovernor();
      for (var i = 0; i < 10; i++) {
        expect(governor.sample(avgQp: null, now: at(i * 2)), isNull);
      }
      expect(governor.effective, isNull);

      // 统计里给了 NaN 也一样
      expect(governor.sample(avgQp: double.nan, now: at(20)), isNull);
      expect(governor.effective, isNull);
    });

    test('已经在这个档位就不再重复切（避免反复重设编码参数）', () {
      final governor = ScreenPolicyGovernor();
      for (var i = 0; i < 3; i++) {
        governor.sample(avgQp: 40, now: at(i * 2));
      }
      expect(governor.effective, SharePolicy.fpsFirst);
      for (var i = 3; i < 12; i++) {
        expect(governor.sample(avgQp: 45, now: at(i * 2)), isNull);
      }
      expect(governor.effective, SharePolicy.fpsFirst);
    });

    test('门槛是闭区间：正好等于门槛也算', () {
      final high = ScreenPolicyGovernor();
      for (var i = 0; i < 3; i++) {
        high.sample(avgQp: ScreenPolicyGovernor.highMotionQp, now: at(i * 2));
      }
      expect(high.effective, SharePolicy.fpsFirst);

      final low = ScreenPolicyGovernor();
      for (var i = 0; i < 3; i++) {
        low.sample(avgQp: ScreenPolicyGovernor.stillQp, now: at(i * 2));
      }
      expect(low.effective, SharePolicy.resolutionFirst);
    });

    test('中间地带（既不静止也不高动态）什么都不切', () {
      final governor = ScreenPolicyGovernor();
      for (var i = 0; i < 10; i++) {
        expect(governor.sample(avgQp: 25, now: at(i * 2)), isNull);
      }
      expect(governor.effective, isNull);
    });

    test('reset 回到「还没判断」，重新开始攒样本', () {
      final governor = ScreenPolicyGovernor();
      for (var i = 0; i < 3; i++) {
        governor.sample(avgQp: 40, now: at(i * 2));
      }
      expect(governor.effective, SharePolicy.fpsFirst);

      governor.reset();
      expect(governor.effective, isNull);
      expect(governor.sample(avgQp: 40, now: at(100)), isNull);
      expect(governor.sample(avgQp: 40, now: at(102)), isNull);
      expect(governor.sample(avgQp: 40, now: at(104)), SharePolicy.fpsFirst);
    });
  });
}
