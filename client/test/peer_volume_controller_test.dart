import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/data/music_models.dart';
import 'package:omioclink_client/data/music_store.dart';
import 'package:omioclink_client/data/volume_store.dart';
import 'package:omioclink_client/media/peer_audio_mixer.dart';
import 'package:omioclink_client/music/music_player.dart';
import 'package:omioclink_client/room/peer_volume_controller.dart';
import 'package:omioclink_client/room/room_music.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 记录调用的假端口（不碰 WebRTC）。
class RecordingPeerAudioSink implements PeerAudioSink {
  final List<({String peerId, double gain})> gains =
      <({String peerId, double gain})>[];
  final List<({String peerId, bool muted})> mutes =
      <({String peerId, bool muted})>[];

  @override
  Future<void> setPeerGain(String peerId, double gain) async =>
      gains.add((peerId: peerId, gain: gain));

  @override
  Future<void> setPeerMuted(String peerId, bool muted) async =>
      mutes.add((peerId: peerId, muted: muted));
}

/// 把端口接到真实音量状态机上（`production` 里就是 `MediaEngine` 干的活）。
class MixerPeerAudioSink implements PeerAudioSink {
  MixerPeerAudioSink(this.mixer);

  final PeerAudioMixer mixer;

  @override
  Future<void> setPeerGain(String peerId, double gain) =>
      mixer.setGain(peerId, gain);

  @override
  Future<void> setPeerMuted(String peerId, bool muted) =>
      mixer.setMuted(peerId, muted);
}

/// 假远端音频设备：记下音轨开关、渲染器绑定与原生增益。
class FakeDevice implements PeerAudioDevice {
  bool? trackEnabled;
  bool? rendererBound;
  final List<double> gains = <double>[];

  @override
  Future<void> setTrackEnabled(bool enabled) async => trackEnabled = enabled;

  @override
  Future<void> setRendererBound(bool bound) async => rendererBound = bound;

  @override
  Future<PeerGainAck> setGain(double gain) async {
    gains.add(gain);
    return const PeerGainAck.ok();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('按 userId 记住音量', () {
    test('未设置过的成员返回默认 100%', () async {
      final controller = PeerVolumeController(
        sink: RecordingPeerAudioSink(),
        store: VolumeStore(),
      );
      await controller.load();
      expect(controller.volumeOf(42), 1.0);
      expect(controller.percentOf(42), 100.0);
    });

    test('写入后新建 store/controller 读到同一个值', () async {
      final first = PeerVolumeController(
        sink: RecordingPeerAudioSink(),
        store: VolumeStore(),
      );
      await first.load();
      await first.setVolume(peerId: 'peer-a', userId: 7, volume: 1.6);
      // 落盘是 unawaited 的，等一个事件循环再读
      await Future<void>.delayed(Duration.zero);

      // 模拟重启：全新的 store + controller
      final second = PeerVolumeController(
        sink: RecordingPeerAudioSink(),
        store: VolumeStore(),
      );
      await second.load();
      expect(second.volumeOf(7), closeTo(1.6, 1e-9));
    });

    test('两个成员各自独立，互不覆盖', () async {
      final sink = RecordingPeerAudioSink();
      final controller = PeerVolumeController(
        sink: sink,
        store: VolumeStore(),
      );
      await controller.load();

      await controller.setVolume(peerId: 'peer-a', userId: 1, volume: 0.2);
      await controller.setVolume(peerId: 'peer-b', userId: 2, volume: 1.6);
      // 落盘是 unawaited 的，等一个事件循环再读
      await Future<void>.delayed(Duration.zero);

      expect(controller.volumeOf(1), closeTo(0.2, 1e-9));
      expect(controller.volumeOf(2), closeTo(1.6, 1e-9));
      expect(sink.gains, <({String peerId, double gain})>[
        (peerId: 'peer-a', gain: 0.2),
        (peerId: 'peer-b', gain: 1.6),
      ]);

      final stored = await VolumeStore().loadPeerVolumes();
      expect(stored, <String, double>{'1': 0.2, '2': 1.6});
    });

    test('越界输入被钳制到 [0, 2]', () async {
      final sink = RecordingPeerAudioSink();
      final controller = PeerVolumeController(
        sink: sink,
        store: VolumeStore(),
      );
      await controller.load();

      await controller.setPercent(peerId: 'p1', userId: 1, percent: 320);
      expect(controller.volumeOf(1), 2.0);
      await controller.setPercent(peerId: 'p1', userId: 1, percent: -40);
      expect(controller.volumeOf(1), 0.0);
      await controller.setPercent(peerId: 'p1', userId: 1, percent: 150);
      expect(controller.volumeOf(1), 1.5);

      expect(sink.gains.map((e) => e.gain), <double>[2.0, 0.0, 1.5]);
    });

    test('bindPeer 在音轨到来前把已保存音量交给端口', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'omioclink.volume.peers': '{"9":1.6}',
      });
      final sink = RecordingPeerAudioSink();
      final controller = PeerVolumeController(
        sink: sink,
        store: VolumeStore(),
      );
      await controller.load();
      await controller.bindPeer(peerId: 'peer-9', userId: 9);
      expect(sink.gains.single.gain, closeTo(1.6, 1e-9));
    });

