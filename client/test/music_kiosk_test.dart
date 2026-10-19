import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/core/app_theme.dart';
import 'package:omioclink_client/data/models.dart';
import 'package:omioclink_client/data/music_models.dart';
import 'package:omioclink_client/data/server_endpoint.dart';
import 'package:omioclink_client/features/music/music_kiosk.dart';
import 'package:omioclink_client/features/music/music_widgets.dart';
import 'package:omioclink_client/features/music/playback_mode.dart';
import 'package:omioclink_client/music/music_favorites.dart';
import 'package:omioclink_client/music/music_free_library.dart';
import 'package:omioclink_client/music/music_player.dart';
import 'package:omioclink_client/musicfree/musicfree_host.dart';
import 'package:omioclink_client/musicfree/musicfree_plugins.dart';
import 'package:omioclink_client/musicfree/musicfree_service.dart';
import 'package:omioclink_client/musicfree/plugin_paths.dart';
import 'package:omioclink_client/room/room_session.dart';
import 'package:omioclink_client/signaling/protocol.dart';
import 'package:omioclink_client/signaling/signaling_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'room_session_test.dart' show FakeMediaPort;

const _endpoint = ServerEndpoint(host: '127.0.0.1', port: 21077);
const _me = User(id: 7, username: 'alice', displayName: '小明');

MusicTrack _track(String id, String name) => MusicTrack(
  platform: 'test',
  id: id,
  name: name,
  artists: <MusicArtist>[MusicArtist(name: '歌手$id')],
  durationMs: 210000,
  musicInfo: <String, dynamic>{'id': id},
);

/// 服务端快照里的一条待播点歌。
MusicEntry _entryOf(
  String entryId, {
  String songId = '1',
  String by = 'peer-a',
  String name = '小明',
}) => MusicEntry(
  entryId: entryId,
  source: 'test',
  songId: songId,
  musicInfo: <String, dynamic>{'id': songId},
  title: '歌$songId',
  artist: '歌手$songId',
  durationMs: 210000,
  requestedBy: MusicRequester(peerId: by, displayName: name),
);

/// 服务端快照里的当前曲。
MusicCurrent _currentEntry(
  String entryId, {
  String songId = '1',
  String by = 'peer-a',
  String name = '小明',
}) => MusicCurrent(
  entryId: entryId,
  source: 'test',
  songId: songId,
  musicInfo: <String, dynamic>{'id': songId},
  title: '在播的歌',
  artist: '歌手$songId',
  durationMs: 210000,
  requestedBy: MusicRequester(peerId: by, displayName: name),
);

MusicFreeSheet _sheet(String id, String title, {String? creator}) =>
    MusicFreeSheet(
      platform: 'test',
      id: id,
      title: title,
      creator: creator,
      raw: <String, dynamic>{'id': id, 'title': title},
    );

MusicFreeTag _tag(String id, String title) => MusicFreeTag(
  platform: 'test',
  id: id,
  title: title,
  raw: <String, dynamic>{'id': id, 'title': title},
);

/// 假的 MusicFree 服务层：只提供界面要断言的那几份数据，不碰 JS 运行时。
class _FakeService extends MusicFreeService {
  _FakeService(
    super.plugins, {
    this.empty = false,
    this.chartGroups,
    this.tags,
    this.sheets,
  });

  /// 榜单 / 标签 / 歌单全当空处理（模拟「一个插件都没装、什么都拿不到」的世界）。
  final bool empty;

  /// 自定义榜单（默认只给一份「测试音源」的榜单）。
  final List<MusicFreeTopListGroup>? chartGroups;

  /// 自定义歌单标签（默认只有一个「流行」）。
  final MusicFreeTags? tags;

  /// 自定义标签下的歌单（默认只有一张「纯音乐歌单」）。
  final List<MusicFreeSheet>? sheets;
  @override
  Future<MusicFreeSearchResult> search(
    String keyword, {
    int page = 1,
    String type = 'music',
    String? platform,
    bool refresh = false,
    void Function(MusicFreeSearchResult partial)? onUpdate,
  }) async {
    lastSearchType = type;
    lastSearchPlatform = platform;
    return MusicFreeSearchResult(
      tracks: <MusicTrack>[
        _track('s1', type == 'music' ? '搜到的歌' : '$type 结果'),
      ],
      errors: const <String>['歌词插件不可用'],
      skipped: const <String>['bad'],
      done: 2,
      total: 2,
    );
  }

