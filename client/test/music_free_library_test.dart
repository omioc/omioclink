import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/data/music_models.dart';
import 'package:omioclink_client/music/music_free_library.dart';
import 'package:omioclink_client/musicfree/musicfree_host.dart';
import 'package:omioclink_client/musicfree/musicfree_plugins.dart';
import 'package:omioclink_client/musicfree/musicfree_service.dart';
import 'package:omioclink_client/musicfree/plugin_paths.dart';
import 'package:omioclink_client/musicfree/plugin_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 只提供排行榜的假服务层：不碰 JS 运行时，用来数「重拉了几次」。
class _FakeService extends MusicFreeService {
  _FakeService(super.plugins);

  int chartCalls = 0;
  int tagCalls = 0;

  @override
  Future<List<MusicFreeTopListGroup>> topLists({bool refresh = false}) async {
    chartCalls++;
    return <MusicFreeTopListGroup>[
      MusicFreeTopListGroup(
        platform: 'kg',
        title: '热门榜单',
        items: <MusicFreeSheet>[
          MusicFreeSheet(
            platform: 'kg',
            id: 'k1',
            title: '酷狗TOP500',
            raw: <String, dynamic>{'id': 'k1'},
          ),
        ],
      ),
    ];
  }

  @override
  Future<MusicFreeTags> recommendTags({bool refresh = false}) async {
    tagCalls++;
    return const MusicFreeTags();
  }

  @override
  Future<List<MusicFreeSheet>> sheetsByTag(MusicFreeTag tag, {int page = 1}) async =>
      const <MusicFreeSheet>[];
}

/// 可控「两轮搜索谁先回来」的假服务：验证并发两轮里旧结果不会覆盖新结果。
class _RacingService extends MusicFreeService {
  _RacingService(super.plugins);

  final List<Completer<MusicFreeSearchResult>> pending =
      <Completer<MusicFreeSearchResult>>[];

  @override
  Future<MusicFreeSearchResult> search(
    String keyword, {
    int page = 1,
    String type = 'music',
    String? platform,
    bool refresh = false,
    void Function(MusicFreeSearchResult partial)? onUpdate,
  }) {
    final completer = Completer<MusicFreeSearchResult>();
    pending.add(completer);
    return completer.future;
  }
}

/// 进房预热用的假服务：榜单 / 标签 / 标签下的歌单，各记一次调用。
class _WarmUpService extends MusicFreeService {
  _WarmUpService(super.plugins);

  int chartCalls = 0;
  int tagCalls = 0;
  int sheetCalls = 0;

  @override
  Future<List<MusicFreeTopListGroup>> topLists({bool refresh = false}) async {
    chartCalls++;
    return <MusicFreeTopListGroup>[
      MusicFreeTopListGroup(
        platform: 'kg',
        title: '热门榜单',
        items: <MusicFreeSheet>[
          MusicFreeSheet(
            platform: 'kg',
            id: 'k1',
            title: '酷狗TOP500',
            raw: <String, dynamic>{'id': 'k1'},
          ),
        ],
      ),
    ];
  }

  @override
  Future<MusicFreeTags> recommendTags({bool refresh = false}) async {
    tagCalls++;
    return MusicFreeTags(
      pinned: <MusicFreeTag>[
        MusicFreeTag(
          platform: 'kg',
          id: 'g1',
          title: '流行',
          raw: <String, dynamic>{'id': 'g1'},
        ),
      ],
    );
  }

  @override
  Future<List<MusicFreeSheet>> sheetsByTag(MusicFreeTag tag, {int page = 1}) async {
    sheetCalls++;
    return <MusicFreeSheet>[
      MusicFreeSheet(
        platform: 'kg',
        id: 'p1',
        title: '纯音乐歌单',
        raw: <String, dynamic>{'id': 'p1'},
      ),
    ];
  }
}

/// 假的插件管理器：只报「装着一条插件」。
///
/// 榜单 / 歌单在没有插件时**不会**再去拉（详见 `loadCharts` 的说明），所以这些
/// 用例必须处在「插件已装好」这个真实常态下，才能走到服务层。
class _FakePlugins extends MusicFreePlugins {
  _FakePlugins({required super.host, super.paths, required this.items});

  final List<MusicFreePlugin> items;

  @override
  List<MusicFreePlugin> get plugins => List<MusicFreePlugin>.unmodifiable(items);
}

MusicFreePlugin _installedPlugin() => MusicFreePlugin(
  hash: 'h1',
  platform: 'kg',
  path: 'musicfree-plugins/h1.js',
  version: '0.1.0',
  author: '作者',
  srcUrl: 'https://plugins.example.com/h1.js',
  supportedMethods: const <String>['getTopList', 'getTopLists', 'getRecommendSheets'],
  userVariables: const <PluginUserVariable>[],
  enabled: true,
);