    test('存储内容坏掉不崩溃，回落默认', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'omioclink.volume.peers': '{不是 JSON',
      });
      final controller = PeerVolumeController(
        sink: RecordingPeerAudioSink(),
        store: VolumeStore(),
      );
      await controller.load();
      expect(controller.volumeOf(1), 1.0);
    });
  });

  group('与音乐音量完全独立', () {
    test('音乐调到 0 不影响任何成员；成员调到 0 也不影响音乐', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final mixer = PeerAudioMixer();
      final alice = FakeDevice();
      final bob = FakeDevice();
      await mixer.attach('peer-alice', alice);
      await mixer.attach('peer-bob', bob);
      // attach 会先下发一次默认 100%，本用例只关心之后的按成员调节
      alice.gains.clear();
      bob.gains.clear();

      final controller = PeerVolumeController(
        sink: MixerPeerAudioSink(mixer),
        store: VolumeStore(),
      );
      await controller.load();
      await controller.setVolume(peerId: 'peer-alice', userId: 1, volume: 0.2);
      await controller.setVolume(peerId: 'peer-bob', userId: 2, volume: 1.6);

      final music = MusicPlayer(
        queue: RoomMusicQueue(),
        resolve: (MusicTrack track) async =>
            throw StateError('本用例不该真的去解析播放地址'),
        store: MusicStore(),
      );

      // 音乐音量 → 0：成员那边一点都不能变
      await music.setVolume(0);
      expect(music.volume, 0.0);
      expect(controller.volumeOf(1), closeTo(0.2, 1e-9));
      expect(controller.volumeOf(2), closeTo(1.6, 1e-9));
      expect(mixer.gainOf('peer-alice'), closeTo(0.2, 1e-9));
      expect(mixer.gainOf('peer-bob'), closeTo(1.6, 1e-9));
      expect(mixer.isSilenced('peer-alice'), isFalse);
      expect(mixer.isSilenced('peer-bob'), isFalse);
      expect(alice.trackEnabled, isTrue);
      expect(bob.trackEnabled, isTrue);
      expect(alice.gains, <double>[0.2]);
      expect(bob.gains, <double>[1.6]);

      // 成员音量 → 0：只静音那个成员，音乐音量原样
      await controller.setVolume(peerId: 'peer-alice', userId: 1, volume: 0);
      expect(alice.trackEnabled, isFalse);
      expect(bob.trackEnabled, isTrue, reason: '别人的音量不受影响');
      expect(music.volume, 0.0);

      // 再把音乐调回去：成员静音状态依然保持
      await music.setVolume(55);
      expect(music.volume, 55.0);
      expect(alice.trackEnabled, isFalse);
      expect(controller.volumeOf(1), 0.0);
      expect(controller.volumeOf(2), closeTo(1.6, 1e-9));
    });
  });
}
