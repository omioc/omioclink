import 'dart:io';

import 'package:flutter/services.dart';

import '../core/app_log.dart';

/// 通话期间向 Android 申请「保活」：前台服务（话筒类型）+ 唤醒锁 + WiFi 锁。
///
/// 为什么必须做：手机息屏后系统会把普通进程暂停/降频，WebRTC 的麦克风采集与
/// 远端播放随之断掉——表现就是「锁屏一会儿就掉出房间，也说不了听不到」。
/// 原生实现在 `android/.../CallForegroundService.kt`，这里只是开关。
///
/// 桌面 / iOS 什么都不做（桌面没有这个限制，iOS 需要另一套 background audio
/// 配置，不在本次范围内）。
class CallKeepalive {
  CallKeepalive._();

  /// 与 `MainActivity.kt` 里的通道名一致。
  static const MethodChannel _channel = MethodChannel('omioclink/keepalive');

  static bool _enabled = false;

  /// 是否处于保活状态（单测/排障用）。
  static bool get isEnabled => _enabled;

  /// 进房成功后调用。可重复调用（幂等），失败只记日志、不影响通话。
  static Future<void> enable() async {
    if (!Platform.isAndroid || _enabled) {
      return;
    }
    _enabled = true;
    try {
      await _channel.invokeMethod<void>('start');
    } on Object catch (error) {
      // 起不来就退回原样：息屏可能断，但当前通话不受影响
      _enabled = false;
      AppLog.warn('开启通话保活失败（息屏后可能掉线）', error: error);
    }
  }

  /// 离开房间 / 释放时调用。可重复调用（幂等）。
  static Future<void> disable() async {
    if (!Platform.isAndroid || !_enabled) {
      return;
    }
    _enabled = false;
    try {
      await _channel.invokeMethod<void>('stop');
    } on Object catch (error) {
      AppLog.debug('关闭通话保活失败：$error');
    }
  }
}
