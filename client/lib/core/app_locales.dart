import 'package:flutter/widgets.dart';

/// 界面语言的取值与解析。
///
/// 中文既是模板语言也是缺省语言：系统语言不在支持列表里（法语、俄语……）时界面用中文，
/// 而不是「碰巧排在列表第一个」的那门语言 —— 具体顺序见 [resolve]。
class AppLocales {
  const AppLocales._();

  /// 「跟随系统」的取值。
  ///
  /// 它不是合法语言码，所以不会和真正的 [Locale] 撞车；之所以不用 `null`
  /// 当取值，是因为下拉框需要一个可以比较的字符串。
  static const String system = 'system';

  /// 支持的语言，顺序即下拉框里的顺序（中文在最前，与文档一致）。
  static const List<Locale> supported = <Locale>[
    Locale('zh'),
    Locale('en'),
    Locale('ja'),
    Locale('ko'),
  ];

  /// 匹配不上系统语言时的回落。
  static const Locale fallback = Locale('zh');

  /// 每种语言用**它自己**的写法命名：语言选项那几行永远看得懂。
  static String nativeName(String code) => switch (code) {
    'zh' => '中文',
    'en' => 'English',
    'ja' => '日本語',
    'ko' => '한국어',
    _ => code,
  };

  /// 把系统语言列表解析成界面语言。
  ///
  /// 为什么不用 `MaterialApp` 的默认回落：它挑的是 `supportedLocales` 的第一个，
  /// 而生成出来的顺序是按语言码排的（en / ja / ko / zh）—— 法语、德语用户会看到
  /// 英文界面。这里显式规定「匹配不上就用中文」，与「中文是母语」的产品定位一致。
  static Locale resolve(List<Locale>? systemLocales) {
    for (final locale in systemLocales ?? const <Locale>[]) {
      for (final candidate in supported) {
        if (candidate.languageCode == locale.languageCode) {
          return candidate;
        }
      }
    }
    return fallback;
  }
  /// 当前界面语言（接口层发请求时据此带 `Accept-Language`）。
  ///
  /// 为什么用可写静态量而不是让 ApiClient 读 LocaleStore：ApiClient 不依赖
  /// Flutter/provider，构造点又在 AppState 里，透传一层只会把「语言」变成
  /// 到处都要传的参数。由 LocaleStore 在语言确定后写一次即可。
  static String _active = 'zh';

  static String get activeLanguageCode => _active;

  /// 由 LocaleStore 在「加载完偏好 / 用户切换语言」时调用。
  static void setActive(String languageCode) {
    for (final locale in supported) {
      if (locale.languageCode == languageCode) {
        _active = languageCode;
        return;
      }
    }
    // 传进来个不支持的语言码：保持原样，别把请求头写成服务端不认识的
    _active = fallback.languageCode;
  }
}
