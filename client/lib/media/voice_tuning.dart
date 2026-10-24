import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'voice_profile.dart';

// 语音链路的三个「能在 Dart 侧落地」的调优点，全部做成纯函数，方便单测：
//
// 1. `voiceMicrophoneConstraints` —— 采集约束（回声消除 / 降噪 / 自动增益 / 高通）；
// 2. `applyVoiceCodecTuning`      —— 改写本地 SDP 里 Opus 的 `a=fmtp`；
// 3. `voiceSendParameters`        —— 音频发送通道的码率上限与网络优先级。
//
// 为什么不改 `flutter_webrtc`（守则里也写了「不改 flutter_webrtc」）：这三个点用的
// 都是它已经透出来的接口。libwebrtc 的降噪强度、抖动缓冲目标延迟都没有暴露到
// 方法通道上，硬改插件就得自己编 libwebrtc，所以只能在「它给的开关」里做最优解。

/// 麦克风的音频采集约束。
///
/// 桌面端（Windows/Linux）选**输入**设备的键是 `sourceId`——那里的 `deviceId`
/// 表示的是**播放**设备，拿麦克风的 id 去填它不但选不中麦克风，还可能把输出设备
/// 切到别处；Web 与移动端则沿用 `deviceId`。
///
/// 四个处理开关由档位决定（见 `voice_profile.dart` 的 `micProcessingFor`）；
/// 原生的 `GetUserAudio` 会把它们翻成 `RTCAudioOptions`，这是唯一的降噪/增益入口。
Map<String, dynamic> voiceMicrophoneConstraints({
  required VoiceProfile profile,
  String? deviceId,
  required bool desktop,
}) {
  final processing = micProcessingFor(profile);
  final audio = <String, dynamic>{
    'echoCancellation': processing.echoCancellation,
    'noiseSuppression': processing.noiseSuppression,
    'autoGainControl': processing.autoGainControl,
    'highpassFilter': processing.highpassFilter,
  };
  if (deviceId != null && deviceId.isNotEmpty) {
    audio[desktop ? 'sourceId' : 'deviceId'] = deviceId;
  }
  return <String, dynamic>{'audio': audio, 'video': false};
}

/// Opus 的 `a=fmtp` 参数里我们要强制写死的那几项。
///
/// * `maxaveragebitrate` —— 默认不写时 libwebrtc 按 32k 单声道发，这是「听得出是
///   人声」的下限而不是「好听」的水平。写死到 64k/96k 才有商业语音的清晰度；
/// * `useinbandfec=1` —— Opus 自带的前向纠错（LBRR）。丢包时靠它补，不必等 NACK
///   重传，**这是最直接的降延迟手段**：一次重传在跨城链路上就是几十毫秒；
/// * `usedtx=0` —— 显式关掉不连续发射。DTX 靠 VAD 判断「没在说话就不发包」，
///   哼唱、长音、呼吸这类内容会被判成静音而**整段被切掉**；它省的那点带宽对
///   这次通话毫无意义；
/// * `minptime=10` —— 声明最小打包时长为 10ms（实际帧长仍由编码器按 20ms 打，
///   但协商成 10 可以避免对端按 40ms 攒包）；
/// * `stereo` / `sprop-stereo` —— **不写**。采集侧本来就是单声道
///   （`channelCount: 1`），写 stereo=1 只会把同一份信号编两遍、白花一倍码率。
Map<String, String> opusFmtpOverrides(VoiceProfile profile) => <String, String>{
  'minptime': '10',
  'useinbandfec': '1',
  'usedtx': '0',
  'maxaveragebitrate': '${opusTargetBitrateFor(profile)}',
};

