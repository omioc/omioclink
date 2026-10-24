import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter/services.dart';

import '../core/app_log.dart';
import '../core/l10n_ext.dart';
import '../signaling/protocol.dart';
import 'media_models.dart';
import 'mic_capture.dart';
import 'mic_meter.dart';
import 'peer_audio_mixer.dart';
import 'screen_capture.dart';
import 'screen_policy_governor.dart';
import 'share_policy.dart';
import 'system_output_device.dart';
import 'uplink_budget.dart';
import 'voice_profile.dart';
import 'voice_tuning.dart';

/// 媒体层的对外回调（由 `RoomSession` 实现，把本地 SDP / 候选交给信令送出）。
class MediaEngineCallbacks {
  const MediaEngineCallbacks({
    required this.onLocalDescription,
    required this.onLocalCandidate,
    required this.onLinkStateChanged,
    required this.onDataChannel,
  });

  /// 本地 SDP 就绪（`type` 为 offer / answer），需要发给对端。
  final Future<void> Function(String peerId, String type, String sdp)
  onLocalDescription;

  /// 本地 ICE 候选就绪；`candidate == null` 表示候选收集结束。
  final void Function(String peerId, IceCandidatePayload? candidate)
  onLocalCandidate;

  /// 连接状态变化（用于渲染信号格 / 直连状态）。
  final void Function(String peerId, PeerLinkState state) onLinkStateChanged;

  /// 对端建好了数据通道（聊天/状态广播走这里，不进服务器）。
  final void Function(String peerId, RTCDataChannel channel) onDataChannel;
}

/// 一条成员连接的内部状态。
class _PeerSlot {
  _PeerSlot({required this.peerId, required this.pc, required this.polite});

  final String peerId;
  final RTCPeerConnection pc;
  final bool polite;

  bool makingOffer = false;
  bool remoteDescriptionSet = false;
  bool closed = false;

  /// 自己发出去的 offer 还没收到 answer。
  ///
  /// 这期间新加的发送通道不在那份 offer 里，得等这轮谈完再补一轮，见
  /// [_maybeRenegotiate]。
  bool offerInFlight = false;

  /// 有「在途 offer 之后新建的发送通道」等着补谈，收到 answer 时消费。
  bool needsRenegotiation = false;

  /// SDP 就绪前先缓存远端候选，避免 `addCandidate` 早于 `setRemoteDescription`。
  final List<IceCandidatePayload> pendingCandidates = <IceCandidatePayload>[];

  RTCRtpSender? audioSender;

  /// 屏幕共享的发送通道（屏幕轨道在 WebRTC 里的 kind 就是 `video`）。
  RTCRtpSender? screenSender;

  RTCDataChannel? dataChannel;

  /// 屏幕流里的回环音频（系统/应用声音）的发送通道。
  ///
  /// 和 [audioSender]（麦克风）分开：投屏带声音时两条音频各走各的 m 行，
  /// 复用一个 sender 会把麦克风顶掉。
  RTCRtpSender? screenAudioSender;

  RTCVideoRenderer? audioRenderer;

  /// 音频渲染器是否已经初始化过。
  ///
  /// 重协商后同一条连接会再来一条远端音轨，重复 `initialize()` 在原生侧会抛异常，
  /// 而调用点（[_handleRemoteTrack]）是 `unawaited` 进来的：一抛就把后面的
  /// `srcObject` 绑定与音量接管全跳过，表现就是「对端在说、本机一点声音都没有」。
  bool audioRendererReady = false;

  RTCVideoRenderer? screenRenderer;
  MediaStream? remoteAudioStream;
  MediaStream? remoteScreenStream;

  /// 对方的音频轨道（本机调音量 / 屏蔽某人时用它）。
  MediaStreamTrack? remoteAudioTrack;
}

/// 聊天 / 轻量状态同步共用的数据通道标签。
const String kDataChannelLabel = 'omioclink';

/// 对 `flutter_webrtc` 的薄封装。
///
/// 关键设计：
/// * **每成员一条 PeerConnection**（mesh），由 `RoomSession` 决定谁向谁发起 offer；
/// * **主叫方**（进房时间靠后的那一位）在建连时用 `addTransceiver` 预置音频与屏幕
///   两个 `sendrecv` transceiver：offer 里必须有两个 m 行，被叫才有位置回送媒体；
///   之后开关麦克风、开始/停止屏幕共享只需 `replaceTrack`，不用重新协商；
/// * **被叫方**（房间里已有的人）不预置：预置的 transceiver 不会被对端 offer 复用，
///   会让 answer 退化成 `recvonly`（详见 [_addSendChannel]）。它有轨道时用 `addTrack`
///   建发送通道，没有就等轨道出现时补一轮协商；
/// * 只配置 `stun:` 服务器，**不存在 relay/TURN**：媒体路径不可能经过服务器；
/// * 不做摄像头视频：本应用的「视频」只有屏幕共享这一种。
class MediaEngine {
  MediaEngine({List<String> iceServers = const <String>[]})
    : _iceServers = List.of(iceServers) {
    _watchAudioDeviceChanges();
  }

  final List<String> _iceServers;

  /// 订阅系统音频设备插拔（耳机接入/拔出等），供设置页刷新设备下拉。
  void _watchAudioDeviceChanges() {
    try {
      navigator.mediaDevices.ondevicechange = (_) {
        audioDevicesVersion.value += 1;
        _onAudioDevicesChanged();
      };
    } on Object catch (error) {
      AppLog.debug('订阅音频设备变更失败：$error');
    }
  }

  /// 系统播放设备可能换人了（插拔耳机、在系统设置里改默认）：通话中重新对齐一次。
  ///
  /// 只在通话中处理：空闲时下一次进房（[startLocalAudio] / [ensurePeer]）会自己对齐，
  /// 而**出房还原**本身也会触发设备变更事件——那时再对齐一次，就会把刚还原的设置
  /// 又改回去，来回打架。
  void _onAudioDevicesChanged() {
    if (!windowsOutputRoutingAvailable || _peers.isEmpty) {
      return;
    }
    _voiceOutputEndpoint = null;
    AppLog.info('系统播放设备变了：通话中无法立刻切换，重新进房后语音会跟到新设备');
    unawaited(_applyVoiceOutput());
  }

  /// 用服务器下发的 STUN 列表刷新配置（只影响之后新建的连接）。
  ///
  /// 全部为 `stun:`，服务器不提供任何 relay，媒体路径不可能经过服务器。
  void updateIceServers(List<String> servers) {
    _iceServers
      ..clear()
      ..addAll(servers.where((server) => server.trim().isNotEmpty));
  }

  List<String> get iceServers => List.unmodifiable(_iceServers);
  final Map<String, _PeerSlot> _peers = <String, _PeerSlot>{};

  /// 每个成员的远端音频状态机（音量 / 本地静音 → 音轨与渲染器的实际动作）。
  final PeerAudioMixer peerAudio = PeerAudioMixer();

  MediaEngineCallbacks? callbacks;

  MediaStream? _localAudio;
  MediaStream? _screen;

  /// 用户选的编码策略：带宽吃紧时先牺牲分辨率还是帧率。
  SharePolicy _screenPolicy = SharePolicy.fallback;

  /// 每一路当前该用的编码目标（peerId → 参数），由 [_recomputeScreenPlan] 现算。
  ///
  /// 观众的增减都会让它作废重算——mesh 下每个人的额度都是别人让出来的。
  Map<String, ScreenTarget> _screenPlan = const <String, ScreenTarget>{};

  /// 采集源的实际分辨率。DXGI 不认采集约束里的 maxHeight，只能按出图尺寸量。
  int _screenSourceWidth = 0;
  int _screenSourceHeight = 0;

  /// 采集刚起来时渲染器还没出帧，隔一小会儿按真实尺寸补算一次分配。
  Timer? _screenPlanRefreshTimer;

  /// 均衡档的内容判定状态机（只在用户选了均衡档时被驱动）。
  final ScreenPolicyGovernor _policyGovernor = ScreenPolicyGovernor();

  /// 均衡档的采样定时器：2 秒一次，跟着统计轮询的节奏走。
  Timer? _policyTimer;

  /// 当前实际生效的策略：均衡档下由 [_policyGovernor] 覆写，其余档位就是用户选的那个。
  SharePolicy get _effectivePolicy =>
      _policyGovernor.effective ?? _screenPolicy;

  /// 共享中把自己采到的画面挂上去，共享者本人也能看到「正在共享的是什么」。
  RTCVideoRenderer? _localScreenRenderer;

  String? _audioInputId;
  String? _audioOutputId;

  /// 语音当前被固定到的播放端点（null = 还没接管）。
  ///
  /// 「跟随系统」时它是系统默认**设备**（＝音乐那只），手选时就是用户挑的那只。
  String? _voiceOutputEndpoint;

  /// 为了把语音挪到 [_voiceOutputEndpoint]，我们临时改掉了系统的默认**通信**
  /// 设备；这里存原值，出房时还原（null = 没动过系统设置）。
  String? _restoreCommEndpoint;

  /// 在途的那次「对齐」：采集与建连会同时调用，共用同一次尝试。
  Future<void>? _voiceOutputInFlight;

  /// 这台机器此前是否真的枚举到过输入设备。
  ///
  /// 用来区分两种「空表」：**从没枚举到过**（多半真没有麦克风）与**曾经有、
  /// 这次却空了**（Windows 上采集过一次之后的老毛病，见 [startLocalAudio]）。
  bool _seenInputDevice = false;
  bool _microphoneMuted = false;
  bool _speakerEnabled = true;
  bool _disposed = false;

  /// 当前语音档位（决定采集侧四个处理开关、Opus 码率与是否保留哼唱）。
  ///
  /// 默认取 [VoiceProfile.fallback]；换成已保存的那一档由 `AppState` 在启动时下发。
  VoiceProfile _voiceProfile = VoiceProfile.fallback;

