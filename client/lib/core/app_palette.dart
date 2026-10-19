import 'package:flutter/material.dart';

/// 一套主题的「源头配色」。
///
/// 这里只手写九个色值（强调色两档 + 三层表面 + 三档文字色），其余全部由
/// [AppPalette.fromPack] 按亮度推导。为什么要推导：六套主题 × 十几个色值
/// 等于六十处可能调歪的地方，而「抬一格的卡片底」「比面板深一档的发丝线」
/// 这类关系在深浅两种底色下的方向是相反的（深色越亮越显眼，浅色越暗越显眼），
/// 写成公式才不会一套主题里出现「浅色底 + 更亮的边框」这种倒挂。
class AppThemePack {
  AppThemePack({
    required this.id,
    required this.name,
    required this.tagline,
    required this.brightness,
    required this.accent,
    required this.accentDeep,
    required this.stage,
    required this.rail,
    required this.panel,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
  });

  /// 落盘的稳定 id：以后改名字不能改它，否则老用户存的主题会读不出来。
  final String id;

  /// 卡片上显示的名字。
  final String name;

  /// 卡片上的一句话说明，控制在 14 个字以内（卡片宽度只放得下两行小字）。
  final String tagline;

  final Brightness brightness;

  /// 唯一的强调色：主操作、当前选中项、链接。
  final Color accent;

  /// 强调色的深一档：按下态、需要更重的强调时用。
  final Color accentDeep;

  /// 舞台：中栏内容区。
  final Color stage;

  /// 左右两条导轨（左导航 / 右信息栏）与标题栏。
  final Color rail;

  /// 卡片。
  final Color panel;

  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;

  /// 算好的运行时色板。缓存在主题包上：换主题时才需要重算，
  /// 每帧重算会让 `context.palette.xxx` 这些调用的代价从「读字段」变成「建对象」。
  late final AppPalette palette = AppPalette.fromPack(this);
}

