import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/core/app_theme.dart';
import 'package:omioclink_client/data/theme_store.dart';
import 'package:omioclink_client/features/theme_pane.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('主题页：六套主题都列出来，点一张就换', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(1100, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final store = ThemeStore(directoryBase: 'no-wallpaper-here');
    await store.load();

    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeStore>.value(
        value: store,
        child: MaterialApp(
          theme: AppTheme.data(store.palette),
          home: const Scaffold(body: ThemePane()),
        ),
      ),
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
}
