import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/data/voice_store.dart';
import 'package:omioclink_client/media/voice_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('没设置过时读回默认档', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    expect(await VoiceStore().loadProfile(), VoiceProfile.fallback);
    expect(VoiceProfile.fallback, VoiceProfile.standard);
  });

  test('写入后新实例读得回来（按稳定标识存，不按索引）', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await VoiceStore().saveProfile(VoiceProfile.preserve);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('omioclink.voice.profile'), 'preserve');

    final again = VoiceStore();
    expect(await again.loadProfile(), VoiceProfile.preserve);
  });

  test('三个档位都能往返', () async {
    for (final profile in VoiceProfile.values) {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await VoiceStore().saveProfile(profile);
      expect(await VoiceStore().loadProfile(), profile);
    }
  });

  test('存的是不认识的值就回落默认档', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'omioclink.voice.profile': 'turbo',
    });
    expect(await VoiceStore().loadProfile(), VoiceProfile.fallback);
  });

  test('存成了别的类型也不崩，按默认档处理', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'omioclink.voice.profile': 3,
    });
    expect(await VoiceStore().loadProfile(), VoiceProfile.fallback);
  });
}
