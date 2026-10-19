import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/app_log.dart';
import 'media_models.dart';

/// 麦克风采集约束。
///
/// 关键差异：桌面端（Windows/Linux）选**输入**设备的键是 `sourceId`——
/// 那里的 `deviceId` 表示的是**播放**设备，拿麦克风的 id 去填它不但选不中
/// 麦克风，还可能把输出设备切到别处；Web 与移动端则沿用 `deviceId`。
Map<String, dynamic> microphoneConstraints({String? deviceId, bool? desktop}) {
  final isDesktop = desktop ?? (!kIsWeb && WebRTC.platformIsDesktop);
  final audio = <String, dynamic>{
    'echoCancellation': true,
    'noiseSuppression': true,
    'autoGainControl': true,
  };
  if (deviceId != null && deviceId.isNotEmpty) {
    audio[isDesktop ? 'sourceId' : 'deviceId'] = deviceId;
  }
  return <String, dynamic>{'audio': audio, 'video': false};
}

/// 「这次采集该用哪个麦克风」的解析结果。
class AudioInputChoice {
  const AudioInputChoice({required this.missing, required this.deviceId});

  /// 设备表里一台输入设备都没有：调用方**必须放弃采集**，不要再调 `getUserMedia`。
  final bool missing;

  /// 本次采集要用的设备 id；空串表示跟随系统默认设备。
  final String deviceId;
}

/// 在枚举到的输入设备里解析出这次采集该用哪个设备。
///
/// 为什么采集前必须先看设备表：**Windows 上「没有麦克风」不会让 `getUserMedia`
/// 失败**。原生（flutter_webrtc `GetUserAudio`）只在录音设备表里找一遍 `sourceId`，
/// 然后无条件建一条麦克风轨道——设备数为 0 时它照样把 `RecordingDeviceName(0, …)`
/// 与 `SetRecordingDevice(0)` 打出去（越界的失败还被原生吞掉），返回的轨道底下
/// 没有任何采集端点，是条「幽灵」轨。谁相信它，谁就会把这条轨道推进
/// PeerConnection（试麦自环、房间发送通道），让原生音频链路在没有采集设备的情况下
/// 启动，表现就是整机卡死或闪退。所以设备表为空时宁可不采集。
///
/// [devices] 传 `enumerateDevices` 的结果，**null 表示这次枚举失败了**——那与
/// 「一台设备都没有」是两回事：前者不该拒绝用户（按原样再试一次采集），后者必须拒绝。
/// 另外，选中的设备已经不在表里（拔了耳机、换了机器）时退回系统默认设备：拿着一个
/// 选不中的 `sourceId` 去采集，同样会落回上面那条没有任何端点的幽灵轨。
AudioInputChoice chooseAudioInput({
  required List<AudioDevice>? devices,
  String? requested,
}) {
  final wanted = requested ?? '';
  final list = devices;
  if (list == null) {
    return AudioInputChoice(missing: false, deviceId: wanted);
  }
  if (list.isEmpty) {
    return const AudioInputChoice(missing: true, deviceId: '');
  }
  if (wanted.isEmpty || list.any((device) => device.deviceId == wanted)) {
    return AudioInputChoice(missing: false, deviceId: wanted);
  }
  return const AudioInputChoice(missing: false, deviceId: '');
}

/// 采集前解析该用哪个输入设备；比 [chooseAudioInput] 多一层「这份设备表可信吗」。
///
/// [seenDeviceBefore] 表示这台机器**此前确实枚举到过**输入设备。Windows 上采集过
/// 一次之后再枚举音频设备会得到空表（原生音频设备模块终止后不再列出设备），此时
/// 按「没有麦克风」拒绝就是误伤——设备明明还在（试麦→停止→进房、退出房间再进房，
/// 都会走到这里）。退回系统默认设备继续采集即可；真没有设备时会在 `getUserMedia`
/// 或音轨校验处失败，不会静默把幽灵轨放行。
AudioInputChoice resolveAudioInput({
  required List<AudioDevice>? devices,
  String? requested,
  bool seenDeviceBefore = false,
}) {
  final choice = chooseAudioInput(devices: devices, requested: requested);
  if (choice.missing && seenDeviceBefore) {
    return const AudioInputChoice(missing: false, deviceId: '');
  }
  return choice;
}

/// 从一份 getStats 报告里挑出「本地麦克风」的实时电平（0..1 线性）。
///
/// 只认 `media-source`（本地音源，Windows 上唯一真正带 `audioLevel` 的报告）
/// 与 `outbound-rtp`（部分平台也提供）；`inbound-rtp` 是对方的声音，绝不能
/// 算进「我在说话」。同一时刻多份报告都有值时取最大。
double? extractLocalAudioLevel(Iterable<StatsReport> reports) {
  double? highest;
  for (final report in reports) {
    if (report.type != 'media-source' && report.type != 'outbound-rtp') {
      continue;
    }
    final values = report.values;
    final kind = values['kind'];
    if (kind != null && kind != 'audio') {
      continue;
    }
    final level = values['audioLevel'];
    if (level is! num) {
      continue;
    }
    final value = level.toDouble();
    if (highest == null || value > highest) {
      highest = value;
    }
  }
  return highest;
}