/// 把本地 SDP 里所有 Opus 的 `a=fmtp` 按档位改一遍（纯函数）。
///
/// 为什么改 SDP 而不是调 API：libwebrtc 没有「设置 Opus 码率」的方法通道接口，
/// 它只认协商出来的 `a=fmtp`——编码器是按协商结果建的。所以这里在本端
/// `setLocalDescription` 之前把 fmtp 改掉，改的只是**我们自己发送方向**的参数
/// （SDP 里 fmtp 描述的就是该方向发送方的能力），对端照旧解析得动：
/// 不认识的参数一律忽略，且对端跑的是同一个客户端，同样会把它的 fmtp 改掉。
///
/// 只动 Opus 那几行，其它编解码（PCMU/PCMA/G722/red/rtx）与其余 SDP 内容原样保留。
/// 找不到 Opus 时原样返回（例如对端只支持 PCMU 的极端情况）。
String applyVoiceCodecTuning(String sdp, VoiceProfile profile) {
  if (sdp.isEmpty || !sdp.toLowerCase().contains('opus')) {
    return sdp;
  }

  final separator = sdp.contains('\r\n') ? '\r\n' : '\n';
  final lines = sdp.split(separator);
  final overrides = opusFmtpOverrides(profile);

  // 先收集 Opus 的 payload type：rtpmap 可能出现在 fmtp 之后（虽然 libwebrtc 不会
  // 这么写，但 SDP 是外部输入，不假设顺序）。
  final opusPayloads = <String>{};
  for (final line in lines) {
    final payload = _opusPayloadType(line);
    if (payload != null) {
      opusPayloads.add(payload);
    }
  }
  if (opusPayloads.isEmpty) {
    return sdp;
  }

  final result = <String>[];
  final rewritten = <String>{};
  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i];
    final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    final fmtpPayload = _fmtpPayloadType(line);
    if (fmtpPayload != null && opusPayloads.contains(fmtpPayload)) {
      result.add(
        'a=fmtp:$fmtpPayload ${_mergeFmtpParams(_fmtpParams(line), overrides)}',
      );
      rewritten.add(fmtpPayload);
      continue;
    }
    result.add(raw);
    // rtpmap 之后补一行 fmtp（原本没有 fmtp 时才会走到这里）
    final payload = _opusPayloadType(line);
    if (payload != null && !_hasFmtpLater(lines, payload, i)) {
      // 参数顺序按 opusFmtpOverrides 的固定顺序，日志里好对照
      result.add('a=fmtp:$payload ${_mergeFmtpParams('', overrides)}');
      rewritten.add(payload);
    }
  }

  if (rewritten.isEmpty) {
    return sdp;
  }
  return result.join(separator);
}

/// 把「本地描述已改好」这件事写进日志用的一行摘要。
String describeVoiceCodecTuning(VoiceProfile profile) {
  final params = opusFmtpOverrides(profile);
  return params.entries.map((entry) => '${entry.key}=${entry.value}').join(';');
}

/// 音频发送通道的编码参数。
///
/// * `maxBitrate` —— 与 fmtp 里的 `maxaveragebitrate` 对齐，避免两个上限互相打架；
/// * `networkPriority: high` —— 让 libwebrtc 把这些音频包按最高优先级放进 pacer、
///   并在开了 `enableDscp` 的连接上打 EF（加速转发）标记：投屏占满上行时，
///   音频不会再排在一堆视频包后面等——**这是「投屏时语音变慢/断续」的直接解法**；
/// * `priority: high` —— 码率分配上的权重，音频优先于视频。
///
/// 不发 `minBitrate`：网络差的时候不该硬逼着编码器花比特。
RTCRtpParameters voiceSendParameters(VoiceProfile profile) => RTCRtpParameters(
  encodings: <RTCRtpEncoding>[
    RTCRtpEncoding(
      maxBitrate: opusTargetBitrateFor(profile),
      priority: RTCPriorityType.high,
      networkPriority: RTCPriorityType.high,
    ),
  ],
);

/// `a=rtpmap:111 opus/48000/2` → `111`；不是 Opus 时返回 null。
String? _opusPayloadType(String line) {
  final match = RegExp(
    r'^a=rtpmap:(\d+)\s+opus/48000(?:/\d+)?\s*$',
    caseSensitive: false,
  ).firstMatch(line);
  return match?.group(1);
}