  /// 最近一次搜索用的类型 / 音源（断言 tab 切换用）。
  String? lastSearchType;
  String? lastSearchPlatform;

  @override
  List<String> get searchTypes => const <String>['music', 'album'];

  @override
  List<String> platformsForType(String type) => const <String>['kg', 'tx'];

  @override
  Future<List<MusicFreeTopListGroup>> topLists({bool refresh = false}) async {
    if (empty) {
      return const <MusicFreeTopListGroup>[];
    }
    final custom = chartGroups;
    if (custom != null) {
      return custom;
    }
    return <MusicFreeTopListGroup>[
      MusicFreeTopListGroup(
        platform: 'test',
        title: '热门榜单',
        items: <MusicFreeSheet>[_sheet('t1', '热歌榜')],
      ),
    ];
  }

  @override
  Future<MusicFreeTrackPage> topListDetail(
    MusicFreeSheet sheet, {
    int page = 1,
  }) async {
    return MusicFreeTrackPage(tracks: <MusicTrack>[_track('d1', '榜单第一首')]);
  }

  @override
  Future<MusicFreeTags> recommendTags({bool refresh = false}) async {
    if (empty) {
      return const MusicFreeTags();
    }
    final custom = tags;
    if (custom != null) {
      return custom;
    }
    return MusicFreeTags(
      pinned: <MusicFreeTag>[_tag('g1', '流行')],
      groups: <MusicFreeTagGroup>[
        MusicFreeTagGroup(title: '风格', tags: <MusicFreeTag>[_tag('g2', '摇滚')]),
      ],
    );
  }

  @override
  Future<List<MusicFreeSheet>> sheetsByTag(MusicFreeTag tag, {int page = 1}) async {
    if (empty) {
      return const <MusicFreeSheet>[];
    }
    final custom = sheets;
    if (custom != null) {
      return custom;
    }
    return <MusicFreeSheet>[_sheet('p1', '纯音乐歌单', creator: '编辑推荐')];
  }

  @override
  Future<MusicFreeTrackPage> sheetInfo(MusicFreeSheet sheet, {int page = 1}) async {
    return MusicFreeTrackPage(tracks: <MusicTrack>[_track('p1t', '歌单第一首')]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late MusicFavorites favorites;
  late RoomSession session;
  late MusicFreeLibrary library;
  late _FakeService service;
  late MusicPlayer player;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tempDir = Directory.systemTemp.createTempSync('mf-kiosk-test');
    final paths = PluginPaths(root: tempDir.path);
    final plugins = MusicFreePlugins(
      host: MusicFreeHost(bundleSource: '', paths: paths),
      paths: paths,
    );
    service = _FakeService(plugins);
    library = MusicFreeLibrary(plugins: plugins, service: service);
    // 「我喜欢」是本机收藏：每个用例一份干净的，读写的是 mock 的 SharedPreferences
    favorites = MusicFavorites();
    session = RoomSession(
      signaling: SignalingClient(
        endpoint: _endpoint,
        accessToken: 'token',
        random: Random(3),
      ),
      media: FakeMediaPort(),
      currentUser: _me,
      statsInterval: const Duration(hours: 1),
    );
    // 界面只用到队列与播放状态；这里不会真的播音（媒体库首次播放才加载）
    player = MusicPlayer(
      queue: session.music,
      resolve: (track) async =>
          const MusicFreeMediaSource(url: 'https://example.com/a.mp3'),
    );
  });

  tearDown(() {
    library.dispose();
    favorites.dispose();
    session.dispose();
    player.dispose();
    try {
      tempDir.deleteSync(recursive: true);
    } on Object {
      // 临时目录清理失败不影响断言
    }
  });

