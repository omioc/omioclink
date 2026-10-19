import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/core/app_theme.dart';
import 'package:omioclink_client/features/home_shell.dart';
import 'package:omioclink_client/music/music_free_library.dart';
import 'package:omioclink_client/musicfree/musicfree_host.dart';
import 'package:omioclink_client/musicfree/musicfree_plugins.dart';
import 'package:omioclink_client/musicfree/musicfree_service.dart';
import 'package:omioclink_client/musicfree/plugin_models.dart';
import 'package:omioclink_client/musicfree/plugin_paths.dart';
import 'package:shared_preferences/shared_preferences.dart';

MusicFreePlugin _plugin({
  required String hash,
  required String platform,
  String author = '作者',
  String version = '0.1.0',
  String? srcUrl,
  List<String> methods = const <String>[
    'search',
    'getMediaSource',
    'getTopListDetail',
  ],
  List<PluginUserVariable> variables = const <PluginUserVariable>[],
  bool enabled = true,
}) {
  return MusicFreePlugin(
    hash: hash,
    platform: platform,
    path: 'musicfree-plugins/$hash.js',
    version: version,
    author: author,
    srcUrl: srcUrl ?? 'https://plugins.example.com/$hash.js',
    supportedMethods: methods,
    userVariables: variables,
    enabled: enabled,
  );
}

/// 假的插件管理器：只记账，不真的读写文件 / 起 JS 运行时。
class _FakePlugins extends MusicFreePlugins {
  _FakePlugins({required super.host, super.paths, required this.items});

  final List<MusicFreePlugin> items;
  final List<String> calls = <String>[];

  @override
  List<MusicFreePlugin> get plugins => List<MusicFreePlugin>.unmodifiable(items);

  @override
  Future<void> setEnabled(String hash, bool enabled) async {
    calls.add('setEnabled:$hash:$enabled');
    final index = items.indexWhere((plugin) => plugin.hash == hash);
    if (index >= 0) {
      items[index] = items[index].copyWith(enabled: enabled);
    }
  }

  @override
  Future<void> move(String hash, int delta) async {
    calls.add('move:$hash:$delta');
  }

  @override
  Future<void> uninstall(String hash) async {
    calls.add('uninstall:$hash');
    items.removeWhere((plugin) => plugin.hash == hash);
  }

  @override
  Future<List<String>> updateAll() async {
    calls.add('updateAll');
    return const <String>[];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _FakePlugins plugins;
  late MusicFreeLibrary library;
  int refreshed = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    refreshed = 0;
    tempDir = Directory.systemTemp.createTempSync('mf-settings-test');
    final paths = PluginPaths(root: tempDir.path);
    plugins = _FakePlugins(
      host: MusicFreeHost(bundleSource: '', paths: paths),
      paths: paths,
      items: <MusicFreePlugin>[
        _plugin(
          hash: 'h1',
          platform: '网易云',
          variables: const <PluginUserVariable>[
            PluginUserVariable(key: 'cookie', name: 'Cookie', hint: '登录后才有的'),
          ],
        ),
        _plugin(hash: 'h2', platform: 'B站', version: '1.2'),
      ],
    );
    library = MusicFreeLibrary(plugins: plugins);
  });

  tearDown(() {
    library.dispose();
    try {
      tempDir.deleteSync(recursive: true);
    } on Object {
      // 清理失败不影响断言
    }
  });

  Future<void> pumpCard(
    WidgetTester tester, {
    List<String> subscriptionUrls = const <String>[
      'https://example.com/subscription.json',
    ],
    bool withRefresh = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          backgroundColor: AppThemePacks.night.palette.stage,
          body: SingleChildScrollView(
            child: MusicPluginSettingsCard(
              library: library,
              subscriptionUrls: subscriptionUrls,
              onRefreshSubscription: withRefresh
                  ? () async {
                      refreshed += 1;
                    }
                  : null,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('列出插件、数量与来源，开关触发 setEnabled', (tester) async {
    await pumpCard(tester);

    expect(find.text('音乐插件'), findsOneWidget);
    expect(find.text('共 2 个（启用 2 个）'), findsOneWidget);
    expect(find.text('网易云'), findsOneWidget);
    expect(find.text('B站'), findsOneWidget);
    // 来源只显示域名
    expect(find.textContaining('plugins.example.com'), findsWidgets);

    // 第一个插件的开关
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(plugins.calls, contains('setEnabled:h1:false'));
    // 停用后卡片上标出「已停用」
    expect(find.text('已停用'), findsOneWidget);
  });

  testWidgets('上移 / 下移按插件顺序移动', (tester) async {
    await pumpCard(tester);

    // 第一个插件的「上移」在第一行是禁用的，第二个插件的可以点
    await tester.tap(find.byIcon(Icons.arrow_upward).at(1));
    await tester.pumpAndSettle();
    expect(plugins.calls, contains('move:h2:-1'));

    await tester.tap(find.byIcon(Icons.arrow_downward).first);
    await tester.pumpAndSettle();
    expect(plugins.calls, contains('move:h1:1'));
  });

  testWidgets('卸载需要二次确认，确认后调用 uninstall', (tester) async {
    await pumpCard(tester);

    await tester.tap(find.text('卸载').first);
    await tester.pumpAndSettle();
    expect(find.text('卸载插件'), findsOneWidget);
    // 先取消：不该卸载
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(plugins.calls.where((call) => call.startsWith('uninstall')), isEmpty);

    await tester.tap(find.text('卸载').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '卸载'));
    await tester.pumpAndSettle();

    expect(plugins.calls, contains('uninstall:h1'));
    expect(find.text('网易云'), findsNothing);
  });

  testWidgets('刷新订阅与更新全部分别触发回调 / updateAll', (tester) async {
    await pumpCard(tester);

    await tester.tap(find.text('刷新订阅'));
    await tester.pumpAndSettle();
    expect(refreshed, 1);

    await tester.tap(find.text('更新全部'));
    await tester.pumpAndSettle();
    expect(plugins.calls, contains('updateAll'));
  });

  testWidgets('音质下拉四档，选中后写回 library', (tester) async {
    await pumpCard(tester);

    expect(find.text('标准'), findsOneWidget);
    await tester.tap(find.byType(DropdownButton<MusicFreeQuality>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('无损').last);
    await tester.pumpAndSettle();

    expect(library.quality, MusicFreeQuality.super_);
    expect(find.text('无损'), findsOneWidget);
  });

  testWidgets('插件有自定义变量时给出「配置」入口', (tester) async {
    await pumpCard(tester);

    // 只有第一个插件声明了 userVariables
    expect(find.text('配置'), findsOneWidget);
    await tester.tap(find.text('配置'));
    await tester.pumpAndSettle();
    expect(find.text('配置 网易云'), findsOneWidget);
    expect(find.text('Cookie'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets('空态：服务器没配订阅地址时给出对应文案', (tester) async {
    await library.uninstallPlugin('h1');
    await library.uninstallPlugin('h2');
    await pumpCard(tester, subscriptionUrls: const <String>[], withRefresh: false);

    expect(find.text('服务器还没有配置插件订阅地址'), findsOneWidget);
  });

  testWidgets('空态：有订阅地址但没装插件时提示刷新订阅', (tester) async {
    await library.uninstallPlugin('h1');
    await library.uninstallPlugin('h2');
    await pumpCard(tester);

    expect(find.text('还没有安装插件，点「刷新订阅」重新拉取'), findsOneWidget);
  });
}