/// 房间外试麦用的电平探针：一对**自环** PeerConnection。
///
/// 为什么不是一条连接？音频发送流要等协商完成才会启动，麦克风采集与
/// `media-source` 的电平统计随之才产出数据——只设置本地 SDP 的「半条」
/// 连接会让 getStats 永远返回 0（实测于 Windows + libwebrtc m150）。
/// 所以这里建两条、互发 offer/answer 与候选，让本地麦克风真的走一遍
/// 发送链路：
///
/// * 发送端 `_tx` 挂着本地麦克风轨道，电平从它身上读；
/// * 接收端 `_rx` 只负责把链路走通，收到的音频**不接播放器**（否则试麦
///   会听到自己的声音）。
class LocalMicProbe {
  LocalMicProbe({this.label = 'mic-probe'});

  final String label;

  RTCPeerConnection? _tx;
  RTCPeerConnection? _rx;
  bool _starting = false;
  bool _closed = false;

  /// 是否已建立（建立中与已关闭都返回 false）。
  bool get running => _tx != null;

  /// 采样一次；返回 null 表示暂时拿不到（无轨道 / 正在建立 / 建立失败）。
  Future<double?> sample(MediaStreamTrack? track) async {
    if (_closed || track == null) {
      return null;
    }
    var tx = _tx;
    if (tx == null) {
      if (_starting) {
        return null; // 上一轮还在建，别叠加
      }
      tx = await _start(track);
      if (tx == null) {
        return null;
      }
    }
    try {
      return extractLocalAudioLevel(await tx.getStats());
    } on Object catch (error) {
      AppLog.debug('读取试麦电平失败：$error');
      return null;
    }
  }

  Future<RTCPeerConnection?> _start(MediaStreamTrack track) async {
    _starting = true;
    try {
      final configuration = <String, dynamic>{
        'iceServers': <dynamic>[],
        'sdpSemantics': 'unified-plan',
      };
      AppLog.info('建立本地试麦回环（$label）…');
      final tx = await createPeerConnection(configuration);
      final rx = await createPeerConnection(configuration);
      _tx = tx;
      _rx = rx;

      // 候选可能早于对端 setRemoteDescription 到达，先缓存再补发
      final pendingTx = <RTCIceCandidate>[];
      final pendingRx = <RTCIceCandidate>[];
      var txReady = false;
      var rxReady = false;
      tx.onIceCandidate = (candidate) {
        if (!txReady) {
          pendingTx.add(candidate);
          return;
        }
        _addCandidate(rx, candidate);
      };
      rx.onIceCandidate = (candidate) {
        if (!rxReady) {
          pendingRx.add(candidate);
          return;
        }
        _addCandidate(tx, candidate);
      };
      // 收到的远端音轨不接播放器，试麦时不该听到自己
      rx.onTrack = (event) => event.track.enabled = false;

      final outbound = await tx.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv),
      );
      await rx.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv),
      );
      await outbound.sender.replaceTrack(track);

      final offer = await tx.createOffer();
      await tx.setLocalDescription(offer);
      await rx.setRemoteDescription(RTCSessionDescription(offer.sdp!, 'offer'));
      final answer = await rx.createAnswer();
      await rx.setLocalDescription(answer);
      await tx.setRemoteDescription(
        RTCSessionDescription(answer.sdp!, 'answer'),
      );

      txReady = true;
      rxReady = true;
      for (final candidate in pendingTx) {
        await _addCandidate(rx, candidate);
      }
      for (final candidate in pendingRx) {
        await _addCandidate(tx, candidate);
      }
      AppLog.info('本地试麦回环已建立（$label）');
      return tx;
    } on Object catch (error) {
      AppLog.warn('本地试麦回环建立失败，房间外将看不到音量', error: error);
      await dispose();
      return null;
    } finally {
      _starting = false;
    }
  }

  Future<void> _addCandidate(
    RTCPeerConnection pc,
    RTCIceCandidate candidate,
  ) async {
    if (candidate.candidate == null) {
      return;
    }
    try {
      await pc.addCandidate(candidate);
    } on Object catch (error) {
      AppLog.debug('添加自环候选失败：$error');
    }
  }

  Future<void> dispose() async {
    _closed = true;
    final rx = _rx;
    final tx = _tx;
    _rx = null;
    _tx = null;
    for (final pc in <RTCPeerConnection?>[rx, tx]) {
      if (pc == null) {
        continue;
      }
      try {
        await pc.close();
      } on Object catch (error) {
        AppLog.debug('关闭试麦回环失败：$error');
      }
    }
  }
}
