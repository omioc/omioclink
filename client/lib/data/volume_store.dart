import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 三条音量通道的本机持久化（纯本地：服务器不知道，也不告诉房间里的任何人）。
///
/// * 音乐音量 —— 走 `MusicStore`（`omioclink.music.volume`，0~100），沿用播放器音量通道；
/// * 成员音量 —— 按**成员的服务器身份**（`userId`）记成一张表，0~2 的增益倍率；
/// * 麦克风音量 —— 本机当前默认录音设备的主音量，0~100。
///
/// 三者的单位在 UI 上统一成百分比：成员 0~200%，音乐/麦克风 0~100%。
/// 存储内容坏掉（手改过、旧版本残留、写到一半）时一律回落默认值，绝不抛给界面。
class VolumeStore {
  static const _peerKey = 'omioclink.volume.peers';
  static const _micKey = 'omioclink.volume.mic';

  /// 没设置过的成员按 100% 处理（= 不放大也不衰减）。
  static const double defaultPeerVolume = 1.0;

  /// 成员音量下限：0 表示静音（走确定性静音路径，见 `PeerAudioMixer`）。
  static const double minPeerVolume = 0;

  /// 成员音量上限：200%（听不清的成员可以放大一倍）。
  static const double maxPeerVolume = 2;

  /// 麦克风音量上限（百分比）。
  static const double maxMicVolume = 100;

  /// 把任意输入收敛到合法增益：非数/NaN/无穷回落默认，越界钳制。
  static double clampPeerVolume(double value) {
    if (value.isNaN || value.isInfinite) {
      return defaultPeerVolume;
    }
    return value.clamp(minPeerVolume, maxPeerVolume).toDouble();
  }

  /// 把任意输入收敛到合法的麦克风百分比。
  static double clampMicVolume(double value) {
    if (value.isNaN || value.isInfinite) {
      return maxMicVolume;
    }
    return value.clamp(0, maxMicVolume).toDouble();
  }

  /// 读出所有保存过的成员音量（`userId → 0~2`）。
  ///
  /// 单条坏数据只丢那一条，不影响其它成员；整块坏掉就返回空表（全部走默认）。
  Future<Map<String, double>> loadPeerVolumes() async {
    final prefs = await SharedPreferences.getInstance();
    String? raw;
    try {
      raw = prefs.getString(_peerKey);
    } on Object {
      // 存成了别的类型（手改/旧版本残留）：当没设置过，全部按默认
      return <String, double>{};
    }
    if (raw == null || raw.isEmpty) {
      return <String, double>{};
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return <String, double>{};
    }
    if (decoded is! Map) {
      return <String, double>{};
    }
    final result = <String, double>{};
    decoded.forEach((key, value) {
      if (key is! String || key.isEmpty) {
        return;
      }
      if (value is! num) {
        return;
      }
      final volume = value.toDouble();
      if (volume.isNaN || volume.isInfinite) {
        return;
      }
      result[key] = clampPeerVolume(volume);
    });
    return result;
  }

  /// 写入一名成员的音量（会先钳制到 [minPeerVolume]~[maxPeerVolume]）。
  Future<void> savePeerVolumes(Map<String, double> volumes) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = <String, double>{};
    volumes.forEach((userId, volume) {
      if (userId.isEmpty) {
        return;
      }
      encoded[userId] = clampPeerVolume(volume);
    });
    if (encoded.isEmpty) {
      await prefs.remove(_peerKey);
      return;
    }
    await prefs.setString(_peerKey, jsonEncode(encoded));
  }

  /// 读出麦克风音量（0~100）；没设置过返回 null（调用方按 100 处理）。
  Future<double?> loadMicVolume() async {
    final prefs = await SharedPreferences.getInstance();
    double? value;
    try {
      value = prefs.getDouble(_micKey);
    } on Object {
      // 存成了别的类型：当没设置过
      return null;
    }
    if (value == null) {
      return null;
    }
    if (value.isNaN || value.isInfinite) {
      return null;
    }
    return clampMicVolume(value);
  }

  Future<void> saveMicVolume(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_micKey, clampMicVolume(value));
  }
}
