import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:omioclink_client/media/share_policy.dart';
import 'package:omioclink_client/media/uplink_budget.dart';

const int _source2kWidth = 2560;
const int _source2kHeight = 1440;

/// 2K 屏、默认 28 Mbps 预算下的一份分配结果。
Map<String, ScreenTarget> planOf({
  required SharePolicy policy,
  required int viewers,
  int budgetBps = kDefaultScreenUplinkBudgetBps,
  int sourceWidth = _source2kWidth,
  int sourceHeight = _source2kHeight,
  String? primaryPeerId,
}) => allocateScreenPlan(
  ScreenBudgetInput(
    policy: policy,
    sourceWidth: sourceWidth,
    sourceHeight: sourceHeight,
    peerIds: List<String>.generate(viewers, (index) => 'p$index'),
    budgetBps: budgetBps,
    primaryPeerId: primaryPeerId,
  ),
);

ScreenTarget single({
  required SharePolicy policy,
  required int viewers,
  int budgetBps = kDefaultScreenUplinkBudgetBps,
  int sourceWidth = _source2kWidth,
  int sourceHeight = _source2kHeight,
}) => planOf(
  policy: policy,
  viewers: viewers,
  budgetBps: budgetBps,
  sourceWidth: sourceWidth,
  sourceHeight: sourceHeight,
).values.first;

