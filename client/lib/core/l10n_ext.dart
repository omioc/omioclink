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