  /// 当前语音档位（界面显示「现在是哪一档」用）。
  VoiceProfile get voiceProfile => _voiceProfile;

  /// 切换语音档位。
  ///
  /// 采集约束只在 `getUserMedia` 那一刻生效，所以正在采集时必须重采一次才真的换挡；
  /// 没在采集就只记下来，下次采集自然按新档位走。重采会短暂哑一下（约一两百毫秒），
  /// 因此只在档位真的变了的时候做。
  Future<void> setVoiceProfile(VoiceProfile profile) async {
    if (profile == _voiceProfile) {
      return;
    }
    _voiceProfile = profile;
    AppLog.info('语音档位 → ${profile.storageId}（${describeVoiceCodecTuning(profile)}）');
    final deviceId = _audioInputId;
    if (_localAudio == null) {
      return;
    }
    try {
      await stopLocalAudio();
      await startLocalAudio(deviceId: deviceId);
    } on Object catch (error) {
      // 换挡失败不该把设置页带崩：档位已经记下，下次采集（含重新进房）会按新档走。
      // 最常见的原因是「这一步设备正好被拔掉」，那时采集本来也用不了。
      AppLog.warn('切换语音档位后重采麦克风失败', error: error);
    }
  }

  /// 房间外试麦用的自环电平探针（采集期间存在，停止试麦即释放）。
  LocalMicProbe? _micProbe;

  /// 音频设备列表版本号：插拔设备时自增，设置页据此重新枚举。
  final ValueNotifier<int> audioDevicesVersion = ValueNotifier<int>(0);

  /// 麦克风实时电平与说话判定；界面与房间层都从这里读。
  late final MicLevelMeter _micMeter = MicLevelMeter(
    sampler: sampleLocalAudioLevel,
  );

  ValueListenable<MicLevel> get micLevel => _micMeter;

  // ------------------------------------------------------------------ 本地采集
  MediaStream? get localAudioStream => _localAudio;
  MediaStream? get screenStream => _screen;
  bool get isScreenSharing => _screen != null;

  /// 本地共享画面的预览渲染器（只在共享期间存在）。
  ///
  /// 共享者的「大画面」就靠它——远端画面渲染器对共享者自己没有值，
  /// 没有它共享者只能看到一块黑屏加一句「你正在共享屏幕」。
  RTCVideoRenderer? get localScreenRenderer => _localScreenRenderer;
  bool get microphoneMuted => _microphoneMuted;
  bool get speakerEnabled => _speakerEnabled;

  /// 当前选用的输入设备（`null`/空串表示跟随系统默认）。
  ///
  /// 还没开始采集时它记录的是「下次采集要用的设备」，选中即生效。
  String? get activeAudioInputId => _audioInputId;

  /// 当前选用的输出设备（`null`/空串表示跟随系统默认）。
  String? get activeAudioOutputId => _audioOutputId;

  MediaStreamTrack? get _localAudioTrack {
    final tracks = _localAudio?.getAudioTracks();
    if (tracks == null || tracks.isEmpty) {
      return null;
    }
    return tracks.first;
  }

  /// 屏幕流里的回环音频轨（投屏时选了「分享应用/系统声音」才有）。
  MediaStreamTrack? get _screenAudioTrack {
    final tracks = _screen?.getAudioTracks();
    if (tracks == null || tracks.isEmpty) {
      return null;
    }
    return tracks.first;
  }

  MediaStreamTrack? get _screenTrack {
    final tracks = _screen?.getVideoTracks();
    if (tracks == null || tracks.isEmpty) {
      return null;
    }
    return tracks.first;
  }

  /// 采集麦克风。已有采集时直接复用。
  ///
  /// [deviceId] 省略时沿用当前选择（设置页选过就跟着走，不会被无声冲掉）；
  /// 显式传空串表示跟随系统默认设备。
  ///
  /// 采集前先确认这台机器真的有麦克风：**Windows 上没有录音设备时
  /// `getUserMedia` 也会成功**，返回的却是一条底下没有采集端点的「幽灵」轨
  /// （原因见 [chooseAudioInput]）。把它交给连接就是让原生音频链路在没有采集
  /// 设备的情况下启动，整机卡死或闪退。宁可在这里就拒绝，并把原因写进电平状态。
  Future<void> startLocalAudio({String? deviceId}) async {
    if (_localAudio != null) {
      return;
    }
    // Web 未授权时 `enumerateDevices` 会给一份「没有 id、没有 label」的空表，
    // 那不是「这台机器没有麦克风」，别据此拒绝（这条只是防御：本应用只发桌面端）。
    final devices = kIsWeb ? null : await tryAudioDevices(input: true);
    final choice = resolveAudioInput(
      devices: devices,
      requested: deviceId ?? _audioInputId,
      seenDeviceBefore: _seenInputDevice,
    );
    if (devices != null && devices.isEmpty && !choice.missing) {
      // Windows 上采集过一次之后再枚举会拿到空表：设备还在，照常采
      AppLog.warn('输入设备表为空，但此前检测到过输入设备：按系统默认设备继续尝试采集');
    }
    if (choice.missing) {
      _failCapture(
        reason: appL10n.mediaMicMissingReason,
        message: appL10n.mediaMicMissingMessage,
        code: 'microphone_missing',
      );
    }
    final target = choice.deviceId;

    // 语音要落到和音乐同一只设备，而音频设备模块起播时才会去读系统的默认通信
    // 设备：趁播放还没起来，先把它对到目标设备上。
    await _applyVoiceOutput();

    MediaStream stream;
    try {
      AppLog.info(
        '开始采集麦克风（${target.isEmpty ? '系统默认设备' : target}）'
        '档位=${_voiceProfile.storageId} ${micProcessingFor(_voiceProfile)}',
      );
      stream = await navigator.mediaDevices.getUserMedia(
        microphoneConstraints(deviceId: target, profile: _voiceProfile),
      );
    } on Object catch (error) {
      AppLog.error('麦克风采集失败', error: error);
      _failCapture(
        reason: appL10n.mediaMicDeniedReason,
        message: appL10n.mediaMicDeniedMessage,
        code: 'microphone_denied',
      );
    }
    // 双保险：拿到的流必须真有一条音轨。设备可能在枚举之后被拔掉，原生也可能
    // 只回了一份空壳（这时 `_localAudioTrack` 为 null，电平永远读不到、发出去的
    // 声音也是空的）。收下手之前先验一遍，别让空壳流混进后续建连。
    if (stream.getAudioTracks().isEmpty) {
      await _disposeStream(stream);
      _failCapture(
        reason: appL10n.mediaMicNoTrackReason,
        message: appL10n.mediaMicNoTrackMessage,
        code: 'microphone_missing',
      );
    }

    _localAudio = stream;
    _audioInputId = target;
    _seenInputDevice = true;
    await _applyMicrophoneMute();
    await _applyAudioTrackToAllPeers();
    AppLog.info('本地麦克风已就绪（音轨 ${stream.getAudioTracks().length} 条）');
    _micProbe = LocalMicProbe();
    _micMeter
      ..setMuted(_microphoneMuted)
      ..updateCaptureState(capturing: true);
    // 采集一开始就启用电平计：房间外（设置页试麦）也能看到实时电平
    _micMeter.start();
  }

  /// 采集失败的统一出口：先把原因写进电平状态（界面据此显示红灯与文案），
  /// 再抛给调用方（设置页弹提示、房间层写 `lastError`）。
  ///
  /// 返回 [Never]：调用点之后不可能再继续用「采集成功了」的分支。
  Never _failCapture({
    required String reason,
    required String message,
    required String code,
  }) {
    _micMeter.updateCaptureState(capturing: false, error: reason);
    throw MediaException(message, code: code);
  }

  Future<void> stopLocalAudio() async {
    final stream = _localAudio;
    _localAudio = null;
    _micMeter
      ..stop()
      ..updateCaptureState(capturing: false);
    final probe = _micProbe;
    _micProbe = null;
    await probe?.dispose();
    if (stream == null) {
      return;
    }
    await _disposeStream(stream);
    for (final slot in _peers.values) {
      await _replaceAudioTrack(slot, null);
    }
  }

  /// 停掉轨道并释放媒体流。
  ///
  /// 原生的 `stream.dispose()` 会抛 `MediaStreamDisposeFailed: stream not found`
  /// （实测：同一个进程里反复开关采集时，原生已经释放过那份流）。清理动作不该把
  /// 调用方带崩——退出房间、注销都会走到这里，抛出去就是一条未捕获异常。
  Future<void> _disposeStream(MediaStream stream) async {
    final tracks = <MediaStreamTrack>[
      ...stream.getAudioTracks(),
      ...stream.getVideoTracks(),
    ];
    for (final track in tracks) {
      try {
        await track.stop();
      } on Object catch (error) {
        AppLog.debug('停止轨道失败：$error');
      }
    }
    try {
      await stream.dispose();
    } on Object catch (error) {
      AppLog.debug('释放媒体流失败：$error');
    }
  }

  /// 切换麦克风输入设备（空串表示跟随系统默认）。
  ///
  /// 正在采集时重建轨道让新设备立刻生效；还没采集时只记住选择。
  Future<void> switchAudioInput(String deviceId) async {
    if (deviceId == _audioInputId) {
      return;
    }
    if (_localAudio == null) {
      _audioInputId = deviceId;
      return;
    }
    await stopLocalAudio();
    await startLocalAudio(deviceId: deviceId);
  }