void main() {
  group('allocateScreenPlan · 帧率优先', () {
    test('2 个观众：一人 14 Mbps，够 2K60 就按源分辨率发', () {
      final target = single(policy: SharePolicy.fpsFirst, viewers: 2);
      expect(target.targetWidth, 2560);
      expect(target.targetHeight, 1440);
      expect(target.maxFramerate, 60);
      expect(target.maxBitrate, 14000000);
      // 下限按需求（16 Mbps）的 60% 给，逼编码器真的把比特花出去
      expect(target.minBitrate, 9600000);
      expect(target.scaleResolutionDownBy, 1.0);
      expect(
        target.degradation,
        RTCDegradationPreference.MAINTAIN_FRAMERATE,
      );
    });

    test('3 个观众：预算只够 1080p60，就先降分辨率、帧率不动', () {
      final target = single(policy: SharePolicy.fpsFirst, viewers: 3);
      expect(target.targetWidth, 1920);
      expect(target.targetHeight, 1080);
      expect(target.maxFramerate, 60);
      expect(target.scaleResolutionDownBy, closeTo(2560 / 1920, 1e-9));
      expect(target.maxBitrate, 9333333);
      expect(target.minBitrate, 5100000);
    });

    test('7 个观众：退到 720p60，仍然不掉到 30fps 以下', () {
      final target = single(policy: SharePolicy.fpsFirst, viewers: 7);
      expect(target.targetWidth, 1280);
      expect(target.targetHeight, 720);
      expect(target.maxFramerate, 60);
      expect(target.maxBitrate, 4000000);
    });
  });

  group('allocateScreenPlan · 分辨率优先', () {
    test('3 个观众：保住 2K，帧率先降到 30', () {
      final target = single(policy: SharePolicy.resolutionFirst, viewers: 3);
      expect(target.targetWidth, 2560);
      expect(target.targetHeight, 1440);
      expect(target.maxFramerate, 30);
      expect(target.scaleResolutionDownBy, 1.0);
      expect(target.maxBitrate, 9000000);
      expect(
        target.degradation,
        RTCDegradationPreference.MAINTAIN_RESOLUTION,
      );
    });

    test('只有 1 个观众时预算富余，帧率提到 60', () {
      final target = single(policy: SharePolicy.resolutionFirst, viewers: 1);
      expect(target.targetWidth, 2560);
      expect(target.maxFramerate, 60);
      // 上限按需求的 1.5 倍封顶，别把整条宽带都灌给一路
      expect(target.maxBitrate, 22500000);
    });

    test('源本身就是 1080p 时不做无意义缩放', () {
      final target = single(
        policy: SharePolicy.resolutionFirst,
        viewers: 1,
        sourceWidth: 1920,
        sourceHeight: 1080,
      );
      expect(target.targetWidth, 1920);
      expect(target.targetHeight, 1080);
      expect(target.scaleResolutionDownBy, 1.0);
    });
  });

  group('allocateScreenPlan · 均衡', () {
    test('3 个观众：2K30，介于两档之间', () {
      final target = single(policy: SharePolicy.balanced, viewers: 3);
      expect(target.targetWidth, 2560);
      expect(target.targetHeight, 1440);
      expect(target.maxFramerate, 30);
      expect(target.maxBitrate, 9333333);
      expect(target.minBitrate, 4800000);
    });
  });

  group('allocateScreenPlan · 主看人权重', () {
    test('主看人拿双份：2K60 一路 + 1080p60 两路', () {
      final plan = planOf(
        policy: SharePolicy.fpsFirst,
        viewers: 3,
        primaryPeerId: 'p0',
      );
      expect(plan['p0']!.targetWidth, 2560);
      expect(plan['p0']!.maxFramerate, 60);
      expect(plan['p0']!.maxBitrate, 14000000);

      for (final peerId in <String>['p1', 'p2']) {
        expect(plan[peerId]!.targetWidth, 1920);
        expect(plan[peerId]!.maxFramerate, 60);
        expect(plan[peerId]!.maxBitrate, 7000000);
      }
    });

    test('主看人不在观众列表里时退回均分（不至于把预算算飞）', () {
      final withUnknown = planOf(
        policy: SharePolicy.fpsFirst,
        viewers: 2,
        primaryPeerId: 'not-here',
      );
      final withoutPrimary = planOf(
        policy: SharePolicy.fpsFirst,
        viewers: 2,
      );
      for (final peerId in <String>['p0', 'p1']) {
        expect(
          withUnknown[peerId]!.maxBitrate,
          withoutPrimary[peerId]!.maxBitrate,
        );
      }
    });
  });

  group('allocateScreenPlan · 硬约束', () {
    test('没有观众时返回空表（还没建连就共享的窗口期）', () {
      expect(
        allocateScreenPlan(
          const ScreenBudgetInput(
            policy: SharePolicy.balanced,
            sourceWidth: _source2kWidth,
            sourceHeight: _source2kHeight,
            peerIds: <String>[],
          ),
        ),
        isEmpty,
      );
    });

    test('各路码率之和永不超过预算（1~7 个观众 × 三档）', () {
      for (final policy in SharePolicy.values) {
        for (var viewers = 1; viewers <= 7; viewers++) {
          final plan = planOf(policy: policy, viewers: viewers);
          final total = plan.values.fold<int>(
            0,
            (sum, target) => sum + target.maxBitrate,
          );
          expect(
            total,
            lessThanOrEqualTo(kDefaultScreenUplinkBudgetBps),
            reason: '$policy / $viewers 人：合计 $total 超出预算',
          );
        }
      }
    });

    test('分辨率不低于 720p、帧率不低于 30fps（1~7 个观众 × 三档）', () {
      for (final policy in SharePolicy.values) {
        for (var viewers = 1; viewers <= 7; viewers++) {
          for (final target in planOf(
            policy: policy,
            viewers: viewers,
          ).values) {
            expect(
              target.targetHeight,
              greaterThanOrEqualTo(720),
              reason: '$policy / $viewers 人：分辨率被打到地板以下',
            );
            expect(
              target.maxFramerate,
              greaterThanOrEqualTo(30),
              reason: '$policy / $viewers 人：帧率被打到 30 以下',
            );
          }
        }
      }
    });

    test('永远不放大：窄源在每一档下都按源分辨率发', () {
      for (final policy in SharePolicy.values) {
        for (var viewers = 1; viewers <= 5; viewers++) {
          final target = single(
            policy: policy,
            viewers: viewers,
            sourceWidth: 1024,
            sourceHeight: 768,
          );
          expect(target.scaleResolutionDownBy, 1.0);
          expect(target.targetWidth, 1024);
          expect(target.targetHeight, 768);
        }
      }
    });

    test('码率下限永不超过上限（极端预算下也不会自己撞自己）', () {
      for (final policy in SharePolicy.values) {
        for (final budget in <int>[0, 500000, 1000000, 3000000]) {
          for (final target in planOf(
            policy: policy,
            viewers: 3,
            budgetBps: budget,
          ).values) {
            expect(target.minBitrate, lessThanOrEqualTo(target.maxBitrate));
          }
        }
      }
    });

    test('预算小到够不着任何地板时，保 720p60 而不是把帧率打到 30 以下', () {
      final target = single(
        policy: SharePolicy.fpsFirst,
        viewers: 3,
        budgetBps: 1000000,
      );
      expect(target.targetHeight, 720);
      expect(target.maxFramerate, 60);
      expect(target.maxBitrate, 333333);
    });

    test('所有路默认都在发（停发留给后续的按需订阅）', () {
      for (final target in planOf(
        policy: SharePolicy.balanced,
        viewers: 3,
      ).values) {
        expect(target.active, isTrue);
      }
    });
  });

  group('ScreenTarget', () {
    test('标签带上实际发出去的尺寸、帧率与码率', () {
      final target = single(policy: SharePolicy.fpsFirst, viewers: 3);
      expect(target.label, '1920×1080@60fps 9.3Mbps');
      expect(target.keepsSourceResolution, isFalse);
    });

    test('按源分辨率发的那些档位会被标出来', () {
      final target = single(policy: SharePolicy.fpsFirst, viewers: 2);
      expect(target.keepsSourceResolution, isTrue);
    });
  });
}
