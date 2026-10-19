import 'package:flutter/material.dart';

import '../core/app_theme.dart';

/// 一条音量的滑块 + 标题 + 当前百分比。
///
/// 三条通道共用同一个外观，只是量程不同：
/// * 成员音量 0~200%（听不清的成员可以放大）；
/// * 音乐 / 麦克风音量 0~100%。
///
/// [onChanged] 收到的是**滑块量程内的原始值**（0~[max]），由调用方换算成业务单位。
class VolumeSliderTile extends StatelessWidget {
  const VolumeSliderTile({
    super.key,
    required this.label,
    required this.value,
    required this.max,
    required this.onChanged,
    this.icon,
    this.subtitle,
    this.notice,
    this.enabled = true,
    this.sliderKey,
  });

  final String label;

  /// 当前值（0~[max]）。
  final double value;

  /// 量程上限：100 或 200。
  final double max;

  final ValueChanged<double> onChanged;
  final IconData? icon;

  /// 标题下面的一行小字（比如「只影响本机听感」）。
  final String? subtitle;

  /// 降级提示（比如「没有找到可用的录音设备」）。
  final String? notice;

  final bool enabled;

  /// 传给 [Slider] 的 key，测试用它找到具体滑块并拖动。
  final Key? sliderKey;

  @override
  Widget build(BuildContext context) {
    final clamped = value.clamp(0, max).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (icon != null) ...<Widget>[
              Icon(icon, size: 13, color: context.palette.textSecondary),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: context.palette.textSecondary,
                  fontSize: 12.5,
                  height: 1.3,
                ),
              ),
            ),
            Text(
              '${clamped.round()}%',
              style: TextStyle(
                color: context.palette.textSecondary,
                fontSize: 11.5,
                height: 1.3,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        SizedBox(
          height: 24,
          child: SliderTheme(
            data: _compactTheme(context),
            child: Slider(
              key: sliderKey,
              min: 0,
              max: max,
              value: clamped,
              onChanged: enabled ? onChanged : null,
            ),
          ),
        ),
        if (subtitle != null)
          Text(
            subtitle!,
            style: TextStyle(
              color: context.palette.textMuted,
              fontSize: 10.5,
              height: 1.55,
            ),
          ),
        if (notice != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              notice!,
              style: TextStyle(
                color: context.palette.warning,
                fontSize: 10.5,
                height: 1.5,
              ),
            ),
          ),
      ],
    );
  }

  static SliderThemeData _compactTheme(BuildContext context) {
    // 房间成员那一列很窄，默认滑块太占高度，这里统一收窄（外观与主题一致）
    return SliderTheme.of(context).copyWith(
      trackHeight: 2.5,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
    );
  }
}

/// 房间里一名成员的音量条（0~200%）。
///
/// 只影响本机听感：不发给服务器、对方也不知道；点右端的静音按钮是另一条路径
/// （见成员列表的麦克风按钮），两者并联，任一为静音即静音。
class PeerVolumeSlider extends StatelessWidget {
  const PeerVolumeSlider({
    super.key,
    required this.label,
    required this.percent,
    required this.onChanged,
    this.muted = false,
    this.sliderKey,
  });

  /// 成员名（用于无障碍朗读与调试）。
  final String label;

  /// 0~200 的百分比。
  final double percent;

  final ValueChanged<double> onChanged;

  /// 是否已被本地静音（图标变成静音样式，但滑块仍可拖动）。
  final bool muted;

  /// 传给 [Slider] 的 key（按成员 userId 区分，测试用它拖动）。
  final Key? sliderKey;

  @override
  Widget build(BuildContext context) {
    final value = percent.clamp(0, 200).toDouble();
    return Row(
      children: [
        Icon(
          muted || value == 0
              ? Icons.volume_off_rounded
              : (value > 100
                    ? Icons.volume_up_rounded
                    : Icons.volume_down_rounded),
          size: 13,
          color: context.palette.textMuted,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: SizedBox(
            height: 22,
            child: SliderTheme(
              data: VolumeSliderTile._compactTheme(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
              ),
              child: Slider(
                key: sliderKey,
                min: 0,
                max: 200,
                value: value,
                onChanged: onChanged,
              ),
            ),
          ),
        ),
        SizedBox(
          width: 30,
          child: Text(
            '${value.round()}%',
            textAlign: TextAlign.right,
            style: TextStyle(color: context.palette.textMuted, fontSize: 10),
          ),
        ),
      ],
    );
  }
}
