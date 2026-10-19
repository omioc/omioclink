import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/media/media_models.dart';
import 'package:omioclink_client/media/mic_meter.dart';

void main() {
  final t0 = DateTime(2026, 1, 1, 12);
  late MicLevelMeter meter;

  // 直接喂 ingest，不跑定时器也不碰真实音频设备
  MicLevelMeter build() =>
      MicLevelMeter(sampler: () async => null, clock: () => t0);

  setUp(() {
    meter = build();
    meter.updateCaptureState(capturing: true);
  });

  test('电平超过阈值立即判定为说话', () {
    meter.ingest(0.05, at: t0);
    expect(meter.value.speaking, isTrue);
    expect(meter.value.level, 0.05);
  });

  test('滞回带内维持说话，不因瞬时抖动闪断', () {
    meter.ingest(0.05, at: t0);
    expect(meter.value.speaking, isTrue);

    // 低于说话阈值但仍高于释放阈值 → 落在滞回带里
    meter.ingest(0.012, at: t0.add(const Duration(milliseconds: 100)));
    expect(meter.value.speaking, isTrue, reason: '滞回带内应保持说话状态');
  });

  test('低于释放阈值要等保持期结束才停止说话', () {
    meter.ingest(0.05, at: t0);

    meter.ingest(0.001, at: t0.add(const Duration(milliseconds: 200)));
    expect(meter.value.speaking, isTrue, reason: '保持期内仍然算说话');

    meter.ingest(0.001, at: t0.add(const Duration(milliseconds: 500)));
    expect(meter.value.speaking, isFalse);
  });

  test('安静时不会被滞回带内的电平误判为说话', () {
    meter.ingest(0.012, at: t0);
    expect(meter.value.speaking, isFalse);
  });

  test('采样失败时保持上一次判定，不把绿灯闪掉', () {
    meter.ingest(0.05, at: t0);
    expect(meter.value.speaking, isTrue);

    meter.ingest(null, at: t0.add(const Duration(seconds: 1)));
    expect(meter.value.speaking, isTrue);
  });

  test('静音立即结束说话状态并清零电平', () {
    meter.ingest(0.05, at: t0);
    meter.setMuted(true);

    expect(meter.value.speaking, isFalse);
    expect(meter.value.level, 0);
    expect(meter.value.muted, isTrue);
    expect(meter.value.statusText, '已静音');

    // 静音期间即便喂入大声电平也不说话
    meter.ingest(0.9, at: t0.add(const Duration(milliseconds: 100)));
    expect(meter.value.speaking, isFalse);
  });

  test('未采集时永远不判定为说话，并给出状态文案', () {
    final idle = build();
    expect(idle.value.capturing, isFalse);
    idle.ingest(0.5, at: t0);
    expect(idle.value.speaking, isFalse);
    expect(idle.value.healthy, isFalse);
    expect(idle.value.statusText, '麦克风未启动');
  });

  test('采集失败时状态文案直接给出失败原因', () {
    final broken = build();
    broken.updateCaptureState(capturing: false, error: '无法使用麦克风（无设备或无权限）');
    expect(broken.value.healthy, isFalse);
    expect(broken.value.statusText, contains('无法使用麦克风'));
  });

  test('正在说话时的状态文案是「正在说话」', () {
    meter.ingest(0.08, at: t0);
    expect(meter.value.healthy, isTrue);
    expect(meter.value.statusText, '正在说话');
  });

  test('显示值按 dBFS 映射：安静接近 0，大声接近满格', () {
    const quiet = MicLevel(level: 0.001, capturing: true);
    const loud = MicLevel(level: 0.5, capturing: true);
    expect(quiet.display, closeTo(0, 0.001));
    expect(loud.display, greaterThan(0.85));
    expect(const MicLevel(capturing: true).display, 0);
  });

  test('电平相同不重复通知，避免无谓重建', () {
    var notifications = 0;
    meter.addListener(() => notifications++);

    meter.ingest(0.2, at: t0);
    meter.ingest(0.2, at: t0.add(const Duration(milliseconds: 100)));

    expect(notifications, 1);
  });

  test('电平变化会通知（电平条才会跟着动）', () {
    var notifications = 0;
    meter.addListener(() => notifications++);

    meter.ingest(0.2, at: t0);
    meter.ingest(0.3, at: t0.add(const Duration(milliseconds: 100)));
    meter.ingest(0.4, at: t0.add(const Duration(milliseconds: 200)));

    expect(notifications, 3);
  });
}