  /// 切换扬声器/耳机输出设备（空串表示跟随系统默认）。
  ///
  /// 空串不是「不指定」，而是**和音乐用同一只设备**：Windows 有两个默认播放
  /// 设备，「默认设备」给音乐这类媒体流，「默认通信设备」给 VoIP。libwebrtc 的
  /// 音频设备模块走的是后者，所以「跟着系统」必须把它摆到和音乐一致
  /// （见 [_applyVoiceOutput]）。手选的设备同理。
  Future<void> switchAudioOutput(String deviceId) async {
    if (deviceId == _audioOutputId) {
      return;
    }
    _audioOutputId = deviceId;
    if (kIsWeb || !windowsOutputRoutingAvailable) {
      return;
    }
    // 目标换了就让「对齐」重新跑：同值也要重新确认一次（设备可能被拔掉）
    _voiceOutputEndpoint = null;
    if (await _alignVoiceOutputOnce()) {
      return;
    }
    // 「跟随系统」失败就按系统原样播，不打扰用户；手选设备失败要让他知道
    if (deviceId.isEmpty) {
      return;
    }
    throw MediaException(
      appL10n.mediaAudioOutputFailed,
      code: 'audio_output_switch_failed',
    );
  }

  /// 让「别人说话」和「放音乐」落到同一只播放设备上。
  ///
  /// 为什么这么绕：libwebrtc 的音频设备模块播放时用 Windows 的默认**通信**设备，
  /// 而音乐（media_kit/mpv）用默认**设备**，两者可以指向不同硬件（实测一台机器：
  /// 耳机是默认设备、显示器是默认通信设备），表现就是「放歌在耳机、别人说话在
  /// 显示器」。而 flutter_webrtc 的 `selectAudioOutput` 在 Windows 上是空实现
  /// （实测 `SetPlayoutDevice` 连越界索引都返回成功，音频设备模块的设备从没被
  /// 改过），所以只能从系统侧把「默认通信设备」指向目标设备——音频设备模块
  /// 起播时会重新读这个默认值。
  ///
  /// 调用点都在起播之前（采集开始前 / 建连前）；失败一律不抛，进房路径不能被它
  /// 带崩，语音退回系统原来的通信设备。
  Future<void> _applyVoiceOutput() async {
    if (kIsWeb || _disposed || !windowsOutputRoutingAvailable) {
      return;
    }
    final inFlight = _voiceOutputInFlight;
    if (inFlight != null) {
      await inFlight;
      return;
    }
    final attempt = _alignVoiceOutputOnce();
    _voiceOutputInFlight = attempt;
    try {
      await attempt;
    } finally {
      _voiceOutputInFlight = null;
    }
  }

  /// 解析目标设备并把系统默认通信设备指过去；返回是否已经对齐。
  Future<bool> _alignVoiceOutputOnce() async {
    if (!windowsOutputRoutingAvailable) {
      return false;
    }
    final target = voiceOutputTarget(
      chosen: _audioOutputId ?? '',
      mediaDefault: windowsDefaultOutputEndpointId(),
    );
    if (target.isEmpty) {
      AppLog.debug('取不到系统默认播放设备，语音继续跟系统的默认通信设备走');
      return false;
    }
    if (target == _voiceOutputEndpoint) {
      return true;
    }
    final current = windowsDefaultOutputEndpointId(communications: true);
    if (current == null) {
      return false;
    }
    if (current == target) {
      // 系统本来就把通信设备指向同一只：不动系统设置，也就没得还原
      _voiceOutputEndpoint = target;
      AppLog.info('语音播放设备 = $target（与音乐同一只，系统通信设备本来就一致）');
      return true;
    }
    if (!windowsPointCommunicationOutputAt(target)) {
      return false;
    }
    _restoreCommEndpoint ??= current;
    _voiceOutputEndpoint = target;
    AppLog.info('语音播放设备 → $target（与音乐同一只；已把系统默认通信设备临时指向它）');
    return true;
  }

  /// 出房/释放时把系统默认通信设备还原成我们看到的原值。
  ///
  /// 只还原「还是我们那只」的情况：中途用户自己改过，就以他的选择为准。
  void _restoreCommunicationOutput() {
    final restoreTo = _restoreCommEndpoint;
    final applied = _voiceOutputEndpoint;
    _restoreCommEndpoint = null;
    _voiceOutputEndpoint = null;
    if (restoreTo == null || applied == null || !windowsOutputRoutingAvailable) {
      return;
    }
    if (windowsDefaultOutputEndpointId(communications: true) != applied) {
      return;
    }
    if (windowsPointCommunicationOutputAt(restoreTo)) {
      AppLog.info('已把系统默认通信设备还原为 $restoreTo');
    }
  }

  /// 开关麦克风。优先用音频设备模块静音（不打断采集），失败则退化为轨道禁用。
  Future<void> setMicrophoneMuted(bool muted) async {
    _microphoneMuted = muted;
    _micMeter.setMuted(muted);
    await _applyMicrophoneMute();
  }

  Future<void> _applyMicrophoneMute() async {
    final track = _localAudioTrack;
    if (track == null) {
      return;
    }
    try {
      await Helper.setMicrophoneMute(_microphoneMuted, track);
    } on Object catch (error) {
      AppLog.warn('设备级静音不可用，退化为轨道禁用', error: error);
      track.enabled = !_microphoneMuted;
    }
  }

  /// 扬声器 / 耳机输出切换。
  Future<void> setSpeakerEnabled(bool enabled) async {
    _speakerEnabled = enabled;
    try {
      await Helper.setSpeakerphoneOn(enabled);
    } on Object catch (error) {
      AppLog.warn('切换输出设备失败', error: error);
    }
  }

  /// 枚举音频设备；下拉列表用这个（枚举失败时按空列表展示）。
  Future<List<AudioDevice>> audioDevices({required bool input}) async =>
      await tryAudioDevices(input: input) ?? const <AudioDevice>[];

  /// 枚举音频设备；**枚举本身失败时返回 null**，与「设备表为空」区分开。
  ///
  /// 差别很重要：空表意味着这台机器没有输入设备，[startLocalAudio] 必须拒绝采集
  /// （否则会拿到一条没有采集端点的幽灵轨）；而 null 只是这次枚举失败，不该据此
  /// 拒绝用户，照常按选择去试一次 `getUserMedia`。
  ///
  /// 过滤掉没有 id 的条目（界面用空串表示「系统默认设备」，不能撞车），
  /// 并按 id 去重——下拉里出现两个同值条目会直接触发框架断言。
  Future<List<AudioDevice>?> tryAudioDevices({required bool input}) async {
    final kind = input ? 'audioinput' : 'audiooutput';
    // 这一行往往是整个进程里第一次碰原生（WebRTC 工厂在这里初始化）：
    // 崩在这台机器上的话，日志最后一条就会是它
    AppLog.info('枚举音频设备($kind)…');
    try {
      final devices = await navigator.mediaDevices.enumerateDevices();
      final seen = <String>{};
      final result = <AudioDevice>[];
      for (final device in devices) {
        if (device.kind != kind || device.deviceId.isEmpty) {
          continue;
        }
        if (!seen.add(device.deviceId)) {
          continue;
        }
        result.add(
          AudioDevice(
            deviceId: device.deviceId,
            label: device.label,
            isInput: input,
          ),
        );
      }
      if (input && result.isNotEmpty) {
        _seenInputDevice = true;
      }
      AppLog.info(
        '音频设备($kind)：${result.length} 个 '
        '${result.map((device) => device.displayName).toList()}',
      );
      return List<AudioDevice>.unmodifiable(result);
    } on Object catch (error) {
      AppLog.warn('枚举音频设备失败($kind)', error: error);
      return null;
    }
  }

  // ------------------------------------------------------------------ 麦克风电平
  /// 采样本地麦克风的实时电平（0..1 线性，取自 WebRTC 统计里的 `audioLevel`）。
  ///
  /// 房间里优先读已有连接：那正是实际发出去的音频，读数最真实。房间外（比如设置页
  /// 试麦）没有连接可读，就用 [LocalMicProbe] 的自环连接来读——不需要服务器，也不
  /// 需要任何对端，但**必须是一条真正协商完成的连接**，否则发送链路不启动，统计里
  /// 只会是一串 0。
  Future<double?> sampleLocalAudioLevel() async {
    final track = _localAudioTrack;
    if (track == null || _disposed) {
      return null;
    }
    for (final slot in _peers.values) {
      if (slot.closed) {
        continue;
      }
      final level = await _audioLevelOf(slot.pc);
      if (level != null) {
        return level;
      }
    }
    return _micProbe?.sample(track);
  }

  /// 从一条连接里取本地音频电平。
  Future<double?> _audioLevelOf(RTCPeerConnection pc) async {
    try {
      return extractLocalAudioLevel(await pc.getStats());
    } on Object catch (error) {
      AppLog.debug('读取音频统计失败：$error');
      return null;
    }
  }

