import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/formatting.dart';
import '../../core/l10n_ext.dart';
import '../../data/music_models.dart';
import '../../music/music_favorites.dart';

/// 封面：网络图 + 渐变兜底。
/// 音源经常给不出封面（酷我的搜索结果基本没有），所以兜底必须体面：按 id 派生
/// 渐变 + 音符图标，与成员头像的兜底是同一套路数。
class MusicCover extends StatelessWidget {
  const MusicCover({
    super.key,
    required this.url,
    this.size = 40,
    this.radius = AppRadii.small,
    this.seed = 0,
  });

  final String? url;
  final double size;
  final BorderRadius radius;
  final int seed;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: context.palette.avatarGradientFor(seed),
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.music_note,
        size: size * 0.45,
        color: Colors.white.withValues(alpha: 0.85),
      ),
    );

    final source = url;
    return ClipRRect(
      borderRadius: radius,
      child: SizedBox(
        width: size,
        height: size,
        child: source == null || source.isEmpty
            ? fallback
            : Image.network(
                source,
                fit: BoxFit.cover,
                // 列表里的封面不需要原图，按显示尺寸取一份就够
                cacheWidth: (size * 2).round(),
                errorBuilder: (_, _, _) => fallback,
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : fallback,
              ),
      ),
    );
  }
}

/// 小胶囊徽章：来源平台 / 免费音源 / 同步播放中等。
class MusicBadge extends StatelessWidget {
  const MusicBadge({
    super.key,
    required this.text,
    this.color,
    this.icon,
  });

