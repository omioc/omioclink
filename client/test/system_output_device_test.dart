import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/media/system_output_device.dart';

void main() {
  group('语音落点：设置页「系统默认设备」的语义', () {
    const mediaDefault =
        '{0.0.0.00000000}.{825fe633-d6cf-4f09-8a26-566125f6fc7e}';
    const picked = '{0.0.0.00000000}.{7f187027-5ad8-4312-b30f-07247598574d}';

    test('跟随系统 = 系统默认设备（和音乐同一只），不是默认通信设备', () {
      expect(
        voiceOutputTarget(chosen: '', mediaDefault: mediaDefault),
        mediaDefault,
      );
    });

    test('手选了设备就以用户为准', () {
      expect(voiceOutputTarget(chosen: picked, mediaDefault: mediaDefault), picked);
    });

    test('取不到系统默认设备时返回空串，调用方据此不动系统设置', () {
      expect(voiceOutputTarget(chosen: '', mediaDefault: null), isEmpty);
    });

    test('非 Windows 平台没有默认设备可言，也不该硬塞一个', () {
      expect(voiceOutputTarget(chosen: '', mediaDefault: ''), isEmpty);
    });
  });
}
