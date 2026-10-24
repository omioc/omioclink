import '../core/l10n_ext.dart';

/// 语音处理档位：决定「麦克风前端怎么处理」+「Opus 花多少比特」。
///
/// 为什么需要用户可选的档位，而不是一套写死的参数：libwebrtc 的音频处理只暴露四个
/// 开关（回声消除 / 降噪 / 自动增益 / 高通），**没有**「降噪强度」这一档
/// （见 `flutter_webrtc` 的 `RTCAudioOptions`）。而这三个问题对声音的要求是互相冲突的：
///
/// * 降噪（NS）会把**持续稳定的声音**当成噪声吃掉——哼歌、长音「嗯——」、口哨，
///   都符合它的噪声模型，唱到第二秒就明显变小变闷；
/// * 自动增益（AGC）在安静时把底噪一起抬起来，一开口又压回去，听感就是
///   「忽大忽小 + 底噪很大」；
/// * 而普通说话又确实需要降噪，否则键盘声、风扇声全被送出去。
///
/// 所以这里给出三个档位，让用户按场景选，默认取「标准」：它在「能压住环境噪声」
/// 和「不把哼唱吃掉」之间折中（保留 NS 与高通，关掉 AGC 这条忽大忽小的来源）。
/// 唱歌 / 哼鸣为主的场景切到 [preserve]，噪声极大的环境切到 [aggressive]。
enum VoiceProfile {
  /// 标准：回声消除 + 降噪 + 高通，自动增益关。
  ///
  /// 关 AGC 是有依据的：本应用的「麦克风音量」调的就是系统录音设备主音量
  /// （见 `mic_volume.dart`），增益由用户自己那一档决定；再叠一层 AGC 就成了两级
  /// 自动增益互相追，安静时把底噪抬起来、忽然大声时又来不及压。
  standard,

  /// 强降噪：在标准之上再打开自动增益，适合键盘声/风扇声大、或者麦克风偏小的机器。
  ///
  /// 代价是哼唱与长音会被压得更狠，底噪也可能被抬起来。
  aggressive,

  /// 保真（唱歌 / 哼鸣）：只留回声消除，降噪、自动增益、高通全关。
  ///
  /// 能不能听见哼唱完全取决于这一档——NS 一开，持续的长音就会被当成噪声衰减掉。
  /// 代价是环境声照原样送出去。
  preserve;

  /// 默认档：绝大多数通话场景。
  static const VoiceProfile fallback = VoiceProfile.standard;

  /// 界面上的名字。
  ///
  /// 文案不能挂在枚举常量上（枚举值必须 const，而文案要跟着语言走），
  /// 所以改成读取时去 ARB 取当前语言（与 `SharePolicy` 同一套做法）。
  String get label => switch (this) {
    VoiceProfile.standard => appL10n.voiceProfileStandardLabel,
    VoiceProfile.aggressive => appL10n.voiceProfileAggressiveLabel,
    VoiceProfile.preserve => appL10n.voiceProfilePreserveLabel,
  };

  /// 一句话适用场景，卡片上作为副标题。
  String get scene => switch (this) {
    VoiceProfile.standard => appL10n.voiceProfileStandardScene,
    VoiceProfile.aggressive => appL10n.voiceProfileAggressiveScene,
    VoiceProfile.preserve => appL10n.voiceProfilePreserveScene,
  };

  /// 选中后的补充说明（设置页底部那一行）。
  String get detail => switch (this) {
    VoiceProfile.standard => appL10n.voiceProfileStandardDetail,
    VoiceProfile.aggressive => appL10n.voiceProfileAggressiveDetail,
    VoiceProfile.preserve => appL10n.voiceProfilePreserveDetail,
  };

  /// 持久化用的稳定字符串。**不要**改成 `index` 或 `name`：
  /// 前者会随枚举顺序变化而错档，后者重命名枚举值就会丢设置。
  String get storageId => switch (this) {
    VoiceProfile.standard => 'standard',
    VoiceProfile.aggressive => 'aggressive',
    VoiceProfile.preserve => 'preserve',
  };

  /// 从存储里读回来；认不出（旧版本残留 / 手改坏）就回落默认档。
  static VoiceProfile fromStorageId(String? id) {
    for (final profile in VoiceProfile.values) {
      if (profile.storageId == id) {
        return profile;
      }
    }
    return fallback;
  }
}

/// 一个档位对麦克风前端的四个开关。
///
/// 这四个值直接进 `getUserMedia` 的音频约束，原生（`flutter_webrtc` 的
/// `GetUserAudio`）把它们翻成 `RTCAudioOptions`。
class MicProcessing {
  const MicProcessing({
    required this.echoCancellation,
    required this.noiseSuppression,
    required this.autoGainControl,
    required this.highpassFilter,
  });

  /// 回声消除：**任何档位都不关**。关掉就是「对方听到自己」，不是可选项。
  final bool echoCancellation;

  /// 降噪：吃掉持续长音（哼唱）的主要来源。
  final bool noiseSuppression;

  /// 自动增益：忽大忽小与底噪被抬起的来源。
  final bool autoGainControl;

  /// 高通：滤掉 80Hz 以下的隆隆声（桌面共振、空调低频），对人声基频无影响。
  final bool highpassFilter;

  @override
  String toString() =>
      'MicProcessing(aec=$echoCancellation, ns=$noiseSuppression, '
      'agc=$autoGainControl, hpf=$highpassFilter)';
}

/// 档位 ↔ 前端开关。
MicProcessing micProcessingFor(VoiceProfile profile) => switch (profile) {
  VoiceProfile.standard => const MicProcessing(
    echoCancellation: true,
    noiseSuppression: true,
    autoGainControl: false,
    highpassFilter: true,
  ),
  VoiceProfile.aggressive => const MicProcessing(
    echoCancellation: true,
    noiseSuppression: true,
    autoGainControl: true,
    highpassFilter: true,
  ),
  VoiceProfile.preserve => const MicProcessing(
    echoCancellation: true,
    noiseSuppression: false,
    autoGainControl: false,
    highpassFilter: false,
  ),
};

/// Opus 的目标码率（bps，`maxaveragebitrate`）。
///
/// libwebrtc 在不写 `maxaveragebitrate` 时按 32k 单声道发——那是「能听懂」的水平，
/// 哼唱、气声、齿音在 32k 下会明显发毛发闷。商业语音（KOOK/Discord/腾讯会议）
/// 通话档普遍在 48~64k 单声道，音乐档更高：
///
/// * 标准 / 强降噪：64k。语音在这个码率下基本透明，且只占投屏码率的零头；
/// * 保真：96k。给唱歌、哼鸣、乐器留余量（单声道就够——采集侧本来就是
///   `channelCount: 1`，两声道只是把同一份信号发两遍）。
int opusTargetBitrateFor(VoiceProfile profile) => switch (profile) {
  VoiceProfile.standard => 64000,
  VoiceProfile.aggressive => 64000,
  VoiceProfile.preserve => 96000,
};
