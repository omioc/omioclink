import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/core/app_theme.dart';

/// WCAG 对比度：1 最差、21 最好。用它替代「肉眼看一眼」——
/// 主题是深色浅色混着来的，靠人眼过一遍根本挡不住「浅色底上写了浅色字」。
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  test('内置主题：id 与名字都不重复，默认那套排第一', () {
    final ids = AppThemePacks.all.map((p) => p.id).toSet();
    final names = AppThemePacks.all.map((p) => p.name).toSet();
    expect(ids.length, AppThemePacks.all.length);
    expect(names.length, AppThemePacks.all.length);
    expect(AppThemePacks.all.first.id, AppThemePacks.defaultPack.id);
    expect(AppThemePacks.byId(null).id, AppThemePacks.defaultPack.id);
    expect(AppThemePacks.byId('没有这套').id, AppThemePacks.defaultPack.id);
    expect(AppThemePacks.byId(AppThemePacks.soda.id).name, '薄荷汽水');
  });

  test('每套主题的层次都成立：抬一格的卡片底、发丝线、强调淡底都与卡片本身不同', () {
    for (final pack in AppThemePacks.all) {
      final p = pack.palette;
      expect(p.panelElevated, isNot(p.panel), reason: '${pack.name} 选中态看不出来');
      expect(p.panelSubtle, isNot(p.panel), reason: '${pack.name} 输入框没有陷进去');
      expect(p.hairline, isNot(p.panel), reason: '${pack.name} 画不出描边');
      expect(p.accentSoft, isNot(p.panel), reason: '${pack.name} 没有强调淡底');
      // 按钮字就压在强调色上：白字配亮绿/亮橙只有 2.4:1，必须按亮度挑深墨字
      expect(
        _contrast(p.onAccent, p.accent),
        greaterThan(3.4),
        reason: '${pack.name} 主按钮上的字看不清',
      );
    }
  });

  test('每套主题的三层底色分得开：舞台 < 导轨 < 卡片（不许糊成一片白）', () {
    for (final pack in AppThemePacks.all) {
      final p = pack.palette;
      double lum(Color c) => c.computeLuminance();
      expect(p.stage, isNot(p.rail), reason: '${pack.name} 导轨与舞台同色');
      expect(p.rail, isNot(p.panel), reason: '${pack.name} 卡片与导轨同色');
      expect(
        lum(p.stage),
        lessThan(lum(p.rail)),
        reason: '${pack.name} 舞台要比导轨深一档',
      );
      expect(
        lum(p.rail),
        lessThan(lum(p.panel)),
        reason: '${pack.name} 卡片要比导轨亮一档',
      );
      // 卡片自己那条描边（原有设计里就有）落在卡片色上要看得出差别
      expect(
        _contrast(p.hairline, p.panel),
        greaterThan(1.08),
        reason: '${pack.name} 卡片描边看不见',
      );
    }
  });

  test('每套主题的正文、次要、弱化文字落在卡片上都读得出来', () {
    for (final pack in AppThemePacks.all) {
      final p = pack.palette;
      expect(
        _contrast(p.textPrimary, p.panel),
        greaterThan(7),
        reason: '${pack.name} 正文对比度太低',
      );
      expect(
        _contrast(p.textSecondary, p.panel),
        greaterThan(4.5),
        reason: '${pack.name} 次要文字对比度太低',
      );
      // 弱化文字是「想弱一点」的，放宽到 2.8：再低就真的看不清了
      expect(
        _contrast(p.textMuted, p.panel),
        greaterThan(2.8),
        reason: '${pack.name} 弱化文字几乎不可见',
      );
      // 舞台上（页面标题、空状态提示）也直接落着文字，同样得撑住
      expect(
        _contrast(p.textPrimary, p.stage),
        greaterThan(5),
        reason: '${pack.name} 舞台上的标题对比度太低',
      );
      expect(
        _contrast(p.textMuted, p.stage),
        greaterThan(2.2),
        reason: '${pack.name} 舞台上的弱化文字看不清',
      );
    }
  });

  test('贴壁纸之后：舞台透明、导轨与卡片半透明、蒙版有透明度', () {
    final base = AppThemePacks.standard.palette;
    final papered = base.withWallpaper();
    expect(papered.stage.a, 0, reason: '舞台不透，壁纸就被盖住了');
    expect(papered.rail.a, lessThan(1));
    expect(papered.panel.a, lessThan(1));
    expect(papered.panel.a, greaterThan(papered.stage.a));
    expect(papered.wallpaperScrim.a, greaterThan(0));
    // 强调色与文字色不该被壁纸改动：那是主题的事
    expect(papered.accent, base.accent);
    expect(papered.textPrimary, base.textPrimary);
  });

  test('分段控件的槽底：没壁纸时就是舞台色，贴壁纸后仍然有底', () {
    final base = AppThemePacks.standard.palette;
    expect(base.track, base.stage);
    final papered = base.withWallpaper();
    expect(papered.track.a, greaterThan(0), reason: '槽底全透明就只剩一个空框');
    expect(papered.track.a, lessThan(1), reason: '槽底要透出壁纸');
  });

  test('主题切换的插值：走到头就是目标色板', () {
    final from = AppThemePacks.standard.palette;
    final to = AppThemePacks.soda.palette;
    final mixed = from.lerp(to, 1);
    expect(mixed.accent, to.accent);
    expect(mixed.panel, to.panel);
    expect(mixed.textPrimary, to.textPrimary);
    expect(from.lerp(to, 0.5).accent, isNot(from.accent));
  });

  test('ThemeData 里带着色板，亮度和强调色都对得上', () {
    final theme = AppTheme.data(AppThemePacks.honey.palette);
    final palette = theme.extension<AppPalette>();
    expect(palette, isNotNull);
    expect(palette!.accent, AppThemePacks.honey.accent);
    expect(theme.brightness, Brightness.light);
    // 深色那套要能把 Material 的默认浅色也反过来
    expect(AppTheme.data(AppThemePacks.night.palette).brightness, Brightness.dark);
  });
}
