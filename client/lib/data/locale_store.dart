import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_locales.dart';

/// 界面语言的本机设置（只影响这台设备，服务器不知道）。
///
/// 和主题一样只记一个语言码，真正的 [Locale] 由 [AppLocales] 解析。
/// 「跟随系统」用**空记录**（[locale] 为 null）表示：这样系统语言变了界面就自动
/// 跟上，而手动选过的语言不会被系统语言覆盖。
class LocaleStore extends ChangeNotifier {
  static const _key = 'omioclink.locale';

  Locale? _locale;

  /// 当前选中的语言；null 表示跟随系统。
  Locale? get locale => _locale;

  bool get followsSystem => _locale == null;

  /// 下拉框当前值：`system` 或语言码（见 [AppLocales.system]）。
  String get selection => _locale?.languageCode ?? AppLocales.system;

  /// 读回上次的选择。坏数据一律当「跟随系统」，绝不抛给界面。
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    String? code;
    try {
      code = prefs.getString(_key);
    } on Object {
      // 存成了别的类型（手改 / 旧版本残留）：当没选过
      code = null;
    }
    _locale = _fromCode(code);
    _publishActive();
    notifyListeners();
  }

  /// 切换语言；[code] 传 [AppLocales.system] 表示跟随系统。
  ///
  /// 同一个语言不重复通知：否则点下拉里已经选中的那项也会整棵树重刷一遍。
  Future<void> select(String code) async {
    final next = _fromCode(code);
    if (next?.languageCode == _locale?.languageCode) {
      return;
    }
    _locale = next;
    _publishActive();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (next == null) {
      await prefs.remove(_key);
    } else {
      await prefs.setString(_key, next.languageCode);
    }
  }

  Locale? _fromCode(String? code) {
    if (code == null || code.isEmpty || code == AppLocales.system) {
      return null;
    }
    for (final locale in AppLocales.supported) {
      if (locale.languageCode == code) {
        return locale;
      }
    }
    // 存了个不支持的语言码：当没选过，免得界面停在半截
    return null;
  }

  /// 把「当前界面语言」同步给接口层：请求要带 Accept-Language，服务端才知道
  /// 用哪种语言回错误文案。跟随系统时按系统语言解析。
  void _publishActive() {
    final locale =
        _locale ?? AppLocales.resolve(PlatformDispatcher.instance.locales);
    AppLocales.setActive(locale.languageCode);
  }
}