  // ------------------------------------------------------------------ 屏幕共享
  /// 枚举显示器与窗口（带缩略图）。Windows 下由 DXGI 提供。
  ///
  /// 枚举本身不返回缩略图（桌面端原生只给 id 与标题），所以要再向原生逐个要一张，
  /// 见 [attachScreenThumbnails]。
  Future<List<ScreenSource>> listScreenSources({
    int thumbnailWidth = 320,
    int thumbnailHeight = 180,
  }) async {
    try {
      final sources = await desktopCapturer.getSources(
        types: <SourceType>[SourceType.Screen, SourceType.Window],
        thumbnailSize: ThumbnailSize(thumbnailWidth, thumbnailHeight),
      );
      // 窗口列表是原生异步枚举的：第一次调用经常只回来一部分（剩下还在枚举），
      // 用户看到的就是「投屏能选的应用不全」。隔一小会儿再要一次，按 id 合并
      // 两次结果——第二趟通常已经补齐，名字以第二次为准。
      final merged = <String, ScreenSource>{
        for (final source in sources)
          source.id: ScreenSource(
            id: source.id,
            name: source.name,
            isWindow: source.type == SourceType.Window,
            thumbnail: source.thumbnail,
          ),
      };
      if (sources.isNotEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 260));
        try {
          final again = await desktopCapturer.getSources(
            types: <SourceType>[SourceType.Screen, SourceType.Window],
            thumbnailSize: ThumbnailSize(thumbnailWidth, thumbnailHeight),
          );
          for (final source in again) {
            final existing = merged[source.id];
            if (existing == null || existing.thumbnail == null) {
              merged[source.id] = ScreenSource(
                id: source.id,
                name: source.name.isEmpty ? (existing?.name ?? '') : source.name,
                isWindow: source.type == SourceType.Window,
                thumbnail: source.thumbnail ?? existing?.thumbnail,
              );
            }
          }
        } on Object catch (error) {
          AppLog.debug('补枚举屏幕源失败（用第一趟结果）：$error');
        }
      }
      final mapped = merged.values.toList(growable: false);
      return await attachScreenThumbnails(
        mapped,
        fetch: (sourceId) => _screenThumbnail(
          sourceId,
          width: thumbnailWidth,
          height: thumbnailHeight,
        ),
      );
    } on Object catch (error) {
      AppLog.error('枚举屏幕源失败', error: error);
      throw MediaException(
        appL10n.mediaScreenEnumFailed,
        code: 'screen_enumeration_failed',
      );
    }
  }

  /// 取单个源的缩略图（原生现截一帧，Windows 上返回的是 JPEG）。
  ///
  /// 原生忽略请求里的尺寸、返回源自身分辨率，所以拿到的图偏大，界面按需缩放解码。
  Future<Uint8List?> _screenThumbnail(
    String sourceId, {
    required int width,
    required int height,
  }) async {
    try {
      return await WebRTC.invokeMethod<Uint8List, dynamic>(
        'getDesktopSourceThumbnail',
        desktopSourceThumbnailRequest(
          sourceId: sourceId,
          width: width,
          height: height,
        ),
      );
    } on Object catch (error) {
      AppLog.debug('取缩略图失败 id=$sourceId：$error');
      return null;
    }
  }

  /// 开始共享屏幕。
  ///
  /// [withSystemAudio] 打开时会把系统回环声音并入共享流（Windows 1.5.0+）。
  /// 注意：回环音频不会成为麦克风回声消除的参考信号，外放场景需引导戴耳机。
  ///
  /// [policy] 决定带宽吃紧时先牺牲分辨率还是帧率；每一路具体发多大、多少帧，由
  /// [allocateScreenPlan] 按观众人数现算（见 `uplink_budget.dart`）。采集恒定按源
  /// 分辨率 60fps 拿，输出规格全在编码侧调。
  Future<void> startScreenShare({
    String? sourceId,
    bool withSystemAudio = false,
    SharePolicy policy = SharePolicy.fallback,
  }) async {
    if (_screen != null) {
      return;
    }
    _screenPolicy = policy;
    var target = sourceId;
    if (target == null || target.isEmpty) {
      final sources = await listScreenSources();
      if (sources.isEmpty) {
        throw MediaException(
          appL10n.mediaNoScreenSource,
          code: 'no_screen_source',
        );
      }
      target = sources.first.id;
    }

    final constraints = screenShareConstraints(
      sourceId: target,
      withSystemAudio: withSystemAudio,
    );

    try {
      _screen = await navigator.mediaDevices.getDisplayMedia(constraints);
    } on Object catch (error) {
      AppLog.error('屏幕采集失败', error: error);
      throw MediaException(
        appL10n.mediaScreenCaptureFailed,
        code: 'screen_capture_denied',
      );
    }
    await _attachLocalScreenPreview();
    _screenSourceWidth = 0;
    _screenSourceHeight = 0;
    _recomputeScreenPlan();
    _logScreenPlan();
    await _applyScreenTrackToAllPeers();
    _startPolicyGovernor();
    _scheduleSourceSizeRefresh();
  }

  /// 按当前策略、观众人数与源分辨率，重算每一路的目标参数。
  ///
  /// 只算不落参数：落参数在 [_applyScreenSendParameters]（它贴在每一条 sender 上）。
  void _recomputeScreenPlan() {
    final source = _resolvedSourceSize();
    _screenSourceWidth = source.width;
    _screenSourceHeight = source.height;
    _screenPlan = allocateScreenPlan(
      ScreenBudgetInput(
        policy: _effectivePolicy,
        budgetBps: kDefaultScreenUplinkBudgetBps,
        sourceWidth: _screenSourceWidth,
        sourceHeight: _screenSourceHeight,
        peerIds: _peers.keys.toList(growable: false),
      ),
    );
  }

  /// 采到的画面到底有多大。
  ///
  /// 先问轨道设置（原生创建时就填好了），拿不到再看本地预览渲染器解出来的尺寸；
  /// 都还没有就按 1080p 先估一版，由 [_scheduleSourceSizeRefresh] 稍后补算——
  /// 2K 源要是被当成 1080p，缩放倍数会整个偏掉。
  ({int width, int height}) _resolvedSourceSize() {
    try {
      final settings = _screenTrack?.getSettings();
      final width = (settings?['width'] as num?)?.toInt() ?? 0;
      final height = (settings?['height'] as num?)?.toInt() ?? 0;
      if (width > 0 && height > 0) {
        return (width: width, height: height);
      }
    } on Object catch (error) {
      AppLog.debug('读取屏幕轨道尺寸失败：$error');
    }
    final renderer = _localScreenRenderer;
    if (renderer != null &&
        renderer.videoWidth > 0 &&
        renderer.videoHeight > 0) {
      return (width: renderer.videoWidth, height: renderer.videoHeight);
    }
    if (_screenSourceWidth > 0 && _screenSourceHeight > 0) {
      return (width: _screenSourceWidth, height: _screenSourceHeight);
    }
    return (width: 1920, height: 1080);
  }

  /// 采集刚起来时渲染器还没出帧，尺寸只能先估一个；隔一会儿按真实尺寸补算一次。
  void _scheduleSourceSizeRefresh() {
    _screenPlanRefreshTimer?.cancel();
    _screenPlanRefreshTimer = Timer(const Duration(milliseconds: 600), () {
      if (_disposed || _screen == null) {
        return;
      }
      final before = (_screenSourceWidth, _screenSourceHeight);
      _recomputeScreenPlan();
      if (before == (_screenSourceWidth, _screenSourceHeight)) {
        return;
      }
      AppLog.info(
        '屏幕源尺寸补测为 $_screenSourceWidth×$_screenSourceHeight，重新分配上行',
      );
      _logScreenPlan();
      unawaited(_applyScreenPlanToAllPeers());
    });
  }

  /// 把这次分配结果写进日志：实测上行有没有真的按计划花出去，全靠这条对账。
  void _logScreenPlan() {
    if (_screenPlan.isEmpty) {
      AppLog.info('屏幕共享：当前没有观众，未分配上行');
      return;
    }
    final entries = _screenPlan.entries
        .map((entry) => '${entry.key}=${entry.value.label}')
        .join('、');
    AppLog.info(
      '屏幕共享分配（${_effectivePolicy.label}，源 $_screenSourceWidth×'
      '$_screenSourceHeight，预算 '
      '${(kDefaultScreenUplinkBudgetBps / 1000000).toStringAsFixed(1)}Mbps）：'
      '$entries',
    );
  }

  /// 起「均衡档」的内容判定：只有用户选了均衡档才需要，其它档位直接返回。
  void _startPolicyGovernor() {
    _policyTimer?.cancel();
    _policyGovernor.reset();
    if (_screenPolicy != SharePolicy.balanced) {
      return;
    }
    _policyTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_reviewScreenPolicy());
    });
  }

  /// 采一次画面复杂度，必要时在两个极端之间切一档。
  Future<void> _reviewScreenPolicy() async {
    if (_disposed || _screen == null) {
      return;
    }
    final qp = await _averageQp();
    final switched = _policyGovernor.sample(avgQp: qp, now: DateTime.now());
    if (switched == null) {
      return;
    }
    AppLog.info(
      '屏幕共享按内容切到「${switched.label}」'
      '（平均 QP ${qp?.toStringAsFixed(1) ?? '未知'}）',
    );
    _recomputeScreenPlan();
    _logScreenPlan();
    await _applyScreenPlanToAllPeers();
  }

  /// 各路屏幕视频的平均量化步长；一条都读不到就返回 null。
  ///
  /// 每路的链路质量不同、QP 也不同，但「画面是高动态还是静止」是全房间同一个事实，
  /// 所以取第一条能读到的就够。
  Future<double?> _averageQp() async {
    for (final peerId in _peers.keys.toList(growable: false)) {
      final snapshot = await statsFor(peerId);
      final qp = snapshot?.avgQp;
      if (qp != null) {
        return qp;
      }
    }
    return null;
  }

  Future<void> stopScreenShare() async {
    _screenPlanRefreshTimer?.cancel();
    _screenPlanRefreshTimer = null;
    _policyTimer?.cancel();
    _policyTimer = null;
    _policyGovernor.reset();
    final stream = _screen;
    _screen = null;
    _screenPlan = const <String, ScreenTarget>{};
    _screenSourceWidth = 0;
    _screenSourceHeight = 0;
    await _disposeLocalScreenPreview();
    if (stream == null) {
      return;
    }
    await _disposeStream(stream);
    for (final slot in _peers.values) {
      await _replaceScreenTrack(slot, null);
    }
    await _dropScreenAudioFromAllPeers();
  }

  /// 把采到的屏幕流挂到本地预览渲染器上。
  ///
  /// 失败只是看不到自己的预览，不影响已经开始的共享（远端照常收到画面），
  /// 所以这里不往上抛，只清掉半成品。
  Future<void> _attachLocalScreenPreview() async {
    final stream = _screen;
    if (stream == null) {
      return;
    }
    try {
      var renderer = _localScreenRenderer;
      if (renderer == null) {
        renderer = RTCVideoRenderer();
        await renderer.initialize();
        _localScreenRenderer = renderer;
      }
      renderer.srcObject = stream;
    } on Object catch (error) {
      AppLog.warn('本地共享预览不可用', error: error);
      await _disposeLocalScreenPreview();
    }
  }

  Future<void> _disposeLocalScreenPreview() async {
    final renderer = _localScreenRenderer;
    _localScreenRenderer = null;
    if (renderer == null) {
      return;
    }
    try {
      renderer.srcObject = null;
      await renderer.dispose();
    } on Object catch (error) {
      AppLog.warn('释放本地共享预览失败', error: error);
    }
  }

  // ------------------------------------------------------------------ P2P 连接
  /// 建立/复用到某成员的连接。
  ///
  /// [polite] 为 Perfect Negotiation 的角色位，由 `RoomSession` 按进房顺序确定性指派，
  /// 正常的「后进者向既有成员发 offer」规则下不会发生冲突，这里是兜底。
  Future<RTCPeerConnection> ensurePeer(
    String peerId, {
    required bool polite,
    bool createDataChannel = false,
  }) async {
    final existing = _peers[peerId];
    if (existing != null && !existing.closed) {
      return existing.pc;
    }

    final configuration = <String, dynamic>{
      'iceServers': _iceServers
          .map(
            (server) => <String, dynamic>{
              'urls': <String>[server],
            },
          )
          .toList(growable: false),
      'sdpSemantics': 'unified-plan',
      // 语音包打 DSCP 标记（EF，加速转发）。原生只认这三个键
      // （`flutter_webrtc` 的 `ParseRTCConfiguration`），投屏占满上行时，
      // 路由器/交换机若认标记就会把语音排到视频前面——这是不改包就能拿到的
      // 唯一「网络层优先级」，对「投屏时语音发飘、延迟变大」有效。
      'enableDscp': true,
      // 一条连接只用一个传输（unified-plan 下本来也是这么走）：候选只检查一份，
      // DTLS 只握一次，进房更快；音频与视频共用一个拥塞控制，pacer 里靠
      // `networkPriority: high` 保证语音优先。
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
    };

    // 音频设备模块是随建连/采集起来的，而它只在起播前读取系统的默认通信设备：
    // 趁这条连接还没有音轨，先把语音落点对到和音乐同一只设备。
    await _applyVoiceOutput();
    AppLog.info('创建 PeerConnection peer=$peerId（原生未初始化时此处会初始化 WebRTC 工厂）');
    final pc = await createPeerConnection(configuration);
    AppLog.info('PeerConnection 已创建 peer=$peerId');
    final slot = _PeerSlot(peerId: peerId, pc: pc, polite: polite);
    _peers[peerId] = slot;
    // 多了一个观众，每一路的额度都变小了：先重算分配，后面挂轨道时才会用到新参数
    if (_screen != null) {
      _recomputeScreenPlan();
    }

    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null) {
        _emitCandidate(peerId, null);
        return;
      }
      _emitCandidate(
        peerId,
        IceCandidatePayload(
          candidate: candidate.candidate!,
          sdpMid: candidate.sdpMid,
          sdpMLineIndex: candidate.sdpMLineIndex,
        ),
      );
    };

    pc.onConnectionState = (state) {
      callbacks?.onLinkStateChanged(peerId, _mapConnectionState(state));
    };

    pc.onTrack = (event) => unawaited(_handleRemoteTrack(slot, event));

    // 数据通道由 offer 方创建（确定性规则），应答方通过 onDataChannel 收到
    pc.onDataChannel = (channel) {
      slot.dataChannel = channel;
      callbacks?.onDataChannel(peerId, channel);
    };

    if (createDataChannel) {
      // 主叫（新进房的成员）：预置两个 sendrecv transceiver 占位。
      // offer 里必须有音频、视频两个 m 行，被叫才有位置回送媒体；占位 transceiver
      // 只影响我们自己发出的 offer（实测可用），之后 replaceTrack 即可。
      // 被叫**不能**这样预置，原因见 `_addSendChannel`。
      AppLog.info('预置发送通道 transceiver(audio) peer=$peerId');
      final audioTransceiver = await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv),
      );
      slot.audioSender = audioTransceiver.sender;

      AppLog.info('预置发送通道 transceiver(video) peer=$peerId');
      final screenTransceiver = await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv),
      );
      slot.screenSender = screenTransceiver.sender;

      AppLog.info('创建数据通道 peer=$peerId');
      final channel = await pc.createDataChannel(
        kDataChannelLabel,
        RTCDataChannelInit(),
      );
      slot.dataChannel = channel;
      callbacks?.onDataChannel(peerId, channel);
      AppLog.info('数据通道已创建 peer=$peerId');
    }

    AppLog.info('本地轨道挂到成员连接上 peer=$peerId');
    await _replaceAudioTrack(slot, _localAudioTrack);
    await _replaceScreenTrack(slot, _screenTrack);
    // 新观众进来后每一路的额度都变了：老的那几条也要按新分配重设，否则合计超预算
    if (_screenTrack != null) {
      _logScreenPlan();
      await _applyScreenPlanToAllPeers();
    }
    AppLog.info('已为成员 $peerId 建立 PeerConnection（polite=$polite）');
    return pc;
  }

  /// 向所有已建立的数据通道广播一条文本消息（聊天/轻量状态，P2P）。
  ///
  /// 返回成功写入的通道数；未连通的成员不会收到（不做离线排队）。
  int broadcastData(String payload) {
    var sent = 0;
    for (final slot in _peers.values) {
      final channel = slot.dataChannel;
      if (channel == null) {
        continue;
      }
      try {
        channel.send(RTCDataChannelMessage(payload));
        sent += 1;
      } on Object catch (error) {
        AppLog.warn('数据通道发送失败 peer=${slot.peerId}', error: error);
      }
    }
    return sent;
  }

  /// 当前已连通的成员数（用于「已直连 n/N」展示）。
  int get liveDataChannelCount => _peers.values
      .where(
        (slot) =>
            slot.dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen,
      )
      .length;

  /// 把本地描述里的 Opus 参数按当前档位改一遍。
  ///
  /// 为什么必须在本端 `setLocalDescription` 之前改：编码器是照着协商出来的
  /// `a=fmtp` 建的，改晚了这次协商就按默认的 32k 单声道跑到底了。
  /// SDP 原样返回（没 Opus / 没有可改的行）时不重建对象。
  RTCSessionDescription _tuneLocalDescription(
    RTCSessionDescription description,
    String peerId,
  ) {
    final sdp = description.sdp;
    if (sdp == null || sdp.isEmpty) {
      return description;
    }
    final tuned = applyVoiceCodecTuning(sdp, _voiceProfile);
    if (tuned == sdp) {
      return description;
    }
    AppLog.info(
      '本地描述已按档位调优 peer=$peerId 档位=${_voiceProfile.storageId} '
      '（${describeVoiceCodecTuning(_voiceProfile)}）',
    );
    return RTCSessionDescription(tuned, description.type);
  }

  /// 向某成员发起协商（发出 offer）。
  ///
  /// 由 `RoomSession` 显式调用：按「新成员向房间内所有既有成员发起 offer」的确定性规则，
  /// 保证同一对连接同时只有一方在 offer，从结构上避免 glare。
  ///
  /// 本地描述先按语音档位调优再生效（见 [_tuneLocalDescription]），发给对端的也是
  /// 调优后的那份——两边必须看到同一个 SDP，否则协商结果对不上。
  Future<void> negotiate(String peerId, {bool iceRestart = false}) async {
    final slot = _peers[peerId];
    if (slot == null || slot.closed) {
      return;
    }
    AppLog.info('发起协商 peer=$peerId${iceRestart ? '（ICE 重启）' : ''}');
    try {
      slot.makingOffer = true;
      final offer = await slot.pc.createOffer(
        iceRestart
            ? <String, dynamic>{'iceRestart': true}
            : <String, dynamic>{},
      );
      AppLog.info('offer 已生成 peer=$peerId（${offer.sdp?.length ?? 0} 字节）');
      // 调优后的那份既要生效也要发给对端：两边看到的 SDP 必须一致
      final tuned = _tuneLocalDescription(offer, peerId);
      await slot.pc.setLocalDescription(tuned);
      AppLog.info('本地描述已生效（offer）peer=$peerId');
      slot.needsRenegotiation = false;
      slot.offerInFlight = true;
      if (tuned.sdp != null) {
        await callbacks?.onLocalDescription(peerId, 'offer', tuned.sdp!);
      }
    } on Object catch (error) {
      AppLog.warn('创建 offer 失败 peer=$peerId', error: error);
    } finally {
      slot.makingOffer = false;
    }
  }

  /// 处理远端 offer（Perfect Negotiation 的 polite/impolite 兜底）。
  Future<void> handleRemoteOffer(String peerId, String sdp) async {
    final slot = _peers[peerId];
    if (slot == null || slot.closed) {
      AppLog.warn('收到未建立连接的 offer：$peerId');
      return;
    }
    // 我们的规则是「后进者向既有成员发 offer」，正常不会撞车；
    // 若同时收到 offer，impolite 一方忽略，polite 一方回滚重答应。
    if (slot.makingOffer && !slot.polite) {
      AppLog.info('忽略冲突的 offer peer=$peerId');
      return;
    }
    AppLog.info('收到远端 offer peer=$peerId（${sdp.length} 字节）');
    try {
      await slot.pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
      slot.remoteDescriptionSet = true;
      AppLog.info('远端描述已生效（offer）peer=$peerId');
      await _drainCandidates(slot);
      final answer = await slot.pc.createAnswer();
      // answer 里的 fmtp 描述的是「我们发」的方向，同样要按档位改
      final tuned = _tuneLocalDescription(answer, peerId);
      await slot.pc.setLocalDescription(tuned);
      AppLog.info('本地描述已生效（answer）peer=$peerId（${tuned.sdp?.length ?? 0} 字节）');
      if (tuned.sdp != null) {
        await callbacks?.onLocalDescription(peerId, 'answer', tuned.sdp!);
      }
    } on Object catch (error) {
      AppLog.warn('处理 offer 失败 peer=$peerId', error: error);
    }
  }

  Future<void> handleRemoteAnswer(String peerId, String sdp) async {
    final slot = _peers[peerId];
    if (slot == null || slot.closed) {
      return;
    }
    AppLog.info('收到远端 answer peer=$peerId（${sdp.length} 字节）');
    try {
      await slot.pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
      slot.remoteDescriptionSet = true;
      AppLog.info('远端描述已生效（answer）peer=$peerId');
      await _drainCandidates(slot);
    } on Object catch (error) {
      AppLog.warn('处理 answer 失败 peer=$peerId', error: error);
      return;
    }
    slot.offerInFlight = false;
    // 这轮 offer 之后新建的发送通道不在它对里，补谈一轮
    if (slot.needsRenegotiation && !slot.closed) {
      slot.needsRenegotiation = false;
      await negotiate(peerId);
    }
  }

  Future<void> handleRemoteCandidate(
    String peerId,
    IceCandidatePayload? candidate,
  ) async {
    final slot = _peers[peerId];
    if (slot == null || slot.closed) {
      return;
    }
    if (candidate == null) {
      return; // 候选收集结束，无需处理
    }
    if (!slot.remoteDescriptionSet) {
      slot.pendingCandidates.add(candidate);
      return;
    }
    await _addCandidate(slot, candidate);
  }

  Future<void> _addCandidate(
    _PeerSlot slot,
    IceCandidatePayload candidate,
  ) async {
    try {
      await slot.pc.addCandidate(
        RTCIceCandidate(
          candidate.candidate,
          candidate.sdpMid,
          candidate.sdpMLineIndex,
        ),
      );
    } on Object catch (error) {
      AppLog.warn('添加候选失败 peer=${slot.peerId}', error: error);
    }
  }

  Future<void> _drainCandidates(_PeerSlot slot) async {
    if (slot.pendingCandidates.isEmpty) {
      return;
    }
    final pending = List<IceCandidatePayload>.of(slot.pendingCandidates);
    slot.pendingCandidates.clear();
    for (final candidate in pending) {
      await _addCandidate(slot, candidate);
    }
  }

  /// 网络切换后尝试 ICE 重启（不需要重新协商）。
  ///
  /// 平台不支持 `restartIce()` 时回退为「带 iceRestart 约束的重新协商」。
  Future<void> restartIce(String peerId) async {
    final slot = _peers[peerId];
    if (slot == null || slot.closed) {
      return;
    }
    try {
      await slot.pc.restartIce();
    } on Object catch (error) {
      AppLog.warn('ICE 重启失败，回退为重新协商 peer=$peerId', error: error);
      await negotiate(peerId, iceRestart: true);
    }
  }

  Future<void> closePeer(String peerId) async {
    final slot = _peers.remove(peerId);
    if (slot == null) {
      return;
    }
    slot.closed = true;
    await _disposeSlot(slot);
    peerAudio.forget(peerId);
    // 少了一个观众，剩下每一路的额度都变宽了：重算并整组重设
    if (_screenTrack != null) {
      _recomputeScreenPlan();
      _logScreenPlan();
      await _applyScreenPlanToAllPeers();
    }
    callbacks?.onLinkStateChanged(peerId, PeerLinkState.closed);
  }

  Future<void> closeAllPeers() async {
    final slots = List<_PeerSlot>.of(_peers.values);
    _peers.clear();
    for (final slot in slots) {
      slot.closed = true;
      await _disposeSlot(slot);
    }
    peerAudio.clear();
    // 播放停了：把临时改过的系统默认通信设备还原回去
    _restoreCommunicationOutput();
  }

  Future<void> _disposeSlot(_PeerSlot slot) async {
    try {
      await slot.dataChannel?.close();
    } on Object catch (error) {
      AppLog.warn('关闭数据通道失败 peer=${slot.peerId}', error: error);
    }
    try {
      await slot.pc.close();
    } on Object catch (error) {
      AppLog.warn('关闭 PeerConnection 失败 peer=${slot.peerId}', error: error);
    }
    // 渲染器与远端流都要在连接关闭之后释放，但原生此时可能已经不认它们了
    // （实测抛 `MediaStreamDisposeFailed: stream not found`）；逐个兜住异常，
    // 免得出房间/注销时半路中断，后面的停止采集、释放电平计都不再执行。
    await _safeDispose(
      slot.peerId,
      '音频渲染器',
      () => slot.audioRenderer?.dispose(),
    );
    await _safeDispose(
      slot.peerId,
      '屏幕渲染器',
      () => slot.screenRenderer?.dispose(),
    );
    await _safeDispose(
      slot.peerId,
      '远端音频流',
      () => slot.remoteAudioStream?.dispose(),
    );
    await _safeDispose(
      slot.peerId,
      '远端屏幕流',
      () => slot.remoteScreenStream?.dispose(),
    );
  }

  /// 释放一个可选的原生对象，失败只记一条日志（清理路径不该往外抛）。
  Future<void> _safeDispose(
    String peerId,
    String what,
    Future<void>? Function() action,
  ) async {
    try {
      await action();
    } on Object catch (error) {
      AppLog.debug('释放 $what 失败 peer=$peerId：$error');
    }
  }

  // ------------------------------------------------------------------ 远端媒体
  Future<void> _handleRemoteTrack(_PeerSlot slot, RTCTrackEvent event) async {
    final track = event.track;
    final stream = event.streams.isNotEmpty ? event.streams.first : null;

    if (track.kind == 'audio') {
      AppLog.info('收到远端音频轨 peer=${slot.peerId}，初始化播放渲染器…');
      final renderer = slot.audioRenderer ??= RTCVideoRenderer();
      // 渲染器只初始化一次，而且失败也要继续往下走：这条路径是 `unawaited`
      // 进来的，异常冒出去就只剩一条「异步未捕获异常」，`srcObject` 绑定与音量
      // 接管全都不再执行——表现就是「对端在说、本机一点声音都没有」。
      if (!slot.audioRendererReady) {
        try {
          await renderer.initialize();
          slot.audioRendererReady = true;
          AppLog.info('远端音频渲染器已就绪 peer=${slot.peerId}');
        } on Object catch (error) {
          AppLog.warn('远端音频渲染器初始化失败 peer=${slot.peerId}', error: error);
        }
      }
      final audioStream =
          stream ?? await createLocalMediaStream('remote-audio-${slot.peerId}');
      if (stream == null) {
        await audioStream.addTrack(track);
      }
      slot.remoteAudioStream = audioStream;
      slot.remoteAudioTrack = track;
      // 把远端音频挂到 renderer 上即开始播放；音量/静音交给状态机接管
      // （点击可能早于音轨到达，attach 会按已保存的值重放一次）
      try {
        renderer.srcObject = audioStream;
      } on Object catch (error) {
        AppLog.warn('绑定远端音频渲染器失败 peer=${slot.peerId}', error: error);
      }
      await _attachPeerAudio(slot);
      AppLog.info(
        '收到远端音频 peer=${slot.peerId} '
        '轨道enabled=${track.enabled} 静音=${track.muted}',
      );
      unawaited(_reportRemoteAudio(slot, track));
      return;
    }

    if (track.kind == 'video') {
      // 本应用只有屏幕共享会产生远端视频轨，不存在摄像头视频
      final renderer = slot.screenRenderer ??= RTCVideoRenderer();
      try {
        await renderer.initialize();
      } on Object catch (error) {
        // 这条路径是 unawaited 进来的，异常抛出去就彻底没了：界面上只剩黑屏、
        // 日志里什么都没有。至少留一条，能分清是渲染器起不来还是压根没帧。
        AppLog.warn('屏幕渲染器初始化失败 peer=${slot.peerId}', error: error);
        return;
      }
      final screenStream =
          stream ??
          await createLocalMediaStream('remote-screen-${slot.peerId}');
      if (stream == null) {
        await screenStream.addTrack(track);
      }
      slot.remoteScreenStream = screenStream;
      // 发送方是「先占位、真要共享时才 replaceTrack」的，握手那一刻这条轨道还
      // 没有任何画面（muted）。安卓原生要等轨道真出帧才把渲染器接上，接早了就
      // 一直黑屏；所以等出货（unmute）时把 srcObject 重挂一次。
      track.onUnMute = () => unawaited(_reattachScreen(slot, screenStream));
      renderer.srcObject = screenStream;
      AppLog.info(
        '收到远端屏幕流 peer=${slot.peerId} track=${track.id} 静音=${track.muted}',
      );
      unawaited(_reportScreenFrames(slot, renderer));
    }
  }

  /// 挂上远端音轨之后回报一次「到底有没有真的出声」。
  ///
  /// 和 [_reportScreenFrames] 同一个用途：出现「对端电平在动、本机却没有声音」时，
  /// 这条日志能把问题一分为二——`samples=0` 说明压根没解码（传输/协商那一层），
  /// `samples>0` 而本机仍听不到，就只剩「被静音」这一种可能：成员音量 0、本地
  /// 静音开关，或者播放设备根本不是在用的那一只。
  Future<void> _reportRemoteAudio(_PeerSlot slot, MediaStreamTrack track) async {
    await Future<void>.delayed(const Duration(seconds: 4));
    if (slot.closed) {
      return;
    }
    var inbound = '无 inbound-rtp';
    try {
      for (final report in await slot.pc.getStats()) {
        if (report.type != 'inbound-rtp') {
          continue;
        }
        final values = report.values;
        final kind = values['kind'] ?? values['mediaType'];
        if (kind != null && kind != 'audio') {
          continue;
        }
        final bytes = values['bytesReceived'];
        final samples = values['totalSamplesReceived'];
        final level = values['audioLevel'];
        // 顺手把「延迟花在哪」也带出来：抖动缓冲的时长、丢包、补出来的音频占比
        inbound =
            'bytes=$bytes samples=$samples level=$level '
            '${describeInboundAudioLatency(values)}';
        break;
      }
    } on Object catch (error) {
      inbound = '读取失败：$error';
    }
    AppLog.info(
      '远端音频播放自检 peer=${slot.peerId} '
      '音轨enabled=${track.enabled} 静音=${track.muted} '
      '增益=${peerAudio.gainOf(slot.peerId).toStringAsFixed(2)} '
      '本地静音=${peerAudio.isSilenced(slot.peerId)} '
      '渲染器已绑=${slot.remoteAudioStream != null} $inbound',
    );
  }

  /// 轨道由静音转成有画面时，把渲染器重挂一遍。
  ///
  /// 为什么需要：`replaceTrack` 不触发重新协商，接收侧拿到的轨道在握手时就是静音的，
  /// 这时安卓原生不会给渲染器接 sink（Windows 上没这个问题）——表现就是手机端
  /// 一直黑屏。重挂一次等于让原生按「现在有帧了」重新绑定一遍。
  Future<void> _reattachScreen(_PeerSlot slot, MediaStream stream) async {
    final renderer = slot.screenRenderer;
    if (slot.closed || renderer == null) {
      return;
    }
    AppLog.info('屏幕轨道开始出画面，重挂渲染器 peer=${slot.peerId}');
    try {
      renderer.srcObject = null;
      renderer.srcObject = stream;
    } on Object catch (error) {
      AppLog.warn('重挂屏幕渲染器失败 peer=${slot.peerId}', error: error);
    }
  }

  /// 挂上渲染器之后回报一次「到底有没有解出画面」。
  ///
  /// 手机端收到黑屏时，这条日志能把问题一分为二：`解码帧=0` 是传输/解码这一层
  /// （对端的编码档位、本端解码器支持与否），有帧但 `尺寸=0x0` 才是渲染这一层。
  Future<void> _reportScreenFrames(
    _PeerSlot slot,
    RTCVideoRenderer renderer,
  ) async {
    await Future<void>.delayed(const Duration(seconds: 4));
    if (slot.closed) {
      return;
    }
    var size = '未知';
    try {
      size = '${renderer.videoWidth}x${renderer.videoHeight}';
    } on Object {
      // 渲染器可能已经随连接一起释放了；这里只是打日志，不值得中断
    }
    var frames = '未知';
    var codec = '未知';
    try {
      final reports = await slot.pc.getStats();
      for (final report in reports) {
        if (report.type != 'inbound-rtp') {
          continue;
        }
        final kind = report.values['kind'] ?? report.values['mediaType'];
        if (kind != 'video') {
          continue;
        }
        frames = '${report.values['framesDecoded'] ?? '未知'}';
        codec =
            '${report.values['mimeType'] ?? report.values['codecId'] ?? '未知'}';
      }
    } on Object catch (error) {
      AppLog.debug('读取屏幕入流统计失败 peer=${slot.peerId}：$error');
    }
    AppLog.info(
      '屏幕画面 peer=${slot.peerId} 解码帧=$frames 编码=$codec 尺寸=$size',
    );
    if (frames == '0' || frames == '未知') {
      AppLog.warn(
        '屏幕画面还没解出任何帧 peer=${slot.peerId}：对端编码档位或本端解码器可能不匹配',
      );
    }
  }

  /// 本地屏蔽 / 恢复某个成员的声音。
  ///
  /// 只影响本机播放，不通知对方，也不改变任何服务端状态——即「我不想听他说话」。
  Future<void> setPeerAudioMuted(String peerId, bool muted) =>
      peerAudio.setMuted(peerId, muted);

  /// 设置某个成员的音量（0~2，100% = 1.0）。
  ///
  /// 实际动作在 [PeerAudioMixer] 里：0 走确定性静音，>0 恢复播放并下发原生增益。
  Future<void> setPeerAudioVolume(String peerId, double gain) =>
      peerAudio.setGain(peerId, gain);

  /// 把某成员的远端音频接到本机播放状态机上（音轨到达时调用）。
  Future<void> _attachPeerAudio(_PeerSlot slot) =>
      peerAudio.attach(slot.peerId, _EnginePeerAudioDevice(slot));

  /// 远端音频播放器（无需渲染到界面，挂上即出声）。
  RTCVideoRenderer? remoteAudioRenderer(String peerId) =>
      _peers[peerId]?.audioRenderer;

  /// 远端屏幕渲染器：有共享时 UI 才需要它。
  RTCVideoRenderer? remoteScreenRenderer(String peerId) =>
      _peers[peerId]?.screenRenderer;

  bool hasRemoteScreen(String peerId) =>
      _peers[peerId]?.remoteScreenStream != null;

  // ------------------------------------------------------------------ 统计
  Future<PeerStatsSnapshot?> statsFor(String peerId) async {
    final slot = _peers[peerId];
    if (slot == null || slot.closed) {
      return null;
    }
    try {
      final reports = await slot.pc.getStats();
      return _summarize(reports);
    } on Object catch (error) {
      AppLog.warn('读取连接统计失败 peer=$peerId', error: error);
      return null;
    }
  }

  PeerStatsSnapshot _summarize(List<StatsReport> reports) {
    int? bytesSent;
    int? bytesReceived;
    int? packetsLost;
    double? roundTripTimeMs;
    double? avgQp;
    String? qualityLimitationReason;
    String? localCandidateId;
    String? remoteCandidateId;

    for (final report in reports) {
      final values = report.values;
      switch (report.type) {
        case 'outbound-rtp':
          final sent = values['bytesSent'];
          if (sent is num) {
            bytesSent = (bytesSent ?? 0) + sent.toInt();
          }
          final kind = values['kind'] ?? values['mediaType'];
          if (kind == 'video') {
            // qpSum / framesEncoded = 平均量化步长：均衡档靠它判断画面复杂度
            final qpSum = values['qpSum'];
            final frames = values['framesEncoded'];
            if (qpSum is num && frames is num && frames > 0) {
              avgQp = qpSum / frames;
            }
            final reason = values['qualityLimitationReason'];
            if (reason is String) {
              qualityLimitationReason = reason;
            }
          }
        case 'inbound-rtp':
          final received = values['bytesReceived'];
          if (received is num) {
            bytesReceived = (bytesReceived ?? 0) + received.toInt();
          }
          final lost = values['packetsLost'];
          if (lost is num) {
            packetsLost = (packetsLost ?? 0) + lost.toInt();
          }
        case 'candidate-pair':
          if (values['state'] == 'succeeded') {
            localCandidateId = values['localCandidateId'] as String?;
            remoteCandidateId = values['remoteCandidateId'] as String?;
            final rtt = values['currentRoundTripTime'];
            if (rtt is num) {
              roundTripTimeMs = rtt * 1000;
            }
          }
      }
    }

    String? candidateType(String? id) {
      if (id == null) {
        return null;
      }
      for (final report in reports) {
        if (report.id == id) {
          return report.values['candidateType'] as String?;
        }
      }
      return null;
    }

    return PeerStatsSnapshot(
      bytesSent: bytesSent,
      bytesReceived: bytesReceived,
      localCandidateType: candidateType(localCandidateId),
      remoteCandidateType: candidateType(remoteCandidateId),
      roundTripTimeMs: roundTripTimeMs,
      packetsLost: packetsLost,
      avgQp: avgQp,
      qualityLimitationReason: qualityLimitationReason,
    );
  }

  // ------------------------------------------------------------------ 工具
  Future<void> _applyAudioTrackToAllPeers() async {
    for (final slot in _peers.values) {
      await _replaceAudioTrack(slot, _localAudioTrack);
    }
  }

  Future<void> _applyScreenTrackToAllPeers() async {
    for (final slot in _peers.values) {
      await _replaceScreenTrack(slot, _screenTrack);
    }
    // 声音跟着画面一起挂：投屏带应用/系统音频时，这一路是独立的 m 行
    await _applyScreenAudioToAllPeers();
  }

  /// 给这条连接的音频发送通道声明码率上限与网络优先级（见 `voiceSendParameters`）。
  ///
  /// 失败只记 debug：音频的实际码率主要靠 SDP 里的 `maxaveragebitrate` 生效，
  /// 这里补的是「优先级」。部分 libwebrtc 版本对音频 sender 的 `setParameters`
  /// 会直接返回 false——那是预期内的，不该因此往日志里刷警告。
  Future<void> _applyAudioSendParameters(_PeerSlot slot) async {
    final sender = slot.audioSender;
    if (sender == null || slot.closed) {
      return;
    }
    try {
      final accepted = await sender.setParameters(
        voiceSendParameters(_voiceProfile),
      );
      if (!accepted) {
        AppLog.debug(
          '音频发送参数未被原生接受 peer=${slot.peerId}（按 SDP 里的码率走）',
        );
      }
    } on Object catch (error) {
      AppLog.debug('设置音频发送参数失败 peer=${slot.peerId}：$error');
    }
  }

  Future<void> _replaceAudioTrack(
    _PeerSlot slot,
    MediaStreamTrack? track,
  ) async {
    if (slot.closed) {
      return;
    }
    final sender = slot.audioSender ?? await _senderForKind(slot, 'audio');
    if (sender == null) {
      await _addSendChannel(slot, track, stream: _localAudio);
      return;
    }
    slot.audioSender = sender;
    await _safeReplace(slot, sender, track);
    if (track != null) {
      await _applyAudioSendParameters(slot);
    }
  }

  Future<void> _replaceScreenTrack(
    _PeerSlot slot,
    MediaStreamTrack? track,
  ) async {
    if (slot.closed) {
      return;
    }
    final sender = slot.screenSender ?? await _senderForKind(slot, 'video');
    if (sender == null) {
      await _addSendChannel(slot, track, stream: _screen);
      return;
    }
    slot.screenSender = sender;
    await _safeReplace(slot, sender, track);
    if (track != null) {
      await _applyScreenSendParameters(slot);
    }
  }

  /// 按分配器算好的目标，给这一路声明编码参数。
  ///
  /// 每次（重新）挂上屏幕轨道都要设一遍，`setParameters` 是贴着这条 sender 的；
  /// 观众进出后也要对全部 sender 重设一遍——每个人的额度都是别人让出来的。
  /// 失败只记日志：最多退回默认的 `balanced`，不影响能不能共享。
  Future<void> _applyScreenSendParameters(_PeerSlot slot) async {
    final sender = slot.screenSender;
    if (sender == null) {
      return;
    }
    if (_screenPlan.isEmpty && _screen != null) {
      // 正常路径上 startScreenShare 已经算过；这里兜住「轨道先到、观众后到」的窗口期
      _recomputeScreenPlan();
    }
    final target = _screenPlan[slot.peerId];
    if (target == null) {
      return;
    }
    try {
      final accepted = await sender.setParameters(
        screenSendParameters(target: target),
      );
      if (!accepted) {
        AppLog.warn('屏幕共享编码参数未被原生接受 peer=${slot.peerId}');
      }
    } on Object catch (error) {
      AppLog.warn('设置屏幕共享编码参数失败 peer=${slot.peerId}', error: error);
    }
  }

  /// 把当前分配结果落到每一条已经挂着屏幕轨道的连接上。
  ///
  /// 观众增减后必须整组重设：只改新增/剩下的那一条的话，老连接会继续按旧额度发，
  /// 合计就超预算了。
  Future<void> _applyScreenPlanToAllPeers() async {
    if (_screenTrack == null) {
      return;
    }
    for (final slot in _peers.values) {
      if (slot.closed) {
        continue;
      }
      await _applyScreenSendParameters(slot);
    }
  }

  /// 还没有发送通道时，用 `addTrack` 现建一个。
  ///
  /// 为什么不用 `addTransceiver` 预置：**实测 flutter_webrtc 1.6.2 在 Windows 上，
  /// 预置出来的 transceiver 不会被对端 offer 复用** —— 被叫侧 `setRemoteDescription`
  /// 时原生会另建一对「只收」的 transceiver（transceiver 数量 2 → 4），于是 answer
  /// 里音频、视频两个 m 行全是 `recvonly`。表现就是：**新进房的人能听到、能看到先入房
  /// 的人，先入房的人却收不到任何媒体**（音频、屏幕共享都发不出去）。
  /// `addTrack` 走标准路径，实测 answer 为 `sendrecv`。
  ///
  /// 传入 `track == null`（麦克风没开、没在共享）时什么都不建：被叫侧没有可回填的
  /// m 行，建了也是白建（还留着就会被后续协商带成多余的 m 行）。等轨道真的出现，
  /// 再补一次重协商即可。
  Future<void> _addSendChannel(
    _PeerSlot slot,
    MediaStreamTrack? track, {
    required MediaStream? stream,
  }) async {
    if (track == null) {
      return;
    }
    final kind = track.kind;
    try {
      final target =
          stream ??
          await createLocalMediaStream('omioclink-${slot.peerId}-$kind');
      AppLog.info('挂发送轨道 kind=$kind peer=${slot.peerId}');
      final sender = await slot.pc.addTrack(track, target);
      if (kind == 'audio') {
        slot.audioSender = sender;
        await _applyAudioSendParameters(slot);
      } else {
        slot.screenSender = sender;
        await _applyScreenSendParameters(slot);
      }
      AppLog.info('为成员 ${slot.peerId} 新建发送通道 kind=$kind');
      await _maybeRenegotiate(slot);
    } on Object catch (error) {
      AppLog.warn('新建发送通道失败 peer=${slot.peerId} kind=$kind', error: error);
    }
  }

  /// 新建发送通道之后：需要时补一轮协商。
  ///
  /// 三种情况：
  /// * 首轮还没谈完（`remoteDescriptionSet` 为假）——不用管，那轮的 offer/answer
  ///   本来就会带上这个通道；
  /// * 自己的 offer 在路上——记下来，等收到 answer 再谈（见 [handleRemoteAnswer]）；
  /// * 连接已经稳定——立刻由我们这边发一个 offer 把新 m 行谈出去。
  ///
  /// 「由被叫方发 offer」不会和主叫方撞车：主叫方的发送通道在建连时就预置好了，
  /// 永远不需要补谈。
  Future<void> _maybeRenegotiate(_PeerSlot slot) async {
    if (slot.closed || !slot.remoteDescriptionSet) {
      return;
    }
    if (slot.offerInFlight) {
      slot.needsRenegotiation = true;
      return;
    }
    slot.needsRenegotiation = false;
    await negotiate(slot.peerId);
  }

  /// 把屏幕流里的回环音频（系统 / 选中的应用声音）挂到每个成员上。
  ///
  /// 只挂「还没挂过」的：投屏过程中有人进房时也会走这里补齐。声音和画面是两条
  /// 独立 m 行——麦克风那条 `audioSender` 不能被顶掉，对端才听得见人说话。
  Future<void> _applyScreenAudioToAllPeers() async {
    final track = _screenAudioTrack;
    final screen = _screen;
    if (track == null || screen == null) {
      return;
    }
    for (final slot in _peers.values.toList(growable: false)) {
      if (slot.closed || slot.screenAudioSender != null) {
        continue;
      }
      try {
        final sender = await slot.pc.addTrack(track, screen);
        slot.screenAudioSender = sender;
        AppLog.info('为成员 ${slot.peerId} 挂上屏幕声音（应用 / 系统音频）');
        await _maybeRenegotiate(slot);
      } on Object catch (error) {
        AppLog.warn('挂屏幕声音失败 peer=${slot.peerId}', error: error);
      }
    }
  }

  /// 停止共享时把屏幕声音收掉。
  ///
  /// 用 `replaceTrack(null)` 而不是 `removeTrack`：不需要重新协商，对端那条 m 行
  /// 直接变静音，下一次共享还能复用同一个 sender。
  Future<void> _dropScreenAudioFromAllPeers() async {
    for (final slot in _peers.values.toList(growable: false)) {
      final sender = slot.screenAudioSender;
      if (sender == null) {
        continue;
      }
      slot.screenAudioSender = null;
      await _safeReplace(slot, sender, null);
    }
  }

  Future<RTCRtpSender?> _senderForKind(_PeerSlot slot, String kind) async {
    try {
      final senders = await slot.pc.getSenders();
      for (final sender in senders) {
        if (sender.track?.kind == kind) {
          return sender;
        }
      }
    } on Object catch (error) {
      AppLog.warn('查找 sender 失败 peer=${slot.peerId} kind=$kind', error: error);
    }
    return null;
  }

  Future<void> _safeReplace(
    _PeerSlot slot,
    RTCRtpSender? sender,
    MediaStreamTrack? track,
  ) async {
    if (sender == null) {
      return;
    }
    try {
      await sender.replaceTrack(track);
    } on Object catch (error) {
      AppLog.warn('替换轨道失败 peer=${slot.peerId}', error: error);
    }
  }

  void _emitCandidate(String peerId, IceCandidatePayload? candidate) {
    callbacks?.onLocalCandidate(peerId, candidate);
  }

  static PeerLinkState _mapConnectionState(
    RTCPeerConnectionState state,
  ) => switch (state) {
    RTCPeerConnectionState.RTCPeerConnectionStateConnected =>
      PeerLinkState.connected,
    RTCPeerConnectionState.RTCPeerConnectionStateConnecting =>
      PeerLinkState.connecting,
    RTCPeerConnectionState.RTCPeerConnectionStateNew => PeerLinkState.idle,
    RTCPeerConnectionState.RTCPeerConnectionStateDisconnected =>
      PeerLinkState.disconnected,
    RTCPeerConnectionState.RTCPeerConnectionStateFailed => PeerLinkState.failed,
    RTCPeerConnectionState.RTCPeerConnectionStateClosed => PeerLinkState.closed,
  };

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    callbacks = null;
    await closeAllPeers();
    await stopScreenShare();
    await stopLocalAudio();
    _micMeter.dispose();
  }
}

