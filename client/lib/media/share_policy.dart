/// 屏幕共享的编码策略：决定「上行不够时先牺牲什么」。
///
/// 它取代了原来的 `ScreenShareQuality`。那套把帧率、码率上限、降级策略写死成一个
/// 枚举，其中码率上限其实抬不动实速（见 `screen_capture.dart` 里的实测说明）——
/// 真正能分到多少比特取决于房间里有多少观众，所以要按人数现算，见
/// `uplink_budget.dart` 的 `allocateScreenPlan`。
enum SharePolicy {
  /// 游戏投屏：先保帧率，带宽不够就把分辨率降下来。
  fpsFirst('帧率优先', '游戏投屏', '恒定 60fps，带宽不足时先降分辨率'),

  /// 会议 / 文档 / 演示：分辨率锁死在源尺寸，帧率先让位。
  resolutionFirst('分辨率优先', '会议 · 文档 · 演示', '锁定源分辨率不缩放，帧率最低 30fps'),

  /// 寻常场景：按画面内容在两者之间自动取舍。
  balanced('均衡', '寻常场景', '按画面内容自动取舍，默认档');

  const SharePolicy(this.label, this.scene, this.detail);

  /// 界面上的名字。
  final String label;

  /// 一句话适用场景，卡片上作为副标题。
  final String scene;

  /// 选中后的补充说明。
  final String detail;

  /// 默认档：绝大多数共享场景用均衡就够。
  static const SharePolicy fallback = SharePolicy.balanced;
}
