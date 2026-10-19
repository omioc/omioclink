import 'share_policy.dart';

/// 均衡档的自动取舍：按画面内容在两个极端之间显式切换。
///
/// 为什么不用 libwebrtc 自带的 `balanced`：它的降级顺序是框架内定的，实测会把
/// 1080p 直接打到 480×270，我们控制不了它降到哪为止。所以这里改成「判断内容类型
/// → 选一个极端」：高动态就当帧率优先，静止界面就当分辨率优先。
///
/// 判断依据是这一路视频的平均量化步长（`qpSum / framesEncoded`）：静态画面在固定
/// 码率下很容易编，QP 稳定在低位；游戏/视频一直在动，QP 高且波动。
class ScreenPolicyGovernor {
  ScreenPolicyGovernor({
    this.switchInterval = const Duration(seconds: 8),
    this.sampleWindow = 3,
  });

  /// 一次切换之后至少锁这么久。
  ///
  /// 来回切会让所有 sender 反复重设编码参数，观感比老老实实固定一档差得多；
  /// 8 秒是「用户能感觉到画面变了、但不至于觉得在抽搐」的折中。
  final Duration switchInterval;

  /// 需要连续多少个采样同向，才认为内容类型真的变了（单次抖动不算）。
  final int sampleWindow;

  /// 高动态门槛：QP 持续高于它，说明画面一直在动。
  static const double highMotionQp = 32;

  /// 静止界面门槛：QP 持续低于它，说明画面基本没变。
  static const double stillQp = 18;

  SharePolicy? _effective;
  DateTime? _lastSwitchAt;
  int _highStreak = 0;
  int _lowStreak = 0;

  /// 当前该用的策略；null 表示「还没判出来，先按调用方的默认走」。
  SharePolicy? get effective => _effective;

  /// 喂一次采样。
  ///
  /// [avgQp] 为 null（还没解出帧，或对端统计里没有 `qpSum`）时不做任何判断——
  /// 拿不到数据时保持现状，比瞎猜一个策略更安全。
  ///
  /// 返回新的有效策略；没有变化就返回 null。
  SharePolicy? sample({required double? avgQp, required DateTime now}) {
    if (avgQp == null || avgQp.isNaN) {
      return null;
    }
    _highStreak = avgQp >= highMotionQp ? _highStreak + 1 : 0;
    _lowStreak = avgQp <= stillQp ? _lowStreak + 1 : 0;

    final wanted = _highStreak >= sampleWindow
        ? SharePolicy.fpsFirst
        : _lowStreak >= sampleWindow
        ? SharePolicy.resolutionFirst
        : null;
    if (wanted == null || wanted == _effective) {
      return null;
    }
    final last = _lastSwitchAt;
    if (last != null && now.difference(last) < switchInterval) {
      return null;
    }
    _effective = wanted;
    _lastSwitchAt = now;
    _highStreak = 0;
    _lowStreak = 0;
    return wanted;
  }

  /// 回到「还没判断」的初始状态（换一次共享、或用户改了档位都要重来）。
  void reset() {
    _effective = null;
    _lastSwitchAt = null;
    _highStreak = 0;
    _lowStreak = 0;
  }
}
