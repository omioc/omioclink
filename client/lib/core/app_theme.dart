import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'theme_packs.dart';

export 'app_palette.dart';
export 'theme_packs.dart';

/// 圆角：控件 8、卡片 10、大块 14、胶囊 999。
abstract final class AppRadii {
  static const small = BorderRadius.all(Radius.circular(6));
  static const medium = BorderRadius.all(Radius.circular(8));
  static const card = BorderRadius.all(Radius.circular(10));
  static const large = BorderRadius.all(Radius.circular(14));
  static const pill = BorderRadius.all(Radius.circular(999));
}

/// 4px 栅格的间距刻度。
abstract final class AppSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;

  /// 页面统一内边距。
  static const page = 20.0;
}

/// 控件尺寸：全应用共用一套，避免按钮高一行矮一行。
abstract final class AppSizes {
  /// 标题栏高度。
  static const titleBar = 44.0;

  /// 按钮 / 输入框 / 分段控件的高度。
  static const control = 34.0;

  /// 左栏导航行高度。
  static const navRow = 34.0;

  /// 贴着窗口底部的横条总高（左栏用户页脚 / 点歌台播放条共用）。
  /// 两处都按这个值定高，顶部那条分隔线才会落在同一水平线上。
  static const bottomBar = 56.0;

  /// 侧栏宽度。
  static const sideRail = 248.0;

  /// 右栏宽度。
  static const infoRail = 288.0;

  /// 内容页头部高度。
  static const pageHeader = 60.0;
}