MusicTrack _track(String name) => MusicTrack(
  platform: 'kg',
  id: name,
  name: name,
  artists: const <MusicArtist>[],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late MusicFreeLibrary library;
  late _FakeService service;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tempDir = Directory.systemTemp.createTempSync('mf-library-test');
    final paths = PluginPaths(root: tempDir.path);
    final plugins = _FakePlugins(
      host: MusicFreeHost(bundleSource: '', paths: paths),
      paths: paths,
      items: <MusicFreePlugin>[_installedPlugin()],
    );
    service = _FakeService(plugins);
    library = MusicFreeLibrary(plugins: plugins, service: service);
  });

  tearDown(() {
    library.dispose();
    try {
      tempDir.deleteSync(recursive: true);
    } on Object {
      // 临时目录清不掉不影响断言
    }
  });

  test('排行榜已加载时，订阅同步（插件集合没变）不清空内容', () async {
    await library.loadCharts();
    expect(library.chartGroups, isNotEmpty);
    expect(service.chartCalls, 1);

    // 「点第一首歌」→ 播放前 ensureReady → AppState 拉订阅 → 这里再同步一次
    await library.syncSubscription(urls: const <String>[], hash: null);

    expect(
      library.chartGroups,
      isNotEmpty,
      reason: '插件没变就清空，界面会突然变成「插件没有提供排行榜」',
    );
    expect(library.chartsError, isNull);
    expect(service.chartCalls, 1, reason: '内容还在，不需要白拉一次');
  });

  test('退出登录 reset()：清空内容且不会在后台偷偷重拉', () async {
    await library.loadCharts();
    final calls = service.chartCalls;
    expect(calls, 1);

    library.reset();
    expect(library.chartGroups, isEmpty);
    await Future<void>.delayed(Duration.zero);

    expect(
      service.chartCalls,
      calls,
      reason: 'reset 之后不该自动重拉（否则退出登录还在后台跑）',
    );
  });

  test('同一个关键词并发两轮：只认最新那轮的结果（旧轮迟到也不覆盖）', () async {
    final paths = PluginPaths(root: tempDir.path);
    // 搜索也要求「装着插件」才发请求（没插件时直接清空，不打扰用户）
    final plugins = _FakePlugins(
      host: MusicFreeHost(bundleSource: '', paths: paths),
      paths: paths,
      items: <MusicFreePlugin>[_installedPlugin()],
    );
    final racing = _RacingService(plugins);
    final racingLibrary = MusicFreeLibrary(plugins: plugins, service: racing);
    addTearDown(racingLibrary.dispose);

    // 用户快速切了一次音源 tab：同一关键词并发两轮
    final firstRound = racingLibrary.search('周杰伦');
    final secondRound = racingLibrary.search('周杰伦');
    expect(racing.pending, hasLength(2));

    // 新那轮先回来
    racing.pending[1].complete(
      MusicFreeSearchResult(tracks: <MusicTrack>[_track('新的')], done: 1, total: 1),
    );
    await secondRound;
    expect(racingLibrary.tracks.single.name, '新的');
    expect(racingLibrary.searching, isFalse);

    // 旧那轮迟到：不许覆盖，也不许把「搜索中」重新点亮
    racing.pending[0].complete(
      MusicFreeSearchResult(tracks: <MusicTrack>[_track('旧的')], done: 1, total: 1),
    );
    await firstRound;
    expect(racingLibrary.tracks.single.name, '新的');
    expect(racingLibrary.searching, isFalse);
  });

  test('没有插件时不去拉榜单/歌单，也不自动装插件', () async {
    library.dispose();
    final paths = PluginPaths(root: tempDir.path);
    final plugins = MusicFreePlugins(
      host: MusicFreeHost(bundleSource: '', paths: paths),
      paths: paths,
    );
    final counter = _WarmUpService(plugins);
    library = MusicFreeLibrary(plugins: plugins, service: counter);

    // 显式调用（界面上的「加载…」按钮 / 搜索）在没有插件时也不该发出任何请求：
    // 自动装插件的那条路已经从库里删掉了（见 `requestSync` 被移除的注释）。
    await library.loadCharts();
    await library.loadTagSections();
    await library.search('七里香');

    expect(counter.chartCalls, 0, reason: '没装音源就不该去拉榜单');
    expect(counter.tagCalls, 0, reason: '没装音源也不该去拉歌单标签');
    expect(library.chartGroups, isEmpty);
    expect(
      library.chartsError,
      isNull,
      reason: '这是「还没装音源」，不是加载失败，界面不该挂一个重试按钮',
    );
    expect(library.query, isEmpty, reason: '没插件时搜索直接清空，不发请求也不留半截状态');
  });

  test('warmUp 不碰插件：进房只读音质偏好，排行榜要等点开点歌台', () async {
    final paths = PluginPaths(root: tempDir.path);
    // 榜单/歌单在没有插件时不会去拉，所以这里要「装着一条插件」（真实常态）
    final plugins = _FakePlugins(
      host: MusicFreeHost(bundleSource: '', paths: paths),
      paths: paths,
      items: <MusicFreePlugin>[_installedPlugin()],
    );
    final warm = _WarmUpService(plugins);
    final warmLibrary = MusicFreeLibrary(plugins: plugins, service: warm);
    addTearDown(warmLibrary.dispose);

    // 进房那一刻（AppState.joinRoom）：只读本地偏好，绝不触发插件装载/榜单
    // （插件装载 = QuickJS 同步编译整个运行时 bundle，会把窗口冻住几秒）
    warmLibrary.warmUp();
    await pumpEventQueue();

    expect(warm.chartCalls, 0, reason: '进房不该拉榜单');
    expect(warm.tagCalls, 0);
    expect(warm.sheetCalls, 0);
    expect(warmLibrary.chartGroups, isEmpty);

    // 用户点开点歌台：这时才拉排行榜
    await warmLibrary.loadCharts();
    expect(warm.chartCalls, 1);
    expect(warmLibrary.chartGroups, isNotEmpty);

    // 切到「热门歌单」：标签 + 第一个标签下的歌单
    await warmLibrary.loadTagSections();
    expect(warm.tagCalls, 1);
    expect(warm.sheetCalls, 1, reason: '热门歌单要把第一个标签下的歌单一并备好');
    expect(warmLibrary.selectedTag, isNotNull);

    // 再来一轮：都已备好，不该再发请求
    await warmLibrary.loadCharts();
    await warmLibrary.loadTagSections();
    expect(warm.chartCalls, 1);
    expect(warm.tagCalls, 1);
    expect(warm.sheetCalls, 1);
  });
}
