import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/core/app_locales.dart';
import 'package:omioclink_client/core/app_theme.dart';
import 'package:omioclink_client/data/locale_store.dart';
import 'package:omioclink_client/data/theme_store.dart';
import 'package:omioclink_client/features/theme_pane.dart';
import 'package:omioclink_client/l10n/generated/app_l10n.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主题页现在要两样东西：主题（配色 + 壁纸）和语言。
Widget _pane({
  required ThemeStore theme,
  required LocaleStore locale,
  Locale? selectedLocale,
}) => MultiProvider(
  providers: [
    ChangeNotifierProvider<ThemeStore>.value(value: theme),
    ChangeNotifierProvider<LocaleStore>.value(value: locale),
  ],
  child: MaterialApp(
    // 挂上真实的本地化：中文那份要用来断言原文，英文那份用来验证真的换了语言
    locale: selectedLocale,
    supportedLocales: AppLocales.supported,
    localizationsDelegates: AppL10n.localizationsDelegates,
    theme: AppTheme.data(theme.palette),
    home: const Scaffold(body: ThemePane()),
  ),
);

void main() {
  testWidgets('主题页：六套主题都列出来，点一张就换', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(1100, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final store = ThemeStore(directoryBase: 'no-wallpaper-here');
    await store.load();
    final locale = LocaleStore();
    await locale.load();

    await tester.pumpWidget(
      _pane(theme: store, locale: locale, selectedLocale: const Locale('zh')),
    );
    await tester.pumpAndSettle();

    for (final pack in AppThemePacks.all) {
      expect(find.text(pack.name), findsOneWidget, reason: '缺了「${pack.name}」');
    }
    expect(find.text('还没有壁纸'), findsOneWidget);
    expect(find.text('当前 · 薄荷汽水'), findsOneWidget);

    await tester.tap(find.text('朱砂'));
    await tester.pumpAndSettle();

    expect(store.pack.id, AppThemePacks.cinnabar.id, reason: '点卡片要真的切过去');
    expect(find.text('当前 · 朱砂'), findsOneWidget);
  });

  testWidgets('页头下拉：四门语言 + 跟随系统，选中就换语言', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(1100, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final theme = ThemeStore(directoryBase: 'no-wallpaper-here');
    await theme.load();
    final locale = LocaleStore();
    await locale.load();

    await tester.pumpWidget(
      _pane(theme: theme, locale: locale, selectedLocale: const Locale('zh')),
    );
    await tester.pumpAndSettle();

    // 下拉框在页头：按钮上就是当前选择，展开后才列出四种语言
    expect(find.text('跟随系统'), findsOneWidget);
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    expect(find.text('English'), findsOneWidget);
    expect(find.text('日本語'), findsOneWidget);
    expect(find.text('한국어'), findsOneWidget);

    await tester.tap(find.text('English').last);
    await tester.pumpAndSettle();

    expect(locale.selection, 'en', reason: '选了 English 要记到 LocaleStore');
    await tester.pumpWidget(
      _pane(theme: theme, locale: locale, selectedLocale: const Locale('en')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Theme'), findsOneWidget);
    // 下拉按钮上显示的是当前选择，所以这时候是 English 而不是 Follow system
    expect(find.text('English'), findsOneWidget);
    expect(find.text('Mint Soda'), findsOneWidget);
  });

  testWidgets('页头下拉：选「跟随系统」清掉选择', (tester) async {
    SharedPreferences.setMockInitialValues({'omioclink.locale': 'ja'});
    await tester.binding.setSurfaceSize(const Size(1100, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final theme = ThemeStore(directoryBase: 'no-wallpaper-here');
    await theme.load();
    final locale = LocaleStore();
    await locale.load();
    expect(locale.selection, 'ja');

    await tester.pumpWidget(
      _pane(theme: theme, locale: locale, selectedLocale: const Locale('ja')),
    );
    await tester.pumpAndSettle();

    // 页头下拉：展开后选「跟随系统」
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('システムに従う').last);
    await tester.pumpAndSettle();

    expect(locale.selection, AppLocales.system);
    expect(locale.locale, isNull);
  });
}
