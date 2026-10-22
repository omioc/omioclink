import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/core/app_theme.dart';
import 'package:omioclink_client/features/dialogs.dart';
import 'package:omioclink_client/musicfree/plugin_models.dart';

/// 订阅清单里的插件选择框。
///
/// 这里只测「弹框本身」的交互：预设勾选、全选/全不选、确认与取消的返回值。
/// 「按选择只装这几个」在 `musicfree_plugins_test.dart` 里用真实 HTTP 流程验证。
List<MusicFreeSubscriptionEntry> makeEntries(int count) {
  return <MusicFreeSubscriptionEntry>[
    for (var index = 1; index <= count; index += 1)
      MusicFreeSubscriptionEntry(
        url: 'https://p.example.com/p$index.js',
        name: '插件$index',
        version: '1.0.$index',
      ),
  ];
}

/// 把弹框挂到一个带按钮的页面上，返回「读取弹框返回值」的闭包。
Future<Future<Set<String>?> Function()> openPicker(
  WidgetTester tester, {
  required List<MusicFreeSubscriptionEntry> entries,
  required Set<String> preselected,
}) async {
  Set<String>? picked;
  var closed = false;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                picked = await showPluginPickerDialog(
                  context,
                  entries: entries,
                  preselected: preselected,
                );
                closed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  return () async {
    expect(closed, isTrue, reason: '弹框还没关');
    return picked;
  };
}

Future<void> useLargeSurface(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1200, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

void main() {
  testWidgets('默认勾选传入的预设值，确认后返回勾选的那些', (tester) async {
    await useLargeSurface(tester);
    final entries = makeEntries(8);
    final read = await openPicker(
      tester,
      entries: entries,
      preselected: <String>{entries[0].url, entries[1].url},
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('选择要安装的插件'), findsOneWidget);
    expect(find.textContaining('共 8 个插件'), findsOneWidget);
    // ListView.builder 只建可见项，所以这里只断言「列表铺出来了」，
    // 条目数量看上面那行文案（共 8 个插件）。
    expect(find.byType(CheckboxListTile), findsWidgets);
    expect(find.text('已选 2 / 8'), findsOneWidget);

    // 再勾一个
    await tester.tap(find.text('插件3'));
    await tester.pumpAndSettle();
    expect(find.text('已选 3 / 8'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '安装 3 个'));
    await tester.pumpAndSettle();

    expect(
      await read(),
      <String>{entries[0].url, entries[1].url, entries[2].url},
    );
  });

  testWidgets('取消返回 null（调用方据此一个插件都不动）', (tester) async {
    await useLargeSurface(tester);
    final entries = makeEntries(3);
    final read = await openPicker(
      tester,
      entries: entries,
      preselected: <String>{entries[0].url},
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(await read(), isNull);
  });

  testWidgets('全选 / 全不选：一个都没选时不能确认', (tester) async {
    await useLargeSurface(tester);
    final entries = makeEntries(5);
    final read = await openPicker(
      tester,
      entries: entries,
      preselected: <String>{entries[0].url},
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 5 / 5'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '安装 5 个'), findsOneWidget);

    await tester.tap(find.text('全不选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 0 / 5'), findsOneWidget);
    // 「安装 0 个」按钮禁用：一个都没选等于把这条订阅的插件全删了，太容易误触
    final confirm = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '安装 0 个'),
    );
    expect(confirm.onPressed, isNull);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await read(), isNull);
  });
}