/// `a=fmtp:111 minptime=10;...` → `111`；不是 fmtp 时返回 null。
String? _fmtpPayloadType(String line) {
  final match = RegExp(
    r'^a=fmtp:(\d+)\s',
    caseSensitive: false,
  ).firstMatch(line);
  return match?.group(1);
}

/// 取 fmtp 行里 `a=fmtp:<pt> ` 之后的那一段参数文本。
String _fmtpParams(String line) {
  final index = line.indexOf(' ');
  return index < 0 ? '' : line.substring(index + 1).trim();
}

/// 同一 m 段里后面是否已经有该 payload 的 fmtp 行（避免重复插入）。
bool _hasFmtpLater(List<String> lines, String payload, int from) {
  for (var i = from + 1; i < lines.length; i++) {
    final line = lines[i].endsWith('\r')
        ? lines[i].substring(0, lines[i].length - 1)
        : lines[i];
    if (line.startsWith('m=')) {
      // 出了这一段就不要再往后面找：m 行是分段边界
      return false;
    }
    if (_fmtpPayloadType(line) == payload) {
      return true;
    }
  }
  return false;
}

/// 合并 fmtp 参数：保留原有的未知项与顺序，覆盖项按 [overrides] 的顺序追加。
String _mergeFmtpParams(String existing, Map<String, String> overrides) {
  final merged = <String>[];
  final seenKeys = <String>{};
  void addPair(String key, String? value) {
    if (!seenKeys.add(key)) {
      return;
    }
    merged.add(value == null ? key : '$key=$value');
  }

  if (existing.isNotEmpty) {
    for (final part in existing.split(';')) {
      final item = part.trim();
      if (item.isEmpty) {
        continue;
      }
      final eq = item.indexOf('=');
      final key = eq < 0 ? item : item.substring(0, eq).trim();
      final value = eq < 0 ? null : item.substring(eq + 1).trim();
      // 我们强制覆盖的键先跳过，等下按固定顺序补回来
      if (overrides.containsKey(key)) {
        continue;
      }
      addPair(key, value);
    }
  }
  for (final entry in overrides.entries) {
    addPair(entry.key, entry.value);
  }
  return merged.join(';');
}

/// 从一条 `inbound-rtp` 统计里读出「这次通话的延迟花在哪」。
///
/// `jitterBufferDelay / jitterBufferEmittedCount` 就是 NetEq 平均把每个包压在抖动
/// 缓冲里多久——**这是判断「延迟高是网络还是本地缓冲」最快的一个数**：
///
/// * 40ms 以下：抖动缓冲没问题，剩下的延迟在路上（RTT、路由器排队）；
/// * 上百毫秒：缓冲在攒包，多半是丢包/抖动严重，或者上行被投屏挤满了；
/// * `concealedSamples` 占比是「补出来的音频」比例，超过几个百分点就能听出来。
///
/// 拿不到字段时对应项不出现（不同平台上报的字段并不完全一致）。
String describeInboundAudioLatency(Map<Object?, Object?> values) {
  final parts = <String>[];
  final bufferDelay = _asDouble(values['jitterBufferDelay']);
  final emitted = _asDouble(values['jitterBufferEmittedCount']);
  if (bufferDelay != null && emitted != null && emitted > 0) {
    parts.add('抖动缓冲=${(bufferDelay / emitted * 1000).round()}ms');
  }
  final jitter = _asDouble(values['jitter']);
  if (jitter != null) {
    // libwebrtc 上报的是秒，转成毫秒看着更直观
    final ms = jitter < 10 ? jitter * 1000 : jitter;
    parts.add('抖动=${ms.toStringAsFixed(1)}ms');
  }
  final lost = _asDouble(values['packetsLost']);
  if (lost != null) {
    parts.add('丢包=${lost.round()}');
  }
  final concealed = _asDouble(values['concealedSamples']);
  final decoded = _asDouble(values['samplesDecoded']);
  if (concealed != null && decoded != null && decoded > 0) {
    parts.add('补偿=${(concealed / decoded * 100).toStringAsFixed(1)}%');
  }
  return parts.join(' ');
}

double? _asDouble(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value);
  }
  return null;
}
