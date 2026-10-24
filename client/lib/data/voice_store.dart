import 'package:shared_preferences/shared_preferences.dart';

import '../media/voice_profile.dart';

/// 语音处理档位的本机持久化（纯本地偏好：服务器不知道，也不告诉房间里的人）。
///
/// 只存档位的稳定标识（`standard` / `aggressive` / `preserve`），不存索引：
/// 索引会随枚举顺序变化而错档，`name` 会随枚举重命名而丢设置。
/// 存储内容坏掉（手改过、写到一半、存成了别的类型）时一律回落默认档，绝不抛给界面。
class VoiceStore {
  static const _key = 'omioclink.voice.profile';

  /// 读出档位；没存过或读不出来就是默认档。
  Future<VoiceProfile> loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    String? raw;
    try {
      raw = prefs.getString(_key);
    } on Object {
      // 存成了别的类型（手改/旧版本残留）：当没设置过
      return VoiceProfile.fallback;
    }
    return VoiceProfile.fromStorageId(raw);
  }

  /// 写入档位。
  Future<void> saveProfile(VoiceProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, profile.storageId);
  }
}
