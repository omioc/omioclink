import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'music_models.dart';

/// 点歌台的本地存储（与服务器无关的那部分）：最近点过的歌、「我喜欢」。
///
/// 队列、当前曲这类**房间状态**不在这里——那些由服务端权威持有（见
/// `docs/氛围音技术调研报告.md` §4），本地只留纯个人偏好与自己点过的历史。
class MusicStore {
  static const _recentKey = 'omioclink.music.recent';
  static const _volumeKey = 'omioclink.music.volume';

  /// 「我喜欢」：本机自己的一份收藏，与服务端无关。
  static const _favoritesKey = 'omioclink.music.favorites';
  static const _recentLimit = 30;

  /// 氛围音音量（0~100）。各人独立、纯本地：服务器不知道、也不需要知道。
  Future<double?> loadVolume() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_volumeKey);
  }

  Future<void> saveVolume(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_volumeKey, value);
  }

  Future<List<MusicTrack>> loadRecent() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_recentKey);
    return raw == null ? const <MusicTrack>[] : _decode(raw);
  }

  Future<void> saveRecent(List<MusicTrack> tracks) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = tracks.take(_recentLimit).toList(growable: false);
    await prefs.setStringList(
      _recentKey,
      trimmed.map((track) => jsonEncode(track.toJson())).toList(growable: false),
    );
  }

  Future<void> clearRecent() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_recentKey);
  }

  /// 「我喜欢」：整首歌原样存下来。
  ///
  /// 必须带上 `musicInfo`——再次播放时插件要靠它解析直链，缺了就点不动；
  /// 这份列表只在本机，服务器不知道也不会同步（见 [MusicFavorites]）。
  Future<List<MusicTrack>> loadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_favoritesKey);
    return raw == null ? const <MusicTrack>[] : _decode(raw);
  }

  Future<void> saveFavorites(List<MusicTrack> tracks) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _favoritesKey,
      tracks.map((track) => jsonEncode(track.toJson())).toList(growable: false),
    );
  }

  /// 把一行一条的 JSON 解回歌曲；单条坏数据（旧版本残留、手改过）跳过就好，
  /// 不能让一条解析失败把整份列表拖没。
  List<MusicTrack> _decode(List<String> raw) {
    final tracks = <MusicTrack>[];
    for (final item in raw) {
      try {
        final decoded = jsonDecode(item);
        if (decoded is Map<String, dynamic>) {
          tracks.add(MusicTrack.fromJson(decoded));
        }
      } on FormatException {
        continue;
      }
    }
    return tracks;
  }
}
