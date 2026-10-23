import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_locales.dart';
import '../core/app_theme.dart';
import '../core/l10n_ext.dart';
import '../core/platform.dart';
import '../data/locale_store.dart';
import '../data/theme_store.dart';
import '../l10n/generated/app_l10n.dart';
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
      title: context.l10n.pickWallpaperTitle,
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

  Future<void> _selectLanguage(String code) async {
    await context.read<LocaleStore>().select(code);
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ThemeStore>();
    final palette = context.palette;
    final l10n = context.l10n;
    // 命名成 localeStore 而不是 locale：下面下拉的 for 里已有 locale 变量
    final localeStore = context.watch<LocaleStore>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: AppSizes.pageHeader,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
          child: Row(
            children: [
              Text(l10n.themePaneTitle, style: AppText.pageTitle),
              const SizedBox(width: 10),
              // 主题名可能很长（小语种尤其），用剩余宽度并省略，
              // 否则窄屏上会把页头的语言下拉挤出可视区域
              Expanded(
                child: Text(
                  l10n.themePaneCurrent(_packName(l10n, store.pack)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.textMuted,
                    fontSize: 11.5,
                    height: 1.2,
                  ),
                ),
              ),
              // 语言切换放页头：配色与语言是这一页最常用的两个开关，都在第一屏，
              // 不用滚到列表底部；下拉沿用设置页那套（isDense + 去掉下划线）
              Tooltip(
                message: l10n.languageSection,
                child: DropdownButton<String>(
                  value: localeStore.selection,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  borderRadius: AppRadii.medium,
                  dropdownColor: palette.panelElevated,
                  style: TextStyle(color: palette.textSecondary, fontSize: 12),
                  icon: Icon(
                    Icons.language_rounded,
                    size: 15,
                    color: palette.textMuted,
                  ),
                  items: [
                    for (final code in <String>[
                      AppLocales.system,
                      for (final supported in AppLocales.supported)
                        supported.languageCode,
                    ])
                      DropdownMenuItem<String>(
                        value: code,
                        child: Text(
                          code == AppLocales.system
                              ? l10n.languageSystem
                              : AppLocales.nativeName(code),
                        ),
                      ),
                  ],
                  onChanged: (code) {
                    if (code != null) {
                      unawaited(_selectLanguage(code));
                    }
                  },
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
                        SectionLabel(text: l10n.themeSectionColor),
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          l10n.themeSectionColorHint,
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
                            Expanded(
                              child: SectionLabel(text: l10n.themeSectionWallpaper),
                            ),
                            OutlinedButton.icon(
                              onPressed: _busy ? null : _pickWallpaper,
                              icon: const Icon(
                                Icons.image_outlined,
                                size: 15,
                              ),
                              label: Text(
                                _busy
                                    ? l10n.wallpaperBusy
                                    : (store.hasWallpaper
                                          ? l10n.wallpaperChange
                                          : l10n.wallpaperPick),
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
                                label: Text(context.l10n.wallpaperRemove),
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
                          context.l10n.wallpaperHint,
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
                      _packName(context.l10n, widget.pack),
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
                _packTagline(context.l10n, widget.pack),
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
                    context.l10n.wallpaperEmpty,
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

/// 主题包的名字与一句话说明走文案表。
///
/// `theme_packs.dart` 里那份中文留给日志和「拿不到本地化」的兜底，
/// 界面上一律按 id 取当前语言的版本。
String _packName(AppL10n l10n, AppThemePack pack) => switch (pack.id) {
  'soda' => l10n.packSodaName,
  'qingzhu' => l10n.packQingzhuName,
  'cinnabar' => l10n.packCinnabarName,
  'sky' => l10n.packSkyName,
  'honey' => l10n.packHoneyName,
  'night' => l10n.packNightName,
  _ => pack.name,
};

String _packTagline(AppL10n l10n, AppThemePack pack) => switch (pack.id) {
  'soda' => l10n.packSodaTagline,
  'qingzhu' => l10n.packQingzhuTagline,
  'cinnabar' => l10n.packCinnabarTagline,
  'sky' => l10n.packSkyTagline,
  'honey' => l10n.packHoneyTagline,
  'night' => l10n.packNightTagline,
  _ => pack.tagline,
};
