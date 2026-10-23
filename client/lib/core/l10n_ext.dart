import 'package:flutter/widgets.dart';

import '../l10n/generated/app_l10n.dart';
// 中文那份单独 import：生成器不把 AppL10nZh 从 app_l10n.dart 里 re-export，
// 而「拿不到本地化时回落中文」正好要用它
import '../l10n/generated/app_l10n_zh.dart';

/// 取当前语言的文案：`context.l10n.themePaneTitle`。
///
/// 为什么不直接 `AppL10n.of(context)`：仓库里大量老用例只 pump 了一个局部控件
/// （`MaterialApp(home: …)` 没挂 delegate），`of()` 在那种环境里会直接断言。
/// 这里拿不到本地化时回落到中文 —— 真实应用里 delegate 一定在，走的仍是当前语言。
extension AppL10nX on BuildContext {
  AppL10n get l10n => Localizations.of<AppL10n>(this, AppL10n) ?? AppL10nZh();
}

/// 非控件层（播放器 / 插件门面这些拿不到 `BuildContext` 的地方）取文案用。
///
/// 它们产出的字符串（播放失败原因、插件错误、订阅进度）最终都直接显示在界面上，
/// 但那一层没有 context。`_App` 每次重建都会把当前语言的实例登记进来，
/// 换语言时界面重画，这里跟着换；没有界面时（单测）就是中文。
AppL10n _current = AppL10nZh();

AppL10n get appL10n => _current;

/// 由 `MaterialApp.builder` 调用：登记当前语言的实例。
void syncAppL10n(AppL10n l10n) => _current = l10n;
