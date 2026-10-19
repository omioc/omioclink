import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../data/music_models.dart';
import '../../music/music_favorites.dart';
import '../../music/music_player.dart';
import '../../room/room_music.dart';
import '../../widgets/common.dart';
import 'music_widgets.dart';
import 'playback_mode.dart';

/// 「正在播放」的展示状态：没有播放引擎时退化成「即将播放」（队列第一首）。
class NowPlayingView {
  const NowPlayingView({required this.track, required this.playing});

  final MusicTrack track;

  /// true = 正在播放；false = 只是队列里的下一首（播放引擎接入前都是这种）。
  final bool playing;
}

NowPlayingView? resolveNowPlaying(RoomMusicQueue queue, {MusicPlayer? player}) {
  final current = player?.current ?? queue.nowPlaying;
  if (current != null) {
    return NowPlayingView(track: current, playing: true);
  }
  if (queue.isEmpty) {
    return null;
  }
  return NowPlayingView(track: queue.queue.first, playing: false);
}

/// 底部常驻「正在播放」条（设计稿 `music.png` 底部那一条）。
class NowPlayingBar extends StatelessWidget {
  const NowPlayingBar({
    super.key,
    required this.queue,
    required this.player,
    required this.favorites,
  });

  final RoomMusicQueue queue;
  final MusicPlayer player;
  final MusicFavorites favorites;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[queue, player, favorites]),
      builder: (context, _) {
        final view = resolveNowPlaying(queue, player: player);
        return Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: context.palette.sidebar,
            border: Border(top: BorderSide(color: context.palette.divider)),
          ),
          child: Row(
            children: [
              if (view == null)
                Icon(
                  Icons.library_music_outlined,
                  size: 22,
                  color: context.palette.textMuted,
                )
              else
                MusicCover(
                  url: view.track.coverUrl,
                  size: 40,
                  seed: view.track.id.hashCode,
                ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: _TrackSummary(
                  view: view,
                  // 播放失败 / 音源不可用都要落在这条上：以前它们只写进日志，
                  // 用户看到的就是「点了没反应」。
                  error: player.error ?? (view == null ? player.sourceError : null),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              _TransportControls(
                playing: player.playing,
                player: player,
                favorites: favorites,
                track: view?.track,
              ),
              const SizedBox(width: AppSpacing.md),
              PlayerVolumeControl(player: player, label: '我的音量'),
            ],
          ),
        );
      },
    );
  }
}

class _TrackSummary extends StatelessWidget {
  const _TrackSummary({required this.view, this.error, this.showBadge = true});

  final NowPlayingView? view;

  /// 播放/音源错误：有值时顶掉副标题那一行，用红色显示。
  final String? error;

  /// 是否显示「同步播放中 / 即将播放」胶囊。
  ///
  /// 房间氛围音卡片表头已经有同一颗了，卡片里再挂一颗就是重复；
  /// 底部播放条没有表头，那边保留。
  final bool showBadge;