/// 把 `_PeerSlot`（远端音轨 + 渲染器 + 原生增益）适配成 [PeerAudioDevice]。
///
/// 每一次原生增益调用都会打一条日志（`成员音量 peer=… 增益=… 结果=…`），
/// 便于事后核对「到底有没有真的调下去、平台报了什么错」。
class _EnginePeerAudioDevice implements PeerAudioDevice {
  _EnginePeerAudioDevice(this.slot);

  final _PeerSlot slot;

  @override
  Future<void> setTrackEnabled(bool enabled) async {
    final track = slot.remoteAudioTrack;
    if (track == null) {
      return;
    }
    try {
      track.enabled = enabled;
    } on Object catch (error) {
      AppLog.warn('切换远端音轨失败 peer=${slot.peerId}', error: error);
    }
  }

  @override
  Future<void> setRendererBound(bool bound) async {
    final renderer = slot.audioRenderer;
    if (renderer == null) {
      return;
    }
    try {
      renderer.srcObject = bound ? slot.remoteAudioStream : null;
    } on Object catch (error) {
      AppLog.warn('切换远端音频渲染器失败 peer=${slot.peerId}', error: error);
    }
  }

  @override
  Future<PeerGainAck> setGain(double gain) async {
    final track = slot.remoteAudioTrack;
    if (track == null) {
      return const PeerGainAck.failed('远端音频轨尚未到达');
    }
    try {
      // 走 flutter_webrtc 的方法通道 setVolume → RTCAudioTrack::SetVolume（每条轨独立）
      await Helper.setVolume(gain, track);
      AppLog.info(
        '成员音量 peer=${slot.peerId} 增益=${gain.toStringAsFixed(2)} 结果=ok',
      );
      return const PeerGainAck.ok();
    } on Object catch (error) {
      final code = error is PlatformException
          ? '${error.code}${error.message == null ? '' : ' ${error.message}'}'
          : '$error';
      AppLog.warn(
        '成员音量 peer=${slot.peerId} '
        '增益=${gain.toStringAsFixed(2)} 结果=失败（$code）',
      );
      return PeerGainAck.failed(code);
    }
  }
}