/// 字号只保留五档，全部 600 以上的字重只用于标题。
///
/// 这里只描述「字怎么排」，颜色一律由主题给（见 [AppTheme.data]）：
/// 深浅两套主题的文字色是反的，写死在 token 里等于把颜色钉在了代码上。
abstract final class AppText {
  static const pageTitle = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    height: 1.25,
    letterSpacing: 0.1,
  );

  static const section = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );

  static const body = TextStyle(fontSize: 13, height: 1.45);

  /// 输入框内文字：行高必须比正文更紧，否则会撑破固定高度的输入框。
  static const field = TextStyle(fontSize: 13, height: 1.35);

  static const label = TextStyle(fontSize: 12, height: 1.35);

  static const caption = TextStyle(fontSize: 11, height: 1.4);

  /// 数字 / 房间号这类等宽需求的小字。
  static const mono = TextStyle(
    fontSize: 11,
    height: 1.3,
    letterSpacing: 0.3,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

/// 取当前主题的色板：`context.palette.accent`。
///
/// 读的是 Theme，所以换主题时读过它的控件会自动重建；没有主题（控件测试里
/// 常直接 `MaterialApp(home: ...)`）时回落到默认色板，让「少一层主题」表现为
/// 颜色朴素，而不是空指针崩掉。
extension AppPaletteContext on BuildContext {
  AppPalette get palette =>
      Theme.of(this).extension<AppPalette>() ?? AppThemePacks.defaultPack.palette;
}

abstract final class AppTheme {
  /// 默认主题（薄荷汽水）。
  static ThemeData standard() => data(AppThemePacks.defaultPack.palette);

  /// 原来的深蓝主题（夜航）。少量控件测试按它比对颜色，保留这个入口。
  static ThemeData dark() => data(AppThemePacks.night.palette);

  /// 由色板拼出 Material 主题。
  ///
  /// 颜色一个都不能漏：Material 的默认值（按钮、菜单、滚动条、输入框……）
  /// 是按 colorScheme 现算的，浅色主题下会冒出 Material 的紫和蓝，
  /// 所以按钮、菜单、开关这些组件逐个钉成色板里的颜色。
  static ThemeData data(AppPalette palette) {
    final scheme = ColorScheme(
      brightness: palette.brightness,
      primary: palette.accent,
      onPrimary: palette.onAccent,
      primaryContainer: palette.accentSoft,
      onPrimaryContainer: palette.textPrimary,
      secondary: palette.accentDeep,
      onSecondary: palette.onAccent,
      surface: palette.panel,
      onSurface: palette.textPrimary,
      surfaceContainerHighest: palette.panelElevated,
      onSurfaceVariant: palette.textSecondary,
      outline: palette.hairline,
      error: palette.danger,
      onError: Colors.white,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: palette.brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: palette.stage,
      canvasColor: palette.stage,
      dividerColor: palette.hairline,
      splashFactory: NoSplash.splashFactory,
      // 不用 VisualDensity.compact：它会把按钮可见高度再削 8px，
      // 于是「按钮 32 / 输入框 28」这种错位就出现了。尺寸由 AppSizes 统一给。
      visualDensity: VisualDensity.standard,
      fontFamilyFallback: const [
        'Microsoft YaHei UI',
        'Microsoft YaHei',
        'PingFang SC',
        'Noto Sans CJK SC',
      ],
    );

    return base.copyWith(
      // 换主题时在这两套色板之间插值（见 AppPalette.lerp），界面是渐变过去的
      extensions: [palette],
      textTheme: base.textTheme
          .apply(
            bodyColor: palette.textPrimary,
            displayColor: palette.textPrimary,
          )
          .copyWith(
            // 输入框没写 style 时用的是 bodyLarge：这里把它定成和界面一致的
            // 13px / 1.35，行高才不会撑破 34px 的框（撑破后文字会被压到底部）
            bodyLarge: AppText.field.copyWith(color: palette.textPrimary),
            // 这两档必须显式给颜色：AppText 里的样式不带颜色，直接塞进来会把
            // 上面 apply() 打上的 bodyColor 覆盖掉，于是没写 color 的 Text
            // （页面标题、好友昵称……）在深色主题里会掉成黑字
            titleMedium: AppText.section.copyWith(color: palette.textPrimary),
            bodyMedium: AppText.body.copyWith(color: palette.textPrimary),
            bodySmall: AppText.label.copyWith(color: palette.textSecondary),
            labelSmall: AppText.caption.copyWith(color: palette.textMuted),
          ),
      iconTheme: IconThemeData(color: palette.textSecondary, size: 17),
      dividerTheme: DividerThemeData(
        color: palette.hairline,
        thickness: 1,
        space: 1,
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: palette.accent,
        selectionColor: palette.accentSoft,
        selectionHandleColor: palette.accent,
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        decoration: BoxDecoration(
          color: palette.panelElevated,
          borderRadius: AppRadii.small,
          border: Border.all(color: palette.divider),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        textStyle: TextStyle(
          color: palette.textPrimary,
          fontSize: 11.5,
          height: 1.3,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.panelSubtle,
        isDense: false,
        // 输入框和按钮钉死同一档高度：填充块只按内容算，不加这条会自己缩一截，
        // 和旁边的按钮差 3~4px，看上去就是「没对齐」。
        constraints: const BoxConstraints(
          minHeight: AppSizes.control,
          maxHeight: AppSizes.control,
        ),
        // 上下留白取 (控件高 - 文字行高)/2：内容正好填满固定高度的框，
        // 文字自然垂直居中，不依赖 textAlignVertical（主题里没有这个字段）。
        hintStyle: TextStyle(color: palette.textMuted, fontSize: 12.5),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        prefixIconColor: palette.textMuted,
        suffixIconColor: palette.textMuted,
        prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 16),
        suffixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 16),
        border: OutlineInputBorder(
          borderRadius: AppRadii.medium,
          borderSide: BorderSide(color: palette.hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadii.medium,
          borderSide: BorderSide(color: palette.hairline),
        ),
        hoverColor: palette.panelElevated,
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadii.medium,
          borderSide: BorderSide(color: palette.accent, width: 1.2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: AppRadii.medium,
          borderSide: BorderSide(color: palette.danger, width: 1.2),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: AppRadii.medium,
          borderSide: BorderSide(color: palette.danger, width: 1.2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: palette.accent,
          // 亮强调色（薄荷、橙）上必须换深色字，白字读不出来
          foregroundColor: palette.onAccent,
          disabledBackgroundColor: palette.panelSubtle,
          disabledForegroundColor: palette.textMuted,
          elevation: 0,
          minimumSize: const Size(0, AppSizes.control),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          shape: const RoundedRectangleBorder(borderRadius: AppRadii.medium),
          textStyle: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.2,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: palette.textSecondary,
          minimumSize: const Size(0, AppSizes.control),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          shape: const RoundedRectangleBorder(borderRadius: AppRadii.medium),
          textStyle: const TextStyle(fontSize: 13),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: palette.textPrimary,
          side: BorderSide(color: palette.divider),
          minimumSize: const Size(0, AppSizes.control),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          shape: const RoundedRectangleBorder(borderRadius: AppRadii.medium),
          textStyle: const TextStyle(fontSize: 13, letterSpacing: 0.2),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: palette.textSecondary,
          minimumSize: const Size(28, 28),
          padding: EdgeInsets.zero,
          shape: const RoundedRectangleBorder(borderRadius: AppRadii.small),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? palette.onAccent
              : palette.textSecondary,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? palette.accent
              : palette.panelSubtle,
        ),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      sliderTheme: SliderThemeData(
        // 音量推子用中性色：绿色留给「正在说话」的电平，控制件上不用语义色
        activeTrackColor: palette.textSecondary,
        inactiveTrackColor: palette.panelSubtle,
        thumbColor: palette.textPrimary,
        trackHeight: 3,
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayColor: palette.textPrimary.withValues(alpha: 0.10),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: palette.accent,
        linearMinHeight: 3,
        strokeWidth: 2,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(
          palette.textMuted.withValues(alpha: 0.35),
        ),
        thickness: const WidgetStatePropertyAll(5),
        radius: const Radius.circular(3),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: palette.panelElevated,
        contentTextStyle: TextStyle(color: palette.textPrimary, fontSize: 12.5),
        behavior: SnackBarBehavior.floating,
        width: 360,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadii.medium,
          side: BorderSide(color: palette.divider),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: palette.panel,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: AppRadii.large),
        // 对话框标题比 Material 默认的 22px 收一档，和界面里的字号体系对齐
        titleTextStyle: TextStyle(
          color: palette.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w600,
          height: 1.35,
        ),
        contentTextStyle: TextStyle(
          color: palette.textSecondary,
          fontSize: 12.5,
          height: 1.6,
        ),
        insetPadding: const EdgeInsets.all(24),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: palette.panelElevated,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadii.medium,
          side: BorderSide(color: palette.divider),
        ),
        textStyle: TextStyle(color: palette.textPrimary, fontSize: 12.5),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(palette.panelElevated),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(0),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: AppRadii.medium,
              side: BorderSide(color: palette.divider),
            ),
          ),
        ),
      ),
    );
  }
}