  @override
  Widget build(BuildContext context) {
    final current = view;
    final message = error;
    if (current == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '还没有人点歌',
            style: TextStyle(
              color: context.palette.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            message ?? '在点歌台挑一首加入播放队列，房间一起听',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: message == null ? context.palette.textMuted : context.palette.danger,
              fontSize: 11,
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                current.track.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: context.palette.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (showBadge) ...<Widget>[
              const SizedBox(width: AppSpacing.sm),
              MusicBadge(
                text: current.playing ? '同步播放中' : '即将播放',
                color: current.playing ? context.palette.success : context.palette.textSecondary,
                icon: current.playing ? Icons.link : null,
              ),
            ],
          ],
        ),
        const SizedBox(height: 2),
        Text(
          message ??
              <String>[
                if (current.track.artistLabel.isNotEmpty)
                  current.track.artistLabel,
                musicPlatformLabel(current.track.platform),
              ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: message == null ? context.palette.textMuted : context.palette.danger,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}

/// 传输控制：接通本机播放引擎；切歌/上一首按队列能力逐步完善。
class _TransportControls extends StatelessWidget {
  const _TransportControls({
    required this.playing,
    required this.player,
    required this.favorites,
    required this.track,
  });

  final bool playing;
  final MusicPlayer player;
  final MusicFavorites favorites;

  /// 这一条正在展示的歌：喜欢按钮跟着它走（没有曲目时按钮禁用但保留）。
  final MusicTrack? track;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 喜欢当前这首：紧挨在播放模式左边，点一下就把在播的歌收进「我喜欢」
        NowPlayingFavoriteButton(favorites: favorites, track: track),
        // 播放模式：房间级设置，点一下轮到下一个模式（图标即当前模式）
        PlaybackModeButton(queue: player.queue),
        const SizedBox(width: AppSpacing.xs),
        Tooltip(
          message: playing ? '暂停' : '播放',
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: context.palette.panelSubtle,
              shape: BoxShape.circle,
            ),
            child: IconButton(
              onPressed: player.togglePlayPause,
              iconSize: 20,
              icon: Icon(
                playing ? Icons.pause : Icons.play_arrow,
                color: context.palette.textPrimary,
              ),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.xs),
        Tooltip(
          message: '下一首',
          child: IconButton(
            onPressed: () => player.playNext(),
            iconSize: 18,
            icon: Icon(Icons.skip_next, color: context.palette.textSecondary),
          ),
        ),
      ],
    );
  }
}

/// 本机播放音量：**纯本地**（各人独立调），只影响自己。
///
/// 音源换成 MusicFree 之后，原来挂在 `MusicLibrary` 上的氛围音音量没了，
/// 这里直接控制本机播放音量（`MusicPlayer.volume`）。
class PlayerVolumeControl extends StatelessWidget {
  const PlayerVolumeControl({
    super.key,
    required this.player,
    this.label = '我的音量',
    this.sliderWidth = 130,
  });

