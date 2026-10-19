import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../room/room_music.dart';

/// 播放模式在界面上的表现：图标 + 文案。
///
/// 模式本身是 `PlaybackMode` 里的协议字符串，这里只做展示映射：
/// 新增模式时两边一起改，别在界面里散落第二套枚举。
String playbackModeLabel(String mode) => switch (mode) {
  PlaybackMode.repeatOne => '单曲循环',
  PlaybackMode.sequential => '顺序播放',
  PlaybackMode.shuffle => '随机播放',
  _ => '列表循环',
};

IconData playbackModeIcon(String mode) => switch (mode) {
  PlaybackMode.repeatOne => Icons.repeat_one,
  PlaybackMode.sequential => Icons.playlist_play,
  PlaybackMode.shuffle => Icons.shuffle,
  _ => Icons.repeat,
};

/// 播放/暂停按钮左边那颗模式按钮：点一下轮到下一个模式。
///
/// 放在这里而不是各自页面里，是因为点歌台底栏和「正在播放」条都要用，
/// 视觉与轮换顺序必须完全一致。
class PlaybackModeButton extends StatelessWidget {
  const PlaybackModeButton({super.key, required this.queue, this.compact = false});

  final RoomMusicQueue queue;

  /// 手机窄屏：和「下一首」一样缩一档，别把播放条挤爆。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final mode = queue.mode;
    return Tooltip(
      message: '${playbackModeLabel(mode)}（点击切换）',
      child: IconButton(
        onPressed: () => queue.setMode(queue.nextMode),
        iconSize: compact ? 18 : 20,
        visualDensity: VisualDensity.compact,
        icon: Icon(
          playbackModeIcon(mode),
          color: context.palette.textSecondary,
        ),
      ),
    );
  }
}
