import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'music_models.dart';

/// 点歌台的本地存储（与服务器无关的那部分）：最近点过的歌。
///
/// 队列、当前曲这类**房间状态**不在这里——那些由服务端权威持有（见
/// `docs/氛围音技术调研报告.md` §4），本地只留纯个人偏好与自己点过的历史。
class MusicStore {
  static const _recentKey = 'omioclink.music.recent';
  static const _volumeKey = 'omioclink.music.volume';
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
    if (raw == null || raw.isEmpty) {
      return const <MusicTrack>[];
    }
    final tracks = <MusicTrack>[];
    for (final item in raw) {
      try {
        final decoded = jsonDecode(item);
        if (decoded is Map<String, dynamic>) {
          tracks.add(MusicTrack.fromJson(decoded));
        }
      } on FormatException {
        // 单条坏数据不影响其它记录
        continue;
      }
    }
    return tracks;
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
}
