import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/core/app_theme.dart';
import 'package:omioclink_client/data/music_models.dart';
import 'package:omioclink_client/features/music/now_playing.dart';
import 'package:omioclink_client/music/music_player.dart';
import 'package:omioclink_client/musicfree/musicfree_service.dart';
import 'package:omioclink_client/room/room_music.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _hintText = '客户端直连音源 · 服务端仅同步曲目与开始时间，不转发音频';

const String _lrc = '''
[ti:富士山下]
[00:00.00]第一句歌词
[00:02.00]第二句歌词
[00:04.50]第三句歌词
''';

MusicTrack _track(String id, String name) => MusicTrack(
  platform: 'kugou',
  id: id,
  name: name,
  artists: const <MusicArtist>[MusicArtist(name: '陈奕迅')],
);

/// 房间氛围音卡片：去重标签、滚动歌词、待播队列弹框、播放控制。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 造一个「正在播第一首 + 待播 queue」的播放器。
  ///
  /// `resolve` 故意不完成：单测里没有 libmpv，真去 open 会炸；
  /// 停在 resolving 正好让队列状态保持不变，方便断言。
  MusicPlayer buildPlayer(
    RoomMusicQueue queue, {
    Future<String?> Function(MusicTrack)? loadLyric,
  }) {
    final player = MusicPlayer(
      queue: queue,
      resolve: (_) => Completer<MusicFreeMediaSource>().future,
      loadLyric: loadLyric,
    );
    addTearDown(player.dispose);
    return player;
  }

  Future<void> pumpCard(
    WidgetTester tester,
    RoomMusicQueue queue,
    MusicPlayer player,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1320, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          backgroundColor: AppThemePacks.night.palette.stage,
          body: Center(
            child: SizedBox(
              width: 900,
              child: AmbientCard(queue: queue, player: player),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('卡片里「同步播放中」只出现一次：歌曲行不再重复挂胶囊', (tester) async {
    final queue = RoomMusicQueue();
    queue.enqueue(_track('1', '富士山下'));
    queue.next();
    queue.enqueue(_track('2', '第二名'));

    await pumpCard(tester, queue, buildPlayer(queue));

    expect(find.text('同步播放中'), findsOneWidget);
    expect(find.text('即将播放'), findsNothing);
    expect(find.text('富士山下'), findsOneWidget);
  });

  testWidgets('卡片上有播放/暂停与下一首，点「下一首」会推进队列', (tester) async {
    final queue = RoomMusicQueue();
    queue.enqueue(_track('1', '富士山下'));
    queue.next();
    queue.enqueue(_track('2', '第二名'));

    await pumpCard(tester, queue, buildPlayer(queue));

    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(find.byIcon(Icons.skip_next), findsOneWidget);
    expect(queue.nowPlaying?.name, '富士山下');

    await tester.tap(find.byIcon(Icons.skip_next));
    await tester.pumpAndSettle();

    expect(queue.nowPlaying?.name, '第二名');
    expect(find.text('第二名'), findsOneWidget);
  });

  testWidgets('「接下来 N 首」右侧按钮弹出待播队列，关闭后消失', (tester) async {
    final queue = RoomMusicQueue();
    queue.enqueue(_track('1', '富士山下'));
    queue.next();
    queue.enqueue(_track('2', '第二名'));
    queue.enqueue(_track('3', '第三名'));

    await pumpCard(tester, queue, buildPlayer(queue));

    expect(find.text('接下来 2 首'), findsOneWidget);
    expect(find.text('接下来播放（2 首）'), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('ambient-upcoming-queue')));
    await tester.pumpAndSettle();

    expect(find.text('接下来播放（2 首）'), findsOneWidget);
    expect(find.text('第二名'), findsOneWidget);
    expect(find.text('第三名'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '关闭'));
    await tester.pumpAndSettle();

    expect(find.text('接下来播放（2 首）'), findsNothing);
    expect(find.text('第三名'), findsNothing);
  });

  testWidgets('歌词在左、架构说明在右，且歌词随播放位置换句', (tester) async {
    final queue = RoomMusicQueue();
    queue.enqueue(_track('1', '富士山下'));
    queue.next();
    final player = buildPlayer(queue, loadLyric: (_) async => _lrc);

    await pumpCard(tester, queue, player);

    // 卡片不会自己开播：手动触发一次，让歌词加载完（resolve 会一直挂着）
    unawaited(player.playCurrent());
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('第一句歌词'), findsOneWidget);
    expect(find.text(_hintText), findsOneWidget);

    player.debugSetPosition(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('第二句歌词'), findsOneWidget);
    expect(find.text('第一句歌词'), findsNothing);

    player.debugSetPosition(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('第三句歌词'), findsOneWidget);

    final lyricCenter = tester.getCenter(find.text('第三句歌词')).dx;
    final hintCenter = tester.getCenter(find.text(_hintText)).dx;
    expect(
      hintCenter,
      greaterThan(lyricCenter),
      reason: '提示信息要居右，左侧位置留给歌词',
    );
  });

  testWidgets('插件没有歌词时左侧显示占位，不影响其它信息', (tester) async {
    final queue = RoomMusicQueue();
    queue.enqueue(_track('1', '富士山下'));
    queue.next();
    final player = buildPlayer(queue, loadLyric: (_) async => null);

    await pumpCard(tester, queue, player);
    unawaited(player.playCurrent());
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('暂无歌词'), findsOneWidget);
    expect(find.text(_hintText), findsOneWidget);
    expect(find.text('富士山下'), findsOneWidget);
  });
}
