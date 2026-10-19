import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter/services.dart';

import '../core/app_log.dart';
import '../signaling/protocol.dart';
import 'media_models.dart';
import 'mic_capture.dart';
import 'mic_meter.dart';
import 'peer_audio_mixer.dart';
import 'screen_capture.dart';

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

  RTCVideoRenderer? audioRenderer;
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
      };
    } on Object catch (error) {
      AppLog.debug('订阅音频设备变更失败：$error');
    }
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

  /// 当前屏幕共享的画质档位（帧率与码率上限跟着它走）。
  ScreenShareQuality _screenQuality = ScreenShareQuality.fallback;

  /// 共享中把自己采到的画面挂上去，共享者本人也能看到「正在共享的是什么」。
  RTCVideoRenderer? _localScreenRenderer;

  String? _audioInputId;
  String? _audioOutputId;

  /// 这台机器此前是否真的枚举到过输入设备。
  ///
  /// 用来区分两种「空表」：**从没枚举到过**（多半真没有麦克风）与**曾经有、
  /// 这次却空了**（Windows 上采集过一次之后的老毛病，见 [startLocalAudio]）。
  bool _seenInputDevice = false;
  bool _microphoneMuted = false;
  bool _speakerEnabled = true;
  bool _disposed = false;

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
        reason: '未检测到麦克风设备',
        message: '这台电脑没有可用的麦克风，无法采集声音',
        code: 'microphone_missing',
      );
    }
    final target = choice.deviceId;

    MediaStream stream;
    try {
      AppLog.info('开始采集麦克风（${target.isEmpty ? '系统默认设备' : target}）');
      stream = await navigator.mediaDevices.getUserMedia(
        microphoneConstraints(deviceId: target),
      );
    } on Object catch (error) {
      AppLog.error('麦克风采集失败', error: error);
      _failCapture(
        reason: '无法使用麦克风（无设备或无权限）',
        message: '无法使用麦克风，请检查系统权限与设备占用',
        code: 'microphone_denied',
      );
    }
    // 双保险：拿到的流必须真有一条音轨。设备可能在枚举之后被拔掉，原生也可能
    // 只回了一份空壳（这时 `_localAudioTrack` 为 null，电平永远读不到、发出去的
    // 声音也是空的）。收下手之前先验一遍，别让空壳流混进后续建连。
    if (stream.getAudioTracks().isEmpty) {
      await _disposeStream(stream);
      _failCapture(
        reason: '麦克风没有可用的采集设备',
        message: '没能从麦克风读到声音，请检查设备是否可用',
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
  /// 走原生 `selectAudioOutput` 改音频设备模块的播放设备——这是桌面端唯一
  /// 生效的方式（`getUserMedia` 的约束只作用于采集）。空串表示不指定，
  /// 交给系统默认设备，不做切换。
  Future<void> switchAudioOutput(String deviceId) async {
    if (deviceId == _audioOutputId) {
      return;
    }
    _audioOutputId = deviceId;
    if (deviceId.isEmpty || kIsWeb) {
      return;
    }
    try {
      await Helper.selectAudioOutput(deviceId);
    } on Object catch (error) {
      AppLog.warn('切换输出设备失败', error: error);
      throw const MediaException(
        '无法切换到所选扬声器，请确认设备仍然可用',
        code: 'audio_output_switch_failed',
      );
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
      final mapped = sources
          .map(
            (source) => ScreenSource(
              id: source.id,
              name: source.name,
              isWindow: source.type == SourceType.Window,
              thumbnail: source.thumbnail,
            ),
          )
          .toList(growable: false);
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
      throw const MediaException(
        '无法枚举屏幕与窗口',
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
  /// 帧率与码率上限取 [quality]；分辨率等于源的分辨率，上行带宽吃紧时保分辨率
  /// 不保帧率（见 [screenSendParameters]，另附「为什么不能压到 1080p」的实测说明）。
  Future<void> startScreenShare({
    String? sourceId,
    bool withSystemAudio = false,
    ScreenShareQuality quality = ScreenShareQuality.fallback,
  }) async {
    if (_screen != null) {
      return;
    }
    _screenQuality = quality;
    var target = sourceId;
    if (target == null || target.isEmpty) {
      final sources = await listScreenSources();
      if (sources.isEmpty) {
        throw const MediaException('没有可共享的屏幕或窗口', code: 'no_screen_source');
      }
      target = sources.first.id;
    }

    final constraints = screenShareConstraints(
      sourceId: target,
      withSystemAudio: withSystemAudio,
      maxHeight: ScreenShareQuality.maxHeight,
      maxFps: quality.maxFps,
    );

    try {
      _screen = await navigator.mediaDevices.getDisplayMedia(constraints);
    } on Object catch (error) {
      AppLog.error('屏幕采集失败', error: error);
      throw const MediaException(
        '无法开始屏幕共享，请检查系统权限',
        code: 'screen_capture_denied',
      );
    }
    await _attachLocalScreenPreview();
    await _applyScreenTrackToAllPeers();
  }

  Future<void> stopScreenShare() async {
    final stream = _screen;
    _screen = null;
    await _disposeLocalScreenPreview();
    if (stream == null) {
      return;
    }
    await _disposeStream(stream);
    for (final slot in _peers.values) {
      await _replaceScreenTrack(slot, null);
    }
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
    };

    AppLog.info('创建 PeerConnection peer=$peerId（原生未初始化时此处会初始化 WebRTC 工厂）');
    final pc = await createPeerConnection(configuration);
    AppLog.info('PeerConnection 已创建 peer=$peerId');
    final slot = _PeerSlot(peerId: peerId, pc: pc, polite: polite);
    _peers[peerId] = slot;

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

  /// 向某成员发起协商（发出 offer）。
  ///
  /// 由 `RoomSession` 显式调用：按「新成员向房间内所有既有成员发起 offer」的确定性规则，
  /// 保证同一对连接同时只有一方在 offer，从结构上避免 glare。
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
      await slot.pc.setLocalDescription(offer);
      AppLog.info('本地描述已生效（offer）peer=$peerId');
      slot.needsRenegotiation = false;
      slot.offerInFlight = true;
      if (offer.sdp != null) {
        await callbacks?.onLocalDescription(peerId, 'offer', offer.sdp!);
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
      await slot.pc.setLocalDescription(answer);
      AppLog.info('本地描述已生效（answer）peer=$peerId（${answer.sdp?.length ?? 0} 字节）');
      if (answer.sdp != null) {
        await callbacks?.onLocalDescription(peerId, 'answer', answer.sdp!);
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
      slot.audioRenderer ??= RTCVideoRenderer();
      await slot.audioRenderer!.initialize();
      AppLog.info('远端音频渲染器已就绪 peer=${slot.peerId}');
      final audioStream =
          stream ?? await createLocalMediaStream('remote-audio-${slot.peerId}');
      if (stream == null) {
        await audioStream.addTrack(track);
      }
      slot.remoteAudioStream = audioStream;
      slot.remoteAudioTrack = track;
      // 把远端音频挂到 renderer 上即开始播放；音量/静音交给状态机接管
      // （点击可能早于音轨到达，attach 会按已保存的值重放一次）
      slot.audioRenderer!.srcObject = audioStream;
      await _attachPeerAudio(slot);
      AppLog.info('收到远端音频 peer=${slot.peerId}');
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

  /// 屏幕轨道挂上发送通道后，声明「保分辨率」的上行编码策略。
  ///
  /// 每次（重新）挂上屏幕轨道都要设一遍，`setParameters` 是贴着这条 sender 的。
  /// 失败只记日志：最多退回默认的 `balanced`，不影响能不能共享。
  Future<void> _applyScreenSendParameters(_PeerSlot slot) async {
    final sender = slot.screenSender;
    if (sender == null) {
      return;
    }
    try {
      final accepted = await sender.setParameters(
        screenSendParameters(quality: _screenQuality),
      );
      if (!accepted) {
        AppLog.warn('屏幕共享编码参数未被原生接受 peer=${slot.peerId}');
      }
    } on Object catch (error) {
      AppLog.warn('设置屏幕共享编码参数失败 peer=${slot.peerId}', error: error);
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
