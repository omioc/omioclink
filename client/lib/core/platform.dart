import 'dart:io';

import 'package:flutter/widgets.dart';

/// 只有桌面端才有的能力：窗口管理、注册表里读系统代理、屏幕共享的原生部分。
///
/// 这些插件在安卓上要么没有实现（`window_manager` 只有桌面端平台），要么调用会
/// 走原生通道失败。判断集中在这里，免得散落的 `Platform.isWindows` 又漏一处。
bool get isDesktopPlatform =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// 手机端：没有窗口，导航靠系统返回键 + 底部导航。
bool get isMobilePlatform => Platform.isAndroid || Platform.isIOS;

/// 手机布局的判定阈值（按**短边**判，横屏也算窄屏）。
///
/// 为什么按短边：手机横过来宽 900+ dp，用宽度判会突然套上桌面三栏；而平板的
/// 短边（768dp 起）本来就放得下三栏。600 是常见平板/手机分界线。
const double kCompactShortestSide = 600;

/// 当前窗口是否该用手机布局（单栏 + 底部导航）。
bool useCompactLayout(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return size.shortestSide < kCompactShortestSide;
}