  /// [withFavorites] 用来指定这一轮挂载用哪份本机收藏（默认就是 setUp 里那份）。
  Future<void> pumpKiosk(
    WidgetTester tester, {
    MusicFavorites? withFavorites,
  }) async {
    // 点歌台是三栏桌面布局：默认 800×600 会溢出
    await tester.binding.setSurfaceSize(const Size(1320, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          backgroundColor: AppThemePacks.night.palette.stage,
          body: MusicKiosk(
            library: library,
            session: session,
            player: player,
            favorites: withFavorites ?? favorites,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('左导航：排行榜 / 热门歌单，分割线下面才是「我喜欢」（搜索走上面的搜索框）', (
    tester,
  ) async {
    await pumpKiosk(tester);

    expect(find.text('排行榜'), findsOneWidget);
    expect(find.text('热门歌单'), findsOneWidget);
    // 「我喜欢」是本机收藏、不是插件给的：它和上面两个入口之间用一条分割线隔开
    expect(find.text('我喜欢'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('nav-divider')), findsOneWidget);
    // 搜索只剩顶部那一个按钮，不再是导航项
    expect(find.text('搜索'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '搜索'), findsOneWidget);
    // 默认落在排行榜（搜索不再占导航项，进来看的是内容而不是空搜索页）
    expect(find.text('热门榜单'), findsOneWidget);
    // 旧模式已经删掉
    expect(find.text('推荐'), findsNothing);
    expect(find.text('最近点过'), findsNothing);
  });

  testWidgets('搜索结果点心形收进「我喜欢」，从导航进去还能再点一遍', (tester) async {
    await pumpKiosk(tester);

    await tester.enterText(find.byType(TextField), '周杰伦');
    await tester.tap(find.widgetWithText(FilledButton, '搜索'));
    await tester.pumpAndSettle();

    // 心形排在「加入队列」左边：点它只是收藏，不动队列
    await tester.tap(find.byType(MusicFavoriteButton).first);
    await tester.pumpAndSettle();
    expect(favorites.length, 1);
    expect(favorites.tracks.single.name, '搜到的歌');
    expect(session.music.isEmpty, isTrue);

    await tester.tap(find.text('我喜欢'));
    await tester.pumpAndSettle();
    expect(find.text('我喜欢的音乐'), findsOneWidget);
    expect(find.text('1 首'), findsOneWidget);
    expect(find.textContaining('只保存在这台设备上'), findsOneWidget);
    expect(find.text('搜到的歌'), findsOneWidget);

    // 点整行＝再把这首点进房间队列（所谓「再次播放」就是这个动作）
    await tester.tap(find.byKey(const ValueKey<String>('favorite:test:s1')));
    await tester.pumpAndSettle();
    expect(session.music.length, 1);
    expect(session.music.queue.single.name, '搜到的歌');
  });

  testWidgets('「我喜欢」里再点心形就取消喜欢，空了回到空态', (tester) async {
    // 先读一次本机收藏，免得挂载时的兜底 load 盖掉下面预置的那首
    await favorites.load();
    favorites.add(_track('f1', '存下的歌'));
    await pumpKiosk(tester);

    await tester.tap(find.text('我喜欢'));
    await tester.pumpAndSettle();
    expect(find.text('存下的歌'), findsOneWidget);

    await tester.tap(find.byType(MusicFavoriteButton));
    await tester.pumpAndSettle();
    expect(favorites.isEmpty, isTrue);
    expect(find.text('还没有喜欢的歌'), findsOneWidget);
  });

  testWidgets('「我喜欢」读的是本机缓存：上次存的歌挂载后就在列表里', (tester) async {
    // 预置一份「上次退出时留在这台机器上」的收藏：它和服务器没有任何关系
    SharedPreferences.setMockInitialValues(<String, Object>{
      'omioclink.music.favorites': <String>[
        jsonEncode(_track('s1', '上次喜欢的歌').toJson()),
      ],
    });
    await pumpKiosk(tester);

    await tester.tap(find.text('我喜欢'));
    await tester.pumpAndSettle();

    expect(find.text('上次喜欢的歌'), findsOneWidget);
    expect(favorites.contains(_track('s1', '上次喜欢的歌')), isTrue);
  });

  testWidgets('没有插件时给出「还没有安装音乐插件」空态', (tester) async {
    // 这个用例要的是「一个插件都没装、什么都拿不到」的世界：
    // 换一个空数据的服务层，别让默认那一屏（排行榜）拿到假数据。
    library.dispose();
    final paths = PluginPaths(root: tempDir.path);
    final plugins = MusicFreePlugins(
      host: MusicFreeHost(bundleSource: '', paths: paths),
      paths: paths,
    );
    library = MusicFreeLibrary(
      plugins: plugins,
      service: _FakeService(plugins, empty: true),
    );
    await pumpKiosk(tester);

    expect(find.text('还没有安装音乐插件'), findsOneWidget);
    expect(find.text('队列还是空的'), findsOneWidget);
    expect(find.text('房间播放队列 (0)'), findsOneWidget);
  });
  testWidgets('搜索关键词后列表出现歌名，点歌进房间队列', (tester) async {
    await pumpKiosk(tester);

    await tester.enterText(find.byType(TextField), '周杰伦');
    await tester.tap(find.widgetWithText(FilledButton, '搜索'));
    await tester.pumpAndSettle();

    expect(find.text('「周杰伦」的搜索结果'), findsOneWidget);
    expect(find.text('搜到的歌'), findsOneWidget);
    // 音源报错不再铺在结果上面：搜索框右边只留一个小入口，点开才看原因
    expect(find.textContaining('歌词插件不可用'), findsNothing);
    expect(find.text('2 个音源异常'), findsOneWidget);
    await tester.tap(find.text('2 个音源异常'));
    await tester.pumpAndSettle();
    expect(find.text('部分音源没有返回结果'), findsOneWidget);
    expect(find.textContaining('歌词插件不可用'), findsOneWidget);
    expect(find.textContaining('已暂时跳过'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '知道了'));
    await tester.pumpAndSettle();
    expect(find.text('部分音源没有返回结果'), findsNothing);

    await tester.tap(find.byType(MusicAddButton).first);
    await tester.pumpAndSettle();

    expect(session.music.length, 1);
    expect(session.music.queue.single.name, '搜到的歌');
    expect(find.text('房间播放队列 (1)'), findsOneWidget);
  });

  testWidgets('服务端模式：队列行显示点歌人，非房主看不到「清空」', (tester) async {
    session.music.setViewer(peerId: 'peer-me');
    session.music.applySnapshot(
      MusicSnapshot(
        revision: 4,
        current: _currentEntry('e1', by: 'peer-b', name: '小红'),
        queue: <MusicEntry>[
          _entryOf('e2', songId: '2', by: 'peer-me', name: '小明'),
          _entryOf('e3', songId: '3', by: 'peer-b', name: '小红'),
        ],
      ),
    );
    await pumpKiosk(tester);

    // 队列里有当前曲：面板按「正在播放 + 等待中」展示
    expect(find.text('等待中 (2)'), findsOneWidget);
    expect(find.text('正在播放'), findsOneWidget);
    expect(find.textContaining('点歌人 小明（你）'), findsOneWidget);
    // 当前曲和待播里各有一首小红点的
    expect(find.textContaining('点歌人 小红'), findsNWidgets(2));
    // 普通成员：不能清空，也删不掉别人点的歌（只留 1 个移除按钮）
    expect(find.widgetWithText(TextButton, '清空'), findsNothing);
    expect(find.byTooltip('从队列移除'), findsOneWidget);
    expect(find.textContaining('清空队列需要房主'), findsOneWidget);
  });

  testWidgets('服务端模式：房主能切歌、清空，也能删别人的点歌', (tester) async {
    session.music.setViewer(peerId: 'peer-me', isOwner: true);
    session.music.applySnapshot(
      MusicSnapshot(
        revision: 4,
        current: _currentEntry('e1', by: 'peer-b', name: '小红'),
        queue: <MusicEntry>[_entryOf('e2', songId: '2', by: 'peer-b', name: '小红')],
      ),
    );
    await pumpKiosk(tester);

    expect(find.byTooltip('切歌（房主或点歌人）'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '清空'), findsOneWidget);
    expect(find.byTooltip('从队列移除'), findsOneWidget);
    expect(find.textContaining('你是房主'), findsOneWidget);
  });

  testWidgets('搜索只由顶部搜索框触发：清空后回到搜索前那一屏（热门歌单）', (tester) async {
    await pumpKiosk(tester);

    await tester.tap(find.text('热门歌单'));
    await tester.pumpAndSettle();
    expect(find.text('纯音乐歌单'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '周杰伦');
    await tester.tap(find.widgetWithText(FilledButton, '搜索'));
    await tester.pumpAndSettle();
    expect(find.text('「周杰伦」的搜索结果'), findsOneWidget);
    expect(find.text('纯音乐歌单'), findsNothing, reason: '搜索结果替换内容区');

    await tester.tap(find.widgetWithText(TextButton, '清空'));
    await tester.pumpAndSettle();
    expect(find.text('「周杰伦」的搜索结果'), findsNothing);
    expect(find.text('纯音乐歌单'), findsOneWidget, reason: '清空搜索回到搜索前的那一屏');
  });

  testWidgets('排行榜按插件分组展示，点进去看到详情歌曲', (tester) async {
    await pumpKiosk(tester);

    await tester.tap(find.text('排行榜'));
    await tester.pumpAndSettle();

    // 分组标题 + 榜单条目
    expect(find.text('热门榜单'), findsOneWidget);
    expect(find.text('热歌榜'), findsOneWidget);

    await tester.tap(find.text('热歌榜'));
    await tester.pumpAndSettle();

    expect(find.text('共 1 首'), findsOneWidget);
    expect(find.text('榜单第一首'), findsOneWidget);
    // 榜单详情带名次
    expect(find.text('1'), findsOneWidget);

    await tester.tap(find.text('全部加入队列'));
    await tester.pumpAndSettle();
    expect(session.music.length, 1);
  });

  testWidgets('排行榜按音源分顶部 tab：默认第一个音源，点 tab 切到该音源的榜单', (tester) async {
    // 两个音源各给一份榜单
    library.dispose();
    final paths = PluginPaths(root: tempDir.path);
    final plugins = MusicFreePlugins(
      host: MusicFreeHost(bundleSource: '', paths: paths),
      paths: paths,
    );
    library = MusicFreeLibrary(
      plugins: plugins,
      service: _FakeService(
        plugins,
        chartGroups: <MusicFreeTopListGroup>[
          MusicFreeTopListGroup(
            platform: 'kg',
            title: '热门榜单',
            items: <MusicFreeSheet>[_sheet('k1', '酷狗TOP500')],
          ),
          MusicFreeTopListGroup(
            platform: 'tx',
            title: '推荐榜',
            items: <MusicFreeSheet>[_sheet('t9', 'QQ热歌榜')],
          ),
        ],
      ),
    );
    await pumpKiosk(tester);

    // 顶部两个音源 tab，默认显示第一个音源的榜单
    expect(find.byKey(const ValueKey<String>('chart-tab:kg')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('chart-tab:tx')), findsOneWidget);
    expect(find.text('酷狗TOP500'), findsOneWidget);
    expect(find.text('QQ热歌榜'), findsNothing);

    // 切到第二个音源：只见它的榜单
    await tester.tap(find.byKey(const ValueKey<String>('chart-tab:tx')));
    await tester.pumpAndSettle();
    expect(find.text('QQ热歌榜'), findsOneWidget);
    expect(find.text('酷狗TOP500'), findsNothing);
    expect(find.text('推荐榜'), findsOneWidget);
  });

  testWidgets('榜单用卡片网格展示：同一行并排多张卡，换行后往下排', (tester) async {
    library.dispose();
    final paths = PluginPaths(root: tempDir.path);
    final plugins = MusicFreePlugins(
      host: MusicFreeHost(bundleSource: '', paths: paths),
      paths: paths,
    );
    library = MusicFreeLibrary(
      plugins: plugins,
      service: _FakeService(
        plugins,
        chartGroups: <MusicFreeTopListGroup>[
          MusicFreeTopListGroup(
            platform: 'kg',
            title: '热门榜单',
            items: <MusicFreeSheet>[
              _sheet('c1', '榜单甲'),
              _sheet('c2', '榜单乙'),
              _sheet('c3', '榜单丙'),
              _sheet('c4', '榜单丁'),
            ],
          ),
        ],
      ),
    );
    await pumpKiosk(tester);

    final first = tester.getRect(find.text('榜单甲'));
    final second = tester.getRect(find.text('榜单乙'));
    final third = tester.getRect(find.text('榜单丙'));
    expect(second.top, first.top, reason: '相邻卡片在同一行并排（卡片网格）');
    expect(second.left, greaterThan(first.left));
    expect(third.top, first.top, reason: '每行固定三张卡片');
    expect(third.left, greaterThan(second.left));

    // 换行后的卡片往下排
    final wrapped = tester.getRect(find.text('榜单丁'));
    expect(wrapped.top, greaterThan(first.top), reason: '第四张换到下一行');
  });

  testWidgets('排行榜音源 tab 可以横向滚动（鼠标拖拽 + 滚轮）', (tester) async {
    // 音源多到装不下，才滚得动
    library.dispose();
    final paths = PluginPaths(root: tempDir.path);

    final plugins = MusicFreePlugins(
      host: MusicFreeHost(bundleSource: '', paths: paths),
      paths: paths,
    );
    library = MusicFreeLibrary(
      plugins: plugins,
      service: _FakeService(
        plugins,
        chartGroups: <MusicFreeTopListGroup>[
          for (var i = 1; i <= 20; i++)
            MusicFreeTopListGroup(
              platform: 'p$i',
              title: '榜$i',
              items: <MusicFreeSheet>[_sheet('s$i', '榜单项$i')],
            ),
        ],
      ),
    );
    await pumpKiosk(tester);

    final scrollable = find.descendant(
      of: find.byKey(const ValueKey<String>('chart-tabs')),
      matching: find.byType(Scrollable),
    );
    expect(scrollable, findsOneWidget);
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.maxScrollExtent, greaterThan(0), reason: 'tab 条应该超宽');
    expect(position.pixels, 0);

    // 桌面端默认不允许鼠标拖动滚动，这里必须能拖
    await tester.drag(
      scrollable,
      const Offset(-260, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0), reason: '鼠标拖拽要能横向滚动');

    // 滚轮：竖向滚轮映射成横向
    position.jumpTo(0);
    await tester.pump();
    final pointer = TestPointer(7, PointerDeviceKind.mouse);
    final center = tester.getCenter(scrollable);
    await tester.sendEventToBinding(pointer.hover(center));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 160)));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0), reason: '滚轮要能横向滚动');
  });
  testWidgets('热门歌单：标签 → 歌单 → 详情', (tester) async {
    await pumpKiosk(tester);

    await tester.tap(find.text('热门歌单'));
    await tester.pumpAndSettle();

    // 标签（pinned + 分组）与歌单列表
    expect(find.text('流行'), findsOneWidget);
    expect(find.text('摇滚'), findsOneWidget);
    expect(find.text('纯音乐歌单'), findsOneWidget);

    await tester.tap(find.text('纯音乐歌单'));
    await tester.pumpAndSettle();

    expect(find.text('共 1 首'), findsOneWidget);
    expect(find.text('歌单第一首'), findsOneWidget);
    expect(find.text('编辑推荐'), findsOneWidget);
  });

  testWidgets('热门歌单：标签去重成横向 tab，歌单是卡片网格（重复项不再崩界面）', (tester) async {
    library.dispose();
    final paths = PluginPaths(root: tempDir.path);
    final plugins = MusicFreePlugins(
      host: MusicFreeHost(bundleSource: '', paths: paths),
      paths: paths,
    );
    library = MusicFreeLibrary(
      plugins: plugins,
      service: _FakeService(
        plugins,
        // 插件重复返回同一个标签（过去会因重复 key 把 tab 条渲染崩掉）
        tags: MusicFreeTags(
          pinned: <MusicFreeTag>[_tag('g1', '流行'), _tag('g1', '流行')],
          groups: <MusicFreeTagGroup>[
            MusicFreeTagGroup(
              title: '风格',
              tags: <MusicFreeTag>[_tag('g2', '摇滚'), _tag('g2', '摇滚')],
            ),
          ],
        ),
        // 同一张歌单也重复返回
        sheets: <MusicFreeSheet>[
          _sheet('a1', '歌单甲'),
          _sheet('a1', '歌单甲'),
          _sheet('a2', '歌单乙'),
        ],
      ),
    );
    await pumpKiosk(tester);

    await tester.tap(find.text('热门歌单'));
    await tester.pumpAndSettle();

    // 标签：去重后每个只有一条 tab
    expect(
      find.byKey(const ValueKey<String>('sheet-tag:test:g1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('sheet-tag:test:g2')),
      findsOneWidget,
    );
    // 歌单：去重后是卡片网格（两张卡并排）
    expect(find.text('歌单甲'), findsOneWidget);
    final first = tester.getRect(find.text('歌单甲'));
    final second = tester.getRect(find.text('歌单乙'));
    expect(second.top, first.top, reason: '卡片在同一行并排');
    expect(second.left, greaterThan(first.left));

    // 切到另一个标签：重新拉歌单，不崩、内容照旧
    await tester.tap(find.byKey(const ValueKey<String>('sheet-tag:test:g2')));
    await tester.pumpAndSettle();
    expect(find.text('歌单甲'), findsOneWidget);
  });

  testWidgets('热门歌单是双层 tab：第一层音源、第二层该音源的类别', (tester) async {
    library.dispose();
    final paths = PluginPaths(root: tempDir.path);
    final plugins = MusicFreePlugins(
      host: MusicFreeHost(bundleSource: '', paths: paths),
      paths: paths,
    );
    MusicFreeTag tagOf(String platform, String id, String title) =>
        MusicFreeTag(
          platform: platform,
          id: id,
          title: title,
          raw: <String, dynamic>{'id': id, 'title': title},
        );
    library = MusicFreeLibrary(
      plugins: plugins,
      service: _FakeService(
        plugins,
        tags: MusicFreeTags(
          pinned: <MusicFreeTag>[
            tagOf('kg', 'pop', '流行'),
            tagOf('tx', 'rec', '推荐'),
          ],
          groups: <MusicFreeTagGroup>[
            MusicFreeTagGroup(
              title: '风格',
              tags: <MusicFreeTag>[tagOf('kg', 'rock', '摇滚')],
            ),
          ],
        ),
        sheets: <MusicFreeSheet>[
          _sheet('a1', '歌单甲', creator: '某某'),
          _sheet('a2', '歌单乙'),
        ],
      ),
    );
    await pumpKiosk(tester);

    await tester.tap(find.text('热门歌单'));
    await tester.pumpAndSettle();

    // 第一层：两个音源
    expect(find.byKey(const ValueKey<String>('sheet-source:kg')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('sheet-source:tx')), findsOneWidget);
    // 第二层：默认展示第一个音源（kg）的类别，另一个音源的类别不混进来
    expect(
      find.byKey(const ValueKey<String>('sheet-tag:kg:pop')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('sheet-tag:kg:rock')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('sheet-tag:tx:rec')),
      findsNothing,
      reason: '第二层只显示当前音源的类别',
    );

    // 切音源 → 第二层类别跟着换
    await tester.tap(find.byKey(const ValueKey<String>('sheet-source:tx')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('sheet-tag:tx:rec')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('sheet-tag:kg:pop')),
      findsNothing,
    );
  });

  testWidgets('卡片是大封面 + 两行标题 + 更小的作者，没有外边框', (tester) async {
    library.dispose();
    final paths = PluginPaths(root: tempDir.path);
    final plugins = MusicFreePlugins(
      host: MusicFreeHost(bundleSource: '', paths: paths),
      paths: paths,
    );
    library = MusicFreeLibrary(
      plugins: plugins,
      service: _FakeService(
        plugins,
        sheets: <MusicFreeSheet>[
          _sheet(
            'a1',
            '这是一个特别长的歌单标题用来验证最多两行然后显示省略号不要溢出',
            creator: '某某同学',
          ),
          _sheet('a2', '歌单乙'),
        ],
      ),
    );
    await pumpKiosk(tester);

    await tester.tap(find.text('热门歌单'));
    await tester.pumpAndSettle();

    final title = tester.widget<Text>(
      find.text('这是一个特别长的歌单标题用来验证最多两行然后显示省略号不要溢出'),
    );
    expect(title.maxLines, 2, reason: '标题最多两行');
    expect(title.overflow, TextOverflow.ellipsis, reason: '超过两行显示省略号');

    final creator = tester.widget<Text>(find.text('某某同学'));
    expect(
      creator.style!.fontSize!,
      lessThan(title.style!.fontSize!),
      reason: '作者字号要比标题小',
    );

    // 大封面在标题上方，宽度撑满卡片（不是列表里那种 40px 小缩略图）
    final cover = tester.getRect(find.byType(MusicCover).first);
    final titleRect = tester.getRect(
      find.text('这是一个特别长的歌单标题用来验证最多两行然后显示省略号不要溢出'),
    );
    expect(cover.bottom, lessThanOrEqualTo(titleRect.top + 1), reason: '标题在封面下方');
    expect(cover.width, greaterThan(120), reason: '封面要占满卡片宽度');
  });

  testWidgets('搜索是双层 tab：第一层类型、第二层音源，切 tab 会带新条件重搜', (tester) async {
    await pumpKiosk(tester);

    await tester.enterText(find.byType(TextField), '富士山下');
    await tester.tap(find.widgetWithText(FilledButton, '搜索'));
    await tester.pumpAndSettle();

    // 两层 tab 都在，且默认「音乐 + 全部」
    expect(find.byKey(const ValueKey<String>('search-types')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('search-platforms')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('search-type:music')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('search-type:album')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('search-platform:__all__')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('search-platform:kg')),
      findsOneWidget,
    );
    expect(service.lastSearchType, 'music');
    expect(service.lastSearchPlatform, isNull, reason: '默认搜全部音源');
    expect(find.text('搜到的歌'), findsOneWidget);

    // 切类型 → 结果换成该类型的，并提示不能直接点歌
    await tester.tap(find.byKey(const ValueKey<String>('search-type:album')));
    await tester.pumpAndSettle();
    expect(service.lastSearchType, 'album');
    expect(find.text('album 结果'), findsOneWidget);
    expect(find.text('搜到的歌'), findsNothing);
    expect(find.textContaining('暂不支持直接点歌'), findsOneWidget);

    // 切音源 → 只搜该音源
    await tester.tap(find.byKey(const ValueKey<String>('search-platform:tx')));
    await tester.pumpAndSettle();
    expect(service.lastSearchType, 'album', reason: '类型保持不变');
    expect(service.lastSearchPlatform, 'tx');
  });

  testWidgets('底部播放条：播放模式左边的心形把在播的歌收进「我喜欢」', (tester) async {
    // 服务端模式下队列里就有「当前曲」，播放条显示的是它
    session.music.setViewer(peerId: 'peer-me');
    session.music.applySnapshot(
      MusicSnapshot(revision: 1, current: _currentEntry('e1')),
    );
    await pumpKiosk(tester);

    final heart = find.byType(NowPlayingFavoriteButton);
    expect(heart, findsOneWidget);
    expect(
      tester.getCenter(heart).dx,
      lessThan(tester.getCenter(find.byType(PlaybackModeButton)).dx),
      reason: '心形要排在播放模式左边',
    );

    await tester.tap(heart);
    await tester.pumpAndSettle();
    expect(favorites.length, 1);
    expect(favorites.tracks.single.name, '在播的歌');

    // 收进去的立刻能在左导航「我喜欢」里再点一遍
    await tester.tap(find.text('我喜欢'));
    await tester.pumpAndSettle();
    expect(find.text('在播的歌'), findsWidgets);
  });
}