  final MusicPlayer player;
  final String label;
  final double sliderWidth;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final value = player.volume.clamp(0, 100).toDouble();
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              // 静音 / 解除静音都在播放器里记账：解除时回到静音前的音量
              onPressed: () => unawaited(player.toggleMute()),
              iconSize: 18,
              tooltip: value > 0 ? '静音（仅本机）' : '恢复音量（仅本机）',
              icon: Icon(
                value <= 0
                    ? Icons.volume_off_outlined
                    : Icons.volume_up_outlined,
                color: context.palette.textSecondary,
              ),
            ),
            Text(
              label,
              style: TextStyle(
                color: context.palette.textSecondary,
                fontSize: 12,
              ),
            ),
            SizedBox(
              width: sliderWidth,
              child: Slider(
                value: value,
                max: 100,
                onChanged: (next) => unawaited(player.setVolume(next)),
              ),
            ),
            SizedBox(
              width: 36,
              child: Text(
                '${value.round()}%',
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: context.palette.textSecondary,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 屏幕共享页顶部的「房间氛围音」卡片（设计稿 `room.png`）。
class AmbientCard extends StatelessWidget {
  const AmbientCard({
    super.key,
    required this.queue,
    required this.player,
    required this.favorites,
    this.compact = false,
  });

  final RoomMusicQueue queue;
  final MusicPlayer player;
  final MusicFavorites favorites;

  /// 手机窄屏：这一行放不下「封面 + 标题 + 传输 + 音量」，音量条让位
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[queue, player, favorites]),
      builder: (context, _) {
        final view = resolveNowPlaying(queue);
        final upcoming = queue.length;
        return PanelCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.library_music_outlined,
                    size: 16,
                    color: context.palette.accent,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      '房间氛围音',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.palette.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  // 状态胶囊只在这里出现一次：歌曲行里那颗是重复的，已经去掉
                  MusicBadge(
                    text: (view?.playing ?? false) ? '同步播放中' : '等待点歌',
                    color: (view?.playing ?? false)
                        ? context.palette.success
                        : context.palette.textSecondary,
                    icon: (view?.playing ?? false) ? Icons.link : null,
                  ),
                  const Spacer(),
                  if (upcoming > 0) ...[
                    Text(
                      '接下来 $upcoming 首',
                      style: TextStyle(
                        color: context.palette.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Tooltip(
                      message: '查看接下来播放的队列',
                      child: IconButton(
                        key: const ValueKey<String>('ambient-upcoming-queue'),
                        onPressed: () =>
                            unawaited(showUpcomingQueueDialog(context, queue)),
                        iconSize: 16,
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 26,
                          minHeight: 26,
                        ),
                        icon: Icon(
                          Icons.queue_music,
                          color: context.palette.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  if (view == null)
                    Icon(
                      Icons.music_note,
                      size: 22,
                      color: context.palette.textMuted,
                    )
                  else
                    MusicCover(
                      url: view.track.coverUrl,
                      size: 40,
                      seed: view.track.id.hashCode,
                    ),
                  const SizedBox(width: AppSpacing.sm),
                  // 卡片表头已有状态胶囊，这里不重复挂
                  Expanded(child: _TrackSummary(view: view, showBadge: false)),
                  const SizedBox(width: AppSpacing.sm),
                  _TransportControls(
                    playing: player.playing,
                    player: player,
                    favorites: favorites,
                    track: view?.track,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  if (!compact) PlayerVolumeControl(player: player),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              // 左边留给滚动歌词，右边才是那条架构说明（以前它独占整行左侧）
              Row(
                children: [
                  Expanded(child: _LyricLineView(player: player)),
                  const SizedBox(width: AppSpacing.md),
                  Icon(
                    Icons.info_outline,
                    size: 12,
                    color: context.palette.textMuted,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      '客户端直连音源 · 服务端仅同步曲目与开始时间，不转发音频',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.palette.textMuted,
                        fontSize: 10,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 卡片左下角的滚动歌词：跟着本机播放进度换句。
///
/// 歌词只负责好看——取不到就显示占位（「前奏…」/「暂无歌词」），
/// 永远不挡播放、也不转圈。
class _LyricLineView extends StatelessWidget {
  const _LyricLineView({required this.player});

  final MusicPlayer player;

  @override
  Widget build(BuildContext context) {
    final lyrics = player.lyrics;
    final index = player.lyricIndex;
    final active = index >= 0 && index < lyrics.length
        ? lyrics[index].text
        : null;
    final placeholder = player.current == null
        ? '还没有人点歌'
        : (lyrics.isEmpty ? '暂无歌词' : '前奏…');
    final text = active ?? placeholder;
    return Row(
      children: [
        Icon(Icons.lyrics_outlined, size: 12, color: context.palette.textMuted),
        const SizedBox(width: 6),
        Expanded(
          child: ClipRect(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 240),
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.7),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              ),
              child: Align(
                key: ValueKey<String>(text),
                alignment: Alignment.centerLeft,
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: active == null
                        ? context.palette.textMuted
                        : context.palette.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 「接下来 N 首」的弹框：只读列出待播队列（点歌 / 移除去点歌台）。
Future<void> showUpcomingQueueDialog(
  BuildContext context,
  RoomMusicQueue queue,
) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final items = queue.queue;
      return AlertDialog(
        title: Text('接下来播放（${items.length} 首）'),
        content: SizedBox(
          // 手机屏幕放不下 420×340：按可用空间收窄，别让它顶到屏幕外
          width: MediaQuery.sizeOf(context).width > 468
              ? 420
              : MediaQuery.sizeOf(context).width - 48,
          height: MediaQuery.sizeOf(context).height > 680
              ? 340
              : MediaQuery.sizeOf(context).height * 0.5,
          child: items.isEmpty
              ? Center(
                  child: Text(
                    '队列是空的',
                    style: TextStyle(color: context.palette.textMuted, fontSize: 12),
                  ),
                )
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final track = items[index];
                    return Row(
                      children: [
                        SizedBox(
                          width: 20,
                          child: Text(
                            '${index + 1}',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              color: context.palette.textMuted,
                              fontSize: 11,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        MusicCover(
                          url: track.coverUrl,
                          size: 32,
                          seed: track.id.hashCode,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                track.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: context.palette.textPrimary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                <String>[
                                  if (track.artistLabel.isNotEmpty)
                                    track.artistLabel,
                                  musicPlatformLabel(track.platform),
                                ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: context.palette.textMuted,
                                  fontSize: 10,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      );
    },
  );
}
