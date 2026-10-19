import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/data/music_models.dart';
import 'package:omioclink_client/music/music_favorites.dart';
import 'package:shared_preferences/shared_preferences.dart';

MusicTrack _track(String id, {String name = '', String platform = 'test'}) =>
    MusicTrack(
      platform: platform,
      id: id,
      name: name.isEmpty ? '歌$id' : name,
      artists: <MusicArtist>[MusicArtist(name: '歌手$id')],
      durationMs: 210000,
      musicInfo: <String, dynamic>{'id': id, 'source': platform},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('「我喜欢」状态', () {
    test('喜欢过的歌排在前面，重复点不会存两份', () {
      final favorites = MusicFavorites();
      addTearDown(favorites.dispose);

      favorites.add(_track('a'));
      favorites.add(_track('b'));
      // 同一首歌再点一次（音源 + id 相同）不算新增
      favorites.add(_track('a'));

      expect(favorites.length, 2);
      // 新的在最前面：刚喜欢的歌不用滚到底才能看到
      expect(
        favorites.tracks.map((track) => track.id).toList(),
        <String>['b', 'a'],
      );
      expect(favorites.contains(_track('a')), isTrue);
      expect(favorites.contains(_track('a', platform: 'other')), isFalse);
    });

    test('toggle：在列表里就移出，不在就加到最前面', () {
      final favorites = MusicFavorites();
      addTearDown(favorites.dispose);

      expect(favorites.toggle(_track('a')), isTrue);
      expect(favorites.contains(_track('a')), isTrue);
      expect(favorites.toggle(_track('a')), isFalse);
      expect(favorites.contains(_track('a')), isFalse);
      expect(favorites.isEmpty, isTrue);
    });

    test('清空后列表为空', () {
      final favorites = MusicFavorites();
      addTearDown(favorites.dispose);

      favorites
        ..add(_track('a'))
        ..add(_track('b'))
        ..clear();

      expect(favorites.isEmpty, isTrue);
      expect(favorites.contains(_track('a')), isFalse);
    });

    test('超过上限丢最老的那首，不静默留一堆', () {
      final favorites = MusicFavorites(limit: 2);
      addTearDown(favorites.dispose);

      favorites
        ..add(_track('a'))
        ..add(_track('b'))
        ..add(_track('c'));

      expect(
        favorites.tracks.map((track) => track.id).toList(),
        <String>['c', 'b'],
      );
      expect(favorites.contains(_track('a')), isFalse);
    });
  });

  group('「我喜欢」是本机缓存', () {
    test('新开一份（相当于重启客户端）能读回上次的收藏，且带完整 musicInfo', () async {
      final first = MusicFavorites();
      first.add(_track('a', name: '存下来的歌'));
      await first.flush();
      first.dispose();

      final second = MusicFavorites();
      addTearDown(second.dispose);
      await second.load();

      expect(second.length, 1);
      expect(second.tracks.single.name, '存下来的歌');
      // musicInfo 必须原样带回来：再次播放要靠它解析直链，缺了就点不动
      expect(second.tracks.single.musicInfo['id'], 'a');
    });

    test('取消喜欢会落盘：重开不会又冒出来', () async {
      final first = MusicFavorites();
      first.add(_track('a'));
      first.remove(_track('a'));
      await first.flush();
      first.dispose();

      final second = MusicFavorites();
      addTearDown(second.dispose);
      await second.load();

      expect(second.isEmpty, isTrue);
    });

    test('单条坏数据只丢那一条，其它照常读出来', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'omioclink.music.favorites': <String>[
          '不是 JSON',
          '{"platform":"test","id":"z","name":"好歌","musicInfo":{"id":"z"}}',
        ],
      });

      final favorites = MusicFavorites();
      addTearDown(favorites.dispose);
      await favorites.load();

      expect(favorites.length, 1);
      expect(favorites.tracks.single.id, 'z');
    });

    test('读盘失败不抛到界面：当成没有收藏', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        // 类型存错了（不是字符串列表）
        'omioclink.music.favorites': 42,
      });

      final favorites = MusicFavorites();
      addTearDown(favorites.dispose);
      await favorites.load();

      expect(favorites.isEmpty, isTrue);
    });
  });
}