/// 运行时色板：界面里所有颜色都从这里取（`context.palette.xxx`）。
///
/// 为什么做成 [ThemeExtension] 而不是一组全局常量：主题要能随时换，而 `const`
/// 常量换不了。挂在 Theme 上还顺带解决了「换了主题谁该重画」——Flutter 会通知
/// 所有读过它的控件重建，不需要谁记得去 setState，也不会漏掉那些 const 子树。
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.brightness,
    required this.stage,
    required this.rail,
    required this.panel,
    required this.panelElevated,
    required this.panelSubtle,
    required this.hairline,
    required this.divider,
    required this.accent,
    required this.accentDeep,
    required this.accentSoft,
    required this.onAccent,
    required this.success,
    required this.warning,
    required this.danger,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.hover,
    required this.wallpaperScrim,
  });

  final Brightness brightness;

  /// 舞台：中栏内容区，也是最深的一层。贴了壁纸之后它是透明的。
  final Color stage;

  /// 左右两条导轨（左导航 / 右信息栏 / 标题栏）。
  final Color rail;

  /// 卡片。
  final Color panel;

  /// 卡片被选中 / 悬停时抬一格。
  final Color panelElevated;

  /// 输入框、分段控件这类「陷进去」的表面。
  final Color panelSubtle;

  /// 发丝线：描边用。
  final Color hairline;

  /// 分隔线：比 [hairline] 重一档，用在结构性分割上。
  final Color divider;

  /// 唯一的强调色。屏幕上只允许出现一次（主操作或当前选中项）。
  final Color accent;
  final Color accentDeep;

  /// 选中态背景：低饱和的强调色底，取代原来的实心胶囊。
  final Color accentSoft;

  /// 压在强调色上的字和图标：薄荷这类亮强调色必须用深色字才看得清。
  final Color onAccent;

  /// 语义色：只用来表达状态，不做装饰。
  final Color success;
  final Color warning;
  final Color danger;

  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;

  /// 悬停底色（半透明，叠在任何表面上都成立）。
  final Color hover;

  /// 壁纸之上的蒙版：不压一层的话，正文落在花哨的图上完全读不出来。
  final Color wallpaperScrim;

  /// 应用底色（与舞台同色，保留旧名以兼容既有引用）。
  Color get background => stage;

  /// 左栏导轨（旧名）。
  Color get sidebar => rail;

  /// 分段控件的「槽底」。
  ///
  /// 平时它就是舞台色（比两侧导轨再深一档，看起来是陷进去的）。贴了壁纸之后
  /// 舞台是全透明的，直接用会让槽变成一个只有描边的空框，所以退成一层半透明底：
  /// 深色主题压黑、浅色主题提白。
  Color get track => stage.a == 0
      ? (isLight
            ? Colors.white.withValues(alpha: 0.55)
            : Colors.black.withValues(alpha: 0.35))
      : stage;

  bool get isLight => brightness == Brightness.light;

  /// 成员头像兜底渐变（按 userId 取模）。头像上永远写白字，深浅主题通用。
  static const List<List<Color>> avatarGradients = <List<Color>>[
    [Color(0xFF5B7CFA), Color(0xFF8B5CF6)],
    [Color(0xFFF59E0B), Color(0xFFF87171)],
    [Color(0xFF34D399), Color(0xFF22D3EE)],
    [Color(0xFFEC4899), Color(0xFF8B5CF6)],
    [Color(0xFF38BDF8), Color(0xFF4C6FFF)],
    [Color(0xFFFBBF24), Color(0xFFF97316)],
  ];

  List<Color> avatarGradientFor(int seed) =>
      avatarGradients[seed.abs() % avatarGradients.length];

  /// 由主题包推导出整套色板。
  static AppPalette fromPack(AppThemePack pack) {
    final light = pack.brightness == Brightness.light;
    final panel = pack.panel;

    // 选中 / 悬停那一格：浅色主题用一层淡淡的强调色（灰底在白面板上认不出来），
    // 深色主题沿用「提亮一点」的做法。
    final panelElevated = light
        ? _blend(panel, pack.accent, 0.10)
        : _blend(panel, pack.textPrimary, 0.055);
    // 陷进去的表面（输入框 / 分段槽）：深色主题提亮一档，浅色主题压深一档。
    // 同一个系数两个方向都成立——叠的是「文字色」，深色主题的文字是浅的，
    // 浅色主题的文字是深的。系数从 0.045 提到 0.075：左栏是近白的导轨，
    // 搜索框只压 4.5% 的话跟导轨糊在一起，只剩一根描边。
    final panelSubtle = _blend(panel, pack.textPrimary, 0.075);

    return AppPalette(
      brightness: pack.brightness,
      stage: pack.stage,
      rail: pack.rail,
      panel: panel,
      panelElevated: panelElevated,
      panelSubtle: panelSubtle,
      // 描边从**导轨**色推导，而不是卡片色：浅色主题里卡片是纯白，从白推导出来的
      // 线（#E7E7E7）落在带色调的舞台上几乎看不见，卡片边界就没了。
      hairline: light
          ? _blend(pack.rail, pack.textPrimary, 0.12)
          : _blend(panel, pack.textPrimary, 0.05),
      divider: light
          ? _blend(pack.rail, pack.textPrimary, 0.18)
          : _blend(panel, pack.textPrimary, 0.075),
      accent: pack.accent,
      accentDeep: pack.accentDeep,
      accentSoft: _blend(panel, pack.accent, 0.16),
      // 黑白各给一档、按亮度挑：阈值取在「白字与深墨字对比度相等」的位置稍偏亮处
      // （等值点约 0.21），橙/绿/天蓝这类亮强调色因此换深墨字——白字压在上面
      // 只有 2.4~2.7:1，按钮上的字基本糊掉。朱砂与夜航的强调色偏深，仍用白字。
      onAccent: pack.accent.computeLuminance() > 0.25
          ? const Color(0xFF10201A)
          : Colors.white,
      // 语义色不跟着强调色走（红永远是红），只按深浅各给一档：
      // 深色底上用亮一档的，浅色底上用沉一档的，否则在白底上刺眼、在深底上发灰。
      success: light ? const Color(0xFF1F9E68) : const Color(0xFF3ED598),
      warning: light ? const Color(0xFFBF7414) : const Color(0xFFF0A94C),
      danger: light ? const Color(0xFFD2453C) : const Color(0xFFF2706B),
      textPrimary: pack.textPrimary,
      textSecondary: pack.textSecondary,
      textMuted: pack.textMuted,
      hover: light
          ? pack.textPrimary.withValues(alpha: 0.05)
          : Colors.white.withValues(alpha: 0.05),
      // 蒙版不能用纯白：白蒙版压在照片上就是一层灰雾，浅色主题整窗发脏。
      // 用舞台色当蒙版，照片被「染」成主题色的一层淡纹，看着像设计的一部分。
      wallpaperScrim: light
          ? pack.stage.withValues(alpha: 0.80)
          : Colors.black.withValues(alpha: 0.75),
    );
  }

  /// 贴了壁纸之后的版本：表面让出一点透明度，壁纸才透得出来。
  ///
  /// 舞台直接透明——壁纸画在 Scaffold 的 body 里，舞台底再罩一层就把图盖住了。
  /// 深浅两套的透明度相反：深色主题的卡片半透才好看（图在深色里像暗纹）；
  /// 浅色主题的白卡片一旦半透，底下的图会把它染成灰雾、边界全糊，所以留 0.9 以上。
  AppPalette withWallpaper() {
    final light = isLight;
    return copyWith(
      stage: stage.withValues(alpha: 0),
      rail: rail.withValues(alpha: light ? 0.92 : 0.78),
      panel: panel.withValues(alpha: light ? 0.96 : 0.86),
      panelElevated: panelElevated.withValues(alpha: light ? 0.97 : 0.92),
      panelSubtle: panelSubtle.withValues(alpha: light ? 0.80 : 0.62),
      hairline: hairline.withValues(alpha: light ? 0.70 : 0.55),
      divider: divider.withValues(alpha: light ? 0.70 : 0.55),
    );
  }

  /// 往 [base] 上叠一层 [over]，压出实色。
  ///
  /// 用 alphaBlend 而不是给颜色留 alpha：卡片底色必须是实色的，否则深色卡片
  /// 落在同色系的舞台上会自己变淡，两层之间的「一格」就没了。
  static Color _blend(Color base, Color over, double alpha) =>
      Color.alphaBlend(over.withValues(alpha: alpha), base);

  @override
  AppPalette copyWith({
    Brightness? brightness,
    Color? stage,
    Color? rail,
    Color? panel,
    Color? panelElevated,
    Color? panelSubtle,
    Color? hairline,
    Color? divider,
    Color? accent,
    Color? accentDeep,
    Color? accentSoft,
    Color? onAccent,
    Color? success,
    Color? warning,
    Color? danger,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? hover,
    Color? wallpaperScrim,
  }) {
    return AppPalette(
      brightness: brightness ?? this.brightness,
      stage: stage ?? this.stage,
      rail: rail ?? this.rail,
      panel: panel ?? this.panel,
      panelElevated: panelElevated ?? this.panelElevated,
      panelSubtle: panelSubtle ?? this.panelSubtle,
      hairline: hairline ?? this.hairline,
      divider: divider ?? this.divider,
      accent: accent ?? this.accent,
      accentDeep: accentDeep ?? this.accentDeep,
      accentSoft: accentSoft ?? this.accentSoft,
      onAccent: onAccent ?? this.onAccent,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      hover: hover ?? this.hover,
      wallpaperScrim: wallpaperScrim ?? this.wallpaperScrim,
    );
  }

  /// 换主题时 MaterialApp 会在这两套色板之间做一次插值，界面是「渐变」过去的，
  /// 不是硬切；因此这里必须把每个字段都插上，漏掉的那个字段会瞬间跳变。
  @override
  AppPalette lerp(covariant AppPalette? other, double t) {
    if (other == null) {
      return this;
    }
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppPalette(
      brightness: t < 0.5 ? brightness : other.brightness,
      stage: mix(stage, other.stage),
      rail: mix(rail, other.rail),
      panel: mix(panel, other.panel),
      panelElevated: mix(panelElevated, other.panelElevated),
      panelSubtle: mix(panelSubtle, other.panelSubtle),
      hairline: mix(hairline, other.hairline),
      divider: mix(divider, other.divider),
      accent: mix(accent, other.accent),
      accentDeep: mix(accentDeep, other.accentDeep),
      accentSoft: mix(accentSoft, other.accentSoft),
      onAccent: mix(onAccent, other.onAccent),
      success: mix(success, other.success),
      warning: mix(warning, other.warning),
      danger: mix(danger, other.danger),
      textPrimary: mix(textPrimary, other.textPrimary),
      textSecondary: mix(textSecondary, other.textSecondary),
      textMuted: mix(textMuted, other.textMuted),
      hover: mix(hover, other.hover),
      wallpaperScrim: mix(wallpaperScrim, other.wallpaperScrim),
    );
  }
}