  final String text;
  /// 不传时用次要文字色：颜色要跟着主题走，所以默认值只能在 build 里取。
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? context.palette.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: AppRadii.pill,
        border: Border.all(color: tint.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 10, color: tint),
            const SizedBox(width: 3),
          ],
          Text(
            text,
            style: TextStyle(
              color: tint,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 歌曲行：名次（可选）/ 封面 / 标题（含来源徽章）/ 歌手 · 专辑 / 时长 / 尾部动作。
class MusicSongTile extends StatefulWidget {
  const MusicSongTile({
    super.key,
    required this.track,
    this.rank,
    this.trailing,
    this.onTap,
    this.showPlatform = true,
    this.playing = false,
    this.dense = false,
    this.note,
  });

  final MusicTrack track;
  final int? rank;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showPlatform;
  final bool playing;
  final bool dense;

  /// 副标题末尾追加的一小段说明（点歌台队列用它显示「点歌人」）。
  final String? note;

  @override
  State<MusicSongTile> createState() => _MusicSongTileState();
}

class _MusicSongTileState extends State<MusicSongTile> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final subtitle = <String>[
      if (track.artistLabel.isNotEmpty) track.artistLabel,
      if (track.album?.name != null && track.album!.name!.isNotEmpty)
        track.album!.name!,
      if (widget.note != null && widget.note!.isNotEmpty) widget.note!,
    ].join(' · ');
    final duration = track.duration;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      cursor: widget.onTap == null
          ? MouseCursor.defer
          : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: widget.dense ? AppSpacing.xs : 6,
          ),
          decoration: BoxDecoration(
            color: _hovering
                ? context.palette.panelSubtle.withValues(alpha: 0.55)
                : Colors.transparent,
            borderRadius: AppRadii.small,
          ),
          child: Row(
            children: [
              if (widget.rank != null)
                SizedBox(
                  width: 24,
                  child: Text(
                    '${widget.rank}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: widget.rank! <= 3
                          ? context.palette.success
                          : context.palette.textMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              MusicCover(
                url: track.coverUrl,
                size: widget.dense ? 32 : 38,
                seed: track.id.hashCode,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            track.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: widget.playing
                                  ? context.palette.success
                                  : context.palette.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        if (widget.playing) ...[
                          const SizedBox(width: 6),
                          Icon(
                            Icons.graphic_eq,
                            size: 13,
                            color: context.palette.success,
                          ),
                        ],
                        if (widget.showPlatform) ...[
                          const SizedBox(width: 6),
                          MusicBadge(
                            text: musicPlatformLabel(track.platform),
                            color: context.palette.accent,
                          ),
                        ],
                      ],
                    ),
                    if (subtitle.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.palette.textMuted,
                            fontSize: 11,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (duration != null) ...[
                const SizedBox(width: AppSpacing.sm),
                Text(
                  formatDuration(duration),
                  style: TextStyle(
                    color: context.palette.textMuted,
                    fontSize: 11,
                  ),
                ),
              ],
              if (widget.trailing != null) ...[
                const SizedBox(width: AppSpacing.xs),
                widget.trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 「加入队列」小圆钮：已在队列里时变成对勾并禁用。
class MusicAddButton extends StatelessWidget {
  const MusicAddButton({
    super.key,
    required this.added,
    this.onPressed,
    this.tooltip,
  });

  final bool added;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: added
          ? context.l10n.musicAddButtonAdded
          : (tooltip ?? context.l10n.musicAddButton),
      child: SizedBox(
        width: 28,
        height: 28,
        child: IconButton(
          padding: EdgeInsets.zero,
          iconSize: 16,
          onPressed: added ? null : onPressed,
          icon: Icon(
            added ? Icons.check_circle : Icons.add_circle_outline,
            color: added ? context.palette.success : context.palette.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// 「喜欢」小圆钮：实心心形＝已经在「我喜欢」里，再点一下取消。
///
/// 尺寸和 [MusicAddButton] 完全同档（28×28 / 图标 16）：两者并排站在行尾，
/// 差一点就会让整行忽高忽低。红色取 `palette.danger`——它在深浅两套主题里
/// 都是「红」，而强调色（薄荷绿 / 天蓝 / 蜜橙）用来标「喜欢」在不同主题下含义会跑偏。
class MusicFavoriteButton extends StatelessWidget {
  const MusicFavoriteButton({
    super.key,
    required this.favorited,
    this.onPressed,
  });

  final bool favorited;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: favorited ? context.l10n.musicUnlike : context.l10n.musicLike,
      child: SizedBox(
        width: 28,
        height: 28,
        child: IconButton(
          padding: EdgeInsets.zero,
          iconSize: 16,
          onPressed: onPressed,
          icon: Icon(
            favorited ? Icons.favorite : Icons.favorite_border,
            color: favorited
                ? context.palette.danger
                : context.palette.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// 「喜欢当前这首歌」：播放条 / 氛围音卡片上，紧挨在播放模式按钮左边那颗。
///
/// 和 [MusicFavoriteButton] 是同一套视觉，差别只有两点：
/// 图标跟「播放模式」同档大小（宽屏 20、窄屏 18），以及**没有在播的歌时禁用**——
/// 队列空的时候心形还留在原位，播放条不会因为少一颗按钮而跳一下。
class NowPlayingFavoriteButton extends StatelessWidget {
  const NowPlayingFavoriteButton({
    super.key,
    required this.favorites,
    required this.track,
    this.compact = false,
  });

  final MusicFavorites favorites;

  /// 这一条正在展示的歌（还没起播时就是队列里的下一首）。
  final MusicTrack? track;

  /// 手机窄屏：和播放模式按钮一起缩一档。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final current = track;
    final favorited = current != null && favorites.contains(current);
    return Tooltip(
      message: current == null
          ? context.l10n.musicNoTrackPlaying
          : (favorited ? context.l10n.musicUnlike : context.l10n.musicLikeThisSong),
      child: IconButton(
        onPressed: current == null ? null : () => favorites.toggle(current),
        iconSize: compact ? 18 : 20,
        visualDensity: VisualDensity.compact,
        icon: Icon(
          favorited ? Icons.favorite : Icons.favorite_border,
          color: favorited
              ? context.palette.danger
              : context.palette.textSecondary,
        ),
      ),
    );
  }
}

/// 专题卡（推荐页「为房间挑一首歌」）。
class MusicTopicCard extends StatelessWidget {
  const MusicTopicCard({
    super.key,
    required this.topic,
    this.onTap,
    this.width = 190,
    this.height = 112,
  });

  final MusicTopic topic;
  final VoidCallback? onTap;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final cover = topic.coverUrl;
    return SizedBox(
      width: width,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: ClipRRect(
            borderRadius: AppRadii.medium,
            child: SizedBox(
              height: height,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: context.palette.avatarGradientFor(topic.id.hashCode),
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                  ),
                  if (cover != null && cover.isNotEmpty)
                    Image.network(
                      cover,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  // 底部压一层暗角，保证文字在任何封面上都读得清
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Color(0xCC000000)],
                      ),
                    ),
                  ),
                  Positioned(
                    left: AppSpacing.sm,
                    right: AppSpacing.sm,
                    bottom: AppSpacing.sm,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          topic.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (topic.description != null &&
                            topic.description!.isNotEmpty)
                          Text(
                            topic.description!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xCCFFFFFF),
                              fontSize: 11,
                            ),
                          ),
                        const SizedBox(height: 6),
                        MusicBadge(
                          text: context.l10n.musicFreeSource,
                          color: context.palette.success,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 区块标题（比 [SectionLabel] 大一档，用于「为房间挑一首歌」「热门排行」这类）。
class MusicSectionTitle extends StatelessWidget {
  const MusicSectionTitle({super.key, required this.text, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: context.palette.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const Spacer(),
        ?trailing,
      ],
    );
  }
}

/// 空态：图标 + 一句话（+ 可选补充说明）。
class MusicEmptyHint extends StatelessWidget {
  const MusicEmptyHint({
    super.key,
    required this.icon,
    required this.text,
    this.hint,
  });

  final IconData icon;
  final String text;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 30, color: context.palette.textMuted),
            const SizedBox(height: AppSpacing.sm),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.palette.textSecondary,
                fontSize: 13,
              ),
            ),
            if (hint != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                hint!,
                textAlign: TextAlign.center,
                style: TextStyle(color: context.palette.textMuted, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 错误态：一句话 + 重试。
class MusicErrorHint extends StatelessWidget {
  const MusicErrorHint({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 30,
              color: context.palette.textMuted,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: context.palette.textSecondary, fontSize: 12),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: AppSpacing.sm),
              TextButton(onPressed: onRetry, child: Text(context.l10n.musicRetry)),
            ],
          ],
        ),
      ),
    );
  }
}

/// 列表加载中的占位（保持高度稳定，避免闪烁）。
class MusicLoading extends StatelessWidget {
  const MusicLoading({
    super.key,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.label,
  });

  final EdgeInsetsGeometry padding;

  /// 可选说明（如「正在加载 热歌榜」）。
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            if (label != null && label!.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                context.l10n.musicLoadingLabel(label!),
                style: TextStyle(
                  color: context.palette.textMuted,
                  fontSize: 11,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
