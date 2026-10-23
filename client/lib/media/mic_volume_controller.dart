import 'package:flutter/foundation.dart';

import '../core/app_log.dart';
import '../core/l10n_ext.dart';
import 'mic_volume.dart';

/// 麦克风音量控制器：持久化 + 即时下发 + 降级（无设备/原生失败 → 只记日志 + 暴露 notice，绝不抛）。
///
/// 与音乐音量的分工：音乐音量只关本机播放器，麦克风音量直接改**系统录音设备**的
/// 主音量（Windows 声音设置里那根「麦克风」滑块），对方听到的大小由它决定。
/// 单位统一用 0~100，端口那边是 0.0~1.0。
///
/// 降级策略：调不动（非 Windows、没有录音设备、COM 调用失败）时不阻断用户，
/// 只是把原因放进 [notice] 给界面显示，用户的拖动照样记下来并持久化。
class MicVolumeController extends ChangeNotifier {
  MicVolumeController({
    MicVolumePort? port,
    Future<double?> Function()? load,
    Future<void> Function(double value)? save,
  }) : _port = port ?? createMicVolumePort(),
       // 没注入持久化时退化成「读不到 / 不落盘」，与逐处判空等价
       _load = load ?? _noSavedVolume,
       _save = save ?? _discardVolume;

  /// 没有持久化来源：当作「没有存过的值」。
  static Future<double?> _noSavedVolume() async => null;

  /// 没有持久化去处：丢掉即可（降级环境不该因为存不下来而报错）。
  static Future<void> _discardVolume(double value) async {}

  /// 没有别的线索时的降级说明（界面直接显示这句）。
  ///
  /// 用 getter 而不是 const：文案要跟着语言走，常量只能存一份死字符串。
  static String get unsupportedNotice => appL10n.mediaMicVolumeDefaultReason;

  final MicVolumePort _port;
  final Future<double?> Function() _load;
  final Future<void> Function(double value) _save;

  double _volume = 100;
  String? _notice;
  bool _disposed = false;

  /// 0~100（同音乐音量、麦克风滑块的单位）。
  double get volume => _volume;

  /// 当前平台/设备是否真的能调音量（[notice] 非空时基本为 false）。
  bool get supported => _port.supported;

  /// 不支持/失败时给界面看的中文说明，正常为 null。
  String? get notice {
    if (_notice != null) {
      return _notice;
    }
    // 还没下发过就已经确定不支持：也要让界面能显示原因
    if (_port.supported) {
      return null;
    }
    return _port.lastError ?? unsupportedNotice;
  }

  /// 读持久化值（没有就 100）并应用到设备。
  Future<void> load() async {
    var percent = 100.0;
    try {
      final saved = await _load();
      if (saved != null && saved.isFinite) {
        percent = saved.clamp(0.0, 100.0).toDouble();
      }
    } on Object catch (error) {
      AppLog.warn('读取本地保存的麦克风音量失败，按 100% 处理', error: error);
    }
    if (_disposed) {
      return;
    }
    _volume = percent;
    notifyListeners();
    await _apply();
  }

  /// 滑块直接调它：立刻下发到设备 + 持久化；范围钳制到 0~100。
  Future<void> setVolume(double percent) async {
    final target = percent.isFinite
        ? percent.clamp(0.0, 100.0).toDouble()
        : _volume;
    // 先落到界面上：拖动时不卡手，成功与否都由 notice 事后说明
    _volume = target;
    if (_disposed) {
      return;
    }
    notifyListeners();
    await _apply();
    await _persist(target);
  }

  /// 重新应用当前值（启动、切换麦克风设备后调用）。
  Future<void> reapply() async {
    if (_disposed) {
      return;
    }
    await _apply();
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _port.dispose();
    super.dispose();
  }

  /// 把当前 [volume] 下发到设备，结果写进 [notice] 与日志。
  Future<void> _apply() async {
    if (_disposed) {
      return;
    }
    final label = '${_formatPercent(_volume)}%';
    if (!_port.supported) {
      final reason = _port.lastError ?? unsupportedNotice;
      _notice = reason;
      AppLog.info('麦克风音量 $label：未下发，$reason');
      if (!_disposed) {
        notifyListeners();
      }
      return;
    }
    final normalized = (_volume / 100.0).clamp(0.0, 1.0).toDouble();
    final written = _port.writeVolume(normalized);
    if (written) {
      _notice = null;
      AppLog.info('麦克风音量 $label（下发 ${_formatScalar(normalized)}）：成功');
    } else {
      final reason = _port.lastError ?? appL10n.mediaMicVolumeWriteFallback;
      _notice = reason;
      AppLog.warn('麦克风音量 $label（下发 ${_formatScalar(normalized)}）：失败，$reason');
    }
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// 持久化用户的选择；写失败只记日志，不影响本次调节。
  Future<void> _persist(double percent) async {
    try {
      await _save(percent);
    } on Object catch (error) {
      AppLog.warn('保存麦克风音量失败（不影响本次调节）', error: error);
    }
  }

  /// `42` / `42.5`（滑块的 0~100 取值，去掉多余的小数）。
  static String _formatPercent(double value) {
    final text = value.toStringAsFixed(1);
    return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
  }

  /// `0.42`：下发给设备的 0.0~1.0 标量。
  static String _formatScalar(double value) => value.toStringAsFixed(2);
}
