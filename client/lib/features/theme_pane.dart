import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_theme.dart';
import '../core/platform.dart';
import '../data/theme_store.dart';
import '../widgets/common.dart';
import 'pick_image.dart';

/// 主题页：卡片式选配色 + 上传壁纸。
///
/// 配色一改，整个应用（房间列表、通话、点歌台、设置、登录页）都跟着换：
/// 颜色全都从 `context.palette` 取，而它是 Theme 的一部分。
class ThemePane extends StatefulWidget {
  const ThemePane({super.key});

  @override
  State<ThemePane> createState() => _ThemePaneState();
}

class _ThemePaneState extends State<ThemePane> {
  /// 选图 / 写盘期间把按钮禁掉：连点会堆出一串选图框。
  bool _busy = false;

  /// 上次挑图的目录：再点「换一张」时从这里开始，不用每次从头翻。
  String? _lastDir;

  Future<void> _pickWallpaper() async {
    final store = context.read<ThemeStore>();
    final messenger = ScaffoldMessenger.of(context);
    final path = await pickImagePath(
      context,
      title: '选择壁纸图片',
      initialDirectory: _lastDir,
    );
    if (path == null || !mounted) {
      return;
    }
    _lastDir = File(path).parent.path;
    setState(() => _busy = true);
    try {
      final error = await store.applyWallpaperFile(path);
      if (error != null && mounted) {
        messenger.showSnackBar(SnackBar(content: Text(error)));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _clearWallpaper() async {
    final store = context.read<ThemeStore>();
    setState(() => _busy = true);
    try {
      await store.clearWallpaper();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _select(AppThemePack pack) async {
    final store = context.read<ThemeStore>();
    await store.select(pack.id);
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ThemeStore>();
    final palette = context.palette;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: AppSizes.pageHeader,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
          child: Row(
            children: [
              const Text('主题', style: AppText.pageTitle),
              const SizedBox(width: 10),
              Text(
                '当前 · ${store.pack.name}',
                style: TextStyle(
                  color: palette.textMuted,
                  fontSize: 11.5,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 880),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.page,
                  16,
                  AppSpacing.page,
                  AppSpacing.xl,
                ),
                children: [
                  PanelCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SectionLabel(text: '配色'),
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          '整套界面的配色，点一张就换。深色那几套夜里用眼睛舒服。',
                          style: TextStyle(
                            color: palette.textMuted,
                            fontSize: 11.5,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Wrap(
                          spacing: AppSpacing.md,
                          runSpacing: AppSpacing.md,
                          children: [
                            for (final pack in AppThemePacks.all)
                              _ThemeCard(
                                pack: pack,
                                selected: store.pack.id == pack.id,
                                onTap: () => _select(pack),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  PanelCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Expanded(child: SectionLabel(text: '壁纸')),
                            OutlinedButton.icon(
                              onPressed: _busy ? null : _pickWallpaper,
                              icon: const Icon(
                                Icons.image_outlined,
                                size: 15,
                              ),
                              label: Text(
                                _busy
                                    ? '正在处理…'
                                    : (store.hasWallpaper ? '换一张' : '选择图片'),
                              ),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(0, AppSizes.control),
                                textStyle: const TextStyle(fontSize: 12),
                              ),
                            ),
                            if (store.hasWallpaper) ...[
                              const SizedBox(width: AppSpacing.sm),
                              TextButton.icon(
                                onPressed: _busy ? null : _clearWallpaper,
                                icon: const Icon(Icons.close_rounded, size: 14),
                                label: const Text('移除'),
                                style: TextButton.styleFrom(
                                  minimumSize: const Size(0, AppSizes.control),
                                  foregroundColor: palette.textMuted,
                                  textStyle: const TextStyle(fontSize: 12),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: AppSpacing.md),
                        _WallpaperPreview(store: store),
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          '点「选择图片」挑一张本机图片（png / jpg / webp）。'
                          '壁纸会铺满整个应用窗口，卡片与侧栏自动变半透明让出画面；'
                          '图片压到长边 2400px 后存在本机，只影响这台电脑。',
                          style: TextStyle(
                            color: palette.textMuted,
                            fontSize: 11,
                            height: 1.6,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 一张主题卡片：上面是这套配色的缩略图，下面是名字与一句话说明。
class _ThemeCard extends StatefulWidget {
  const _ThemeCard({
    required this.pack,
    required this.selected,
    required this.onTap,
  });

  final AppThemePack pack;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ThemeCard> createState() => _ThemeCardState();
}

class _ThemeCardState extends State<_ThemeCard> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final selected = widget.selected;
    final border = selected
        ? palette.accent
        : (_hovering ? palette.divider : palette.hairline);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 130),
          // 手机上一行只放得下一张卡：固定 196dp 会留下一条空白，改成撑满
          // （Wrap 给的是松约束，double.infinity 会被收敛成可用宽，不会溢出）
          width: useCompactLayout(context) ? double.infinity : 196,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: _hovering && !selected
                ? palette.panelElevated
                : palette.panel,
            borderRadius: AppRadii.card,
            border: Border.all(color: border, width: selected ? 1.4 : 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _ThemePreview(pack: widget.pack),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.pack.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                    ),
                  ),
                  if (selected)
                    Icon(
                      Icons.check_circle_rounded,
                      size: 15,
                      color: palette.accent,
                    ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                widget.pack.tagline,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.textMuted,
                  fontSize: 11,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 主题缩略图：左导轨 + 中栏，用的全是**这套主题自己的**颜色，
/// 所以不看名字也能一眼分出绿白 / 绿黑 / 红白 / 蓝白 / 橙白。
class _ThemePreview extends StatelessWidget {
  const _ThemePreview({required this.pack});

  final AppThemePack pack;

  @override
  Widget build(BuildContext context) {
    final p = pack.palette;
    Widget bar(Color color, double width, {double height = 4}) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(2),
      ),
    );

    return ClipRRect(
      borderRadius: AppRadii.medium,
      child: Container(
        height: 84,
        decoration: BoxDecoration(
          color: p.stage,
          border: Border.all(color: p.hairline),
          borderRadius: AppRadii.medium,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 左导轨：一条选中态 + 两条普通行
            Container(
              width: 44,
              color: p.rail,
              padding: const EdgeInsets.fromLTRB(6, 7, 6, 7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 8,
                    decoration: BoxDecoration(
                      color: p.panelElevated,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 6),
                  bar(p.textMuted, 22),
                  const SizedBox(height: 5),
                  bar(p.textMuted.withValues(alpha: 0.6), 26),
                ],
              ),
            ),
            // 中栏：标题 + 一张卡片（卡片里带强调色）
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(7),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        bar(p.textPrimary.withValues(alpha: 0.8), 26, height: 5),
                        const Spacer(),
                        Container(
                          width: 18,
                          height: 8,
                          decoration: BoxDecoration(
                            color: p.accent,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: p.panel,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: p.divider),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            bar(p.accent, 14),
                            const SizedBox(height: 5),
                            bar(p.textSecondary, 44),
                            const SizedBox(height: 4),
                            bar(p.textMuted, 30),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 壁纸预览：贴了就是缩略图（带同样的蒙版），没贴就是一块空槽位。
class _WallpaperPreview extends StatelessWidget {
  const _WallpaperPreview({required this.store});

  final ThemeStore store;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final path = store.wallpaperPath;

    return Container(
      // 换图后强制重建一次（理由见 ThemeStore.wallpaperRevision）
      key: ValueKey<int>(store.wallpaperRevision),
      height: 132,
      decoration: BoxDecoration(
        color: palette.panelSubtle,
        borderRadius: AppRadii.medium,
        border: Border.all(color: palette.hairline),
        image: path == null
            ? null
            : DecorationImage(
                image: FileImage(File(path)),
                fit: BoxFit.cover,
                // 和真实背景同一层蒙版，缩略图看到的亮度就是实际效果
                colorFilter: ColorFilter.mode(
                  palette.wallpaperScrim,
                  BlendMode.srcOver,
                ),
              ),
      ),
      child: path == null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.wallpaper_rounded,
                    size: 22,
                    color: palette.textMuted,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '还没有壁纸',
                    style: TextStyle(
                      color: palette.textMuted,
                      fontSize: 11.5,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            )
          : null,
    );
  }
}
