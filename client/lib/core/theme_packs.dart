import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'platform.dart';

/// 内置主题包。
///
/// 命名走「意象」而不是「像谁」：这几套配色是照着常见音乐软件的调子调的，
/// 但把它们当作独立的主题来卖，比挂别人的名字更合适。
/// 顺序即主题页的出场顺序：薄荷汽水排第一（桌面默认主题），青竹是手机默认。
abstract final class AppThemePacks {
  /// 薄荷汽水（绿黑）：桌面端的默认主题。
  ///
  /// 选深色这套当桌面默认：应用里有大量深色场景（通话、共享画面、点歌台封面），
  /// 浅色主题在这些地方要靠蒙版硬压，深色底是更省事也更稳的起点。
  static final AppThemePack soda = AppThemePack(
    id: 'soda',
    name: '薄荷汽水',
    tagline: '墨黑底 · 荧光薄荷，默认',
    brightness: Brightness.dark,
    accent: const Color(0xFF2BE59B),
    accentDeep: const Color(0xFF16A872),
    stage: const Color(0xFF070C0A),
    rail: const Color(0xFF0C1310),
    panel: const Color(0xFF111916),
    textPrimary: const Color(0xFFE6F5ED),
    textSecondary: const Color(0xFF95AC9F),
    textMuted: const Color(0xFF61776B),
  );

  /// 没得选的时候（新用户、存的主题 id 认不出来）用它。
  ///
  /// 手机上默认「青竹」：小屏又是自发光，深色底在强光下更难看清；
  /// 桌面端保持原来的「薄荷汽水」。用户手动选过之后按 `ThemeStore` 里存的 id 来，
  /// 这里只管「一次都没选过」的情况。
  static AppThemePack get defaultPack => isMobilePlatform ? standard : soda;

  /// 青竹（绿白）。
  static final AppThemePack standard = AppThemePack(
    id: 'qingzhu',
    name: '青竹',
    tagline: '青白底 · 草绿强调',
    brightness: Brightness.light,
    accent: const Color(0xFF22B573),
    accentDeep: const Color(0xFF128A55),
    // 浅色主题的层次是深色的镜像：舞台偏深（带主色调）、导轨近白、卡片纯白。
    // 三层都给纯白的话，贴纸之后卡片和背景就糊成一片了；档位按「亮度差约 10%」
    // 取，和深色那边（舞台 0.05 → 导轨 0.09 → 卡片 0.13）保持同一分寸。
    stage: const Color(0xFFE3EBE6),
    rail: const Color(0xFFF3F7F4),
    panel: const Color(0xFFFFFFFF),
    textPrimary: const Color(0xFF16211B),
    textSecondary: const Color(0xFF55685D),
    textMuted: const Color(0xFF7B8A81),
  );

  /// 朱砂（红白）。
  static final AppThemePack cinnabar = AppThemePack(
    id: 'cinnabar',
    name: '朱砂',
    tagline: '暖白底 · 朱红强调',
    brightness: Brightness.light,
    accent: const Color(0xFFE13B34),
    accentDeep: const Color(0xFFA92620),
    stage: const Color(0xFFEDE2E1),
    rail: const Color(0xFFF8F3F2),
    panel: const Color(0xFFFFFFFF),
    textPrimary: const Color(0xFF221615),
    textSecondary: const Color(0xFF6B5957),
    textMuted: const Color(0xFF8F7E7C),
  );

  /// 晴空（蓝白）。
  static final AppThemePack sky = AppThemePack(
    id: 'sky',
    name: '晴空',
    tagline: '冷白底 · 天蓝强调',
    brightness: Brightness.light,
    accent: const Color(0xFF2A8CF0),
    accentDeep: const Color(0xFF1560B4),
    stage: const Color(0xFFE1EAF5),
    rail: const Color(0xFFF2F7FC),
    panel: const Color(0xFFFFFFFF),
    textPrimary: const Color(0xFF131F2B),
    textSecondary: const Color(0xFF516475),
    textMuted: const Color(0xFF7E8C9A),
  );

  /// 蜜橙（橙白）。
  static final AppThemePack honey = AppThemePack(
    id: 'honey',
    name: '蜜橙',
    tagline: '米白底 · 暖橙强调',
    brightness: Brightness.light,
    accent: const Color(0xFFF2921D),
    accentDeep: const Color(0xFFC2690A),
    stage: const Color(0xFFEDE5D8),
    rail: const Color(0xFFF9F5EC),
    panel: const Color(0xFFFFFFFF),
    textPrimary: const Color(0xFF291E13),
    textSecondary: const Color(0xFF6D5B48),
    textMuted: const Color(0xFF91806E),
  );

  /// 夜航（深蓝）：原来的界面配色，留一套省得老用户不适应。
  static final AppThemePack night = AppThemePack(
    id: 'night',
    name: '夜航',
    tagline: '深蓝底 · 星蓝强调，原界面',
    brightness: Brightness.dark,
    accent: const Color(0xFF5B7BFF),
    accentDeep: const Color(0xFF3D57D6),
    stage: const Color(0xFF0A0F16),
    rail: const Color(0xFF0F161F),
    panel: const Color(0xFF141C26),
    textPrimary: const Color(0xFFE9EFF6),
    textSecondary: const Color(0xFF96A5B8),
    textMuted: const Color(0xFF63707F),
  );

  /// 主题页按这个顺序铺卡片。
  static final List<AppThemePack> all = <AppThemePack>[
    soda,
    standard,
    cinnabar,
    sky,
    honey,
    night,
  ];

  /// 按 id 取主题包；id 认不出来（旧版本残留、手改过）时回落到默认主题，
  /// 不让「存了一个不存在的主题」变成起不来的白屏。
  static AppThemePack byId(String? id) {
    for (final pack in all) {
      if (pack.id == id) {
        return pack;
      }
    }
    return defaultPack;
  }
}
