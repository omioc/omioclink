import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/media/peer_audio_mixer.dart';

/// 记录调用的假音频设备：把「音轨开关 / 渲染器绑定 / 原生增益」全部记下来。
class FakePeerAudioDevice implements PeerAudioDevice {
  FakePeerAudioDevice(this.name);

  final String name;

  /// null = 还没下发过。
  bool? trackEnabled;
  bool? rendererBound;

  /// 每次成功下发的原生增益（按顺序）。
  final List<double> gains = <double>[];

  /// 让原生增益失败（模拟平台报错）。
  bool failGain = false;

  @override
  Future<void> setTrackEnabled(bool enabled) async {
    trackEnabled = enabled;
  }

  @override
  Future<void> setRendererBound(bool bound) async {
    rendererBound = bound;
  }

  @override
  Future<PeerGainAck> setGain(double gain) async {
    if (failGain) {
      return const PeerGainAck.failed('0x80004005 平台错误');
    }
    gains.add(gain);
    return const PeerGainAck.ok();
  }
}

void main() {
  group('按成员音量互不覆盖', () {
    test('两个成员分别设 0.2 与 1.6，各自生效且不互相覆盖', () async {
      final mixer = PeerAudioMixer();
      final alice = FakePeerAudioDevice('alice');
      final bob = FakePeerAudioDevice('bob');
      await mixer.attach('peer-alice', alice);
      await mixer.attach('peer-bob', bob);

      // attach 会先把默认 100% 下发一次；本用例只关心之后的按成员调节
      alice.gains.clear();
      bob.gains.clear();

      await mixer.setGain('peer-alice', 0.2);
      await mixer.setGain('peer-bob', 1.6);

      expect(mixer.gainOf('peer-alice'), closeTo(0.2, 1e-9));
      expect(mixer.gainOf('peer-bob'), closeTo(1.6, 1e-9));
      expect(alice.gains, <double>[0.2]);
      expect(bob.gains, <double>[1.6]);

      // 再调 alice 不会动到 bob
      await mixer.setGain('peer-alice', 0.8);
      expect(alice.gains, <double>[0.2, 0.8]);
      expect(bob.gains, <double>[1.6]);

      // 再调 bob 不会动到 alice
      await mixer.setGain('peer-bob', 0.4);
      expect(alice.gains, <double>[0.2, 0.8]);
      expect(bob.gains, <double>[1.6, 0.4]);
    });

    test('没设置过的成员按 100%（增益 1.0）', () {
      final mixer = PeerAudioMixer();
      expect(mixer.gainOf('whoever'), 1.0);
      expect(mixer.isSilenced('whoever'), isFalse);
    });
  });

  group('越界钳制', () {
    test('超出 [0, 2] 的输入被钳制，NaN/无穷回落默认', () async {
      final mixer = PeerAudioMixer();
      final device = FakePeerAudioDevice('a');
      await mixer.attach('p1', device);

      await mixer.setGain('p1', 5.5);
      expect(mixer.gainOf('p1'), 2.0);
      expect(device.gains.last, 2.0);

      await mixer.setGain('p1', -3);
      expect(mixer.gainOf('p1'), 0.0);
      expect(mixer.isSilenced('p1'), isTrue);

      await mixer.setGain('p1', double.nan);
      expect(mixer.gainOf('p1'), 1.0, reason: 'NaN 回落默认 100%');
      expect(mixer.isSilenced('p1'), isFalse);

      await mixer.setGain('p1', double.infinity);
      expect(mixer.gainOf('p1'), 1.0, reason: '无穷回落默认 100%');

      expect(PeerAudioMixer.clampGain(3), 2.0);
      expect(PeerAudioMixer.clampGain(-1), 0.0);
    });
  });

  group('迟到的音轨', () {
    test('音轨后到：attach 时按已保存的音量应用', () async {
      final mixer = PeerAudioMixer();
      // 成员列表比 P2P 连接先出现：先设音量（此时没有设备）
      await mixer.setGain('late', 1.6);
      expect(mixer.gainOf('late'), 1.6);

      final device = FakePeerAudioDevice('late');
      await mixer.attach('late', device);

      expect(device.gains, <double>[1.6], reason: '迟到音轨要按已保存的 160% 播放');
      expect(device.trackEnabled, isTrue);
      expect(device.rendererBound, isTrue);
    });

    test('音轨后到时若音量是 0，仍然走确定性静音', () async {
      final mixer = PeerAudioMixer();
      await mixer.setGain('late', 0);

      final device = FakePeerAudioDevice('late');
      await mixer.attach('late', device);

      expect(device.trackEnabled, isFalse);
      expect(device.rendererBound, isFalse);
      expect(device.gains, isEmpty, reason: '静音时不依赖音量数值，也不下发增益');
    });
  });

  group('音量 0 走确定性静音', () {
    test('音轨 enabled=false 且解绑渲染器；恢复 >0 后重新绑上并下发增益', () async {
      final mixer = PeerAudioMixer();
      final device = FakePeerAudioDevice('a');
      await mixer.attach('p1', device);
      await mixer.setGain('p1', 1.0);
      expect(device.trackEnabled, isTrue);
      expect(device.rendererBound, isTrue);
      expect(device.gains, <double>[1.0]);

      await mixer.setGain('p1', 0);
      expect(device.trackEnabled, isFalse, reason: '音轨必须显式禁用');
      expect(device.rendererBound, isFalse, reason: '渲染器必须解绑，双保险');
      expect(mixer.isSilenced('p1'), isTrue);

      await mixer.setGain('p1', 1.2);
      expect(device.trackEnabled, isTrue);
      expect(device.rendererBound, isTrue);
      expect(device.gains.last, 1.2);
      expect(mixer.isSilenced('p1'), isFalse);
    });

    test('本地静音开关与音量并联：静音时不动音量值，取消后按原音量恢复', () async {
      final mixer = PeerAudioMixer();
      final device = FakePeerAudioDevice('a');
      await mixer.attach('p1', device);
      await mixer.setGain('p1', 1.6);

      await mixer.setMuted('p1', true);
      expect(device.trackEnabled, isFalse);
      expect(device.rendererBound, isFalse);
      expect(mixer.gainOf('p1'), 1.6, reason: '静音不该把音量改掉');

      await mixer.setMuted('p1', false);
      expect(device.trackEnabled, isTrue);
      expect(device.rendererBound, isTrue);
      expect(device.gains.last, 1.6);
    });
  });

  group('离开 / 关闭 peer 不残留', () {
    test('detach 只影响该成员，其它成员音量与开关不变', () async {
      final mixer = PeerAudioMixer();
      final alice = FakePeerAudioDevice('alice');
      final bob = FakePeerAudioDevice('bob');
      await mixer.attach('a', alice);
      await mixer.attach('b', bob);
      await mixer.setGain('a', 0.2);
      await mixer.setGain('b', 1.6);

      final bobGainsBefore = List<double>.of(bob.gains);
      mixer.detach('a');

      expect(mixer.gainOf('b'), 1.6);
      expect(bob.gains, bobGainsBefore, reason: '拆掉别人的连接不该动 bob 的音量');
      expect(bob.trackEnabled, isTrue);

      // 对端重连后新音轨到来：a 的音量保持不变地重新应用
      final aliceAgain = FakePeerAudioDevice('alice-again');
      await mixer.attach('a', aliceAgain);
      expect(aliceAgain.gains, <double>[0.2]);
      expect(bob.gains, bobGainsBefore);
    });

    test('forget（成员真的离开）后状态归零，且不影响其他人', () async {
      final mixer = PeerAudioMixer();
      final alice = FakePeerAudioDevice('alice');
      final bob = FakePeerAudioDevice('bob');
      await mixer.attach('a', alice);
      await mixer.attach('b', bob);
      await mixer.setGain('a', 0.2);
      await mixer.setGain('b', 1.6);

      mixer.forget('a');
      expect(mixer.gainOf('a'), 1.0, reason: '状态已清掉');
      expect(mixer.isSilenced('a'), isFalse);
      expect(mixer.gainOf('b'), 1.6);

      mixer.clear();
      expect(mixer.gainOf('b'), 1.0);
    });
  });

  group('降级', () {
    test('原生增益报错不抛异常，音量值仍然保留', () async {
      final mixer = PeerAudioMixer();
      final device = FakePeerAudioDevice('a')..failGain = true;
      await mixer.attach('p1', device);

      await mixer.setGain('p1', 1.5);

      expect(mixer.gainOf('p1'), 1.5);
      expect(device.gains, isEmpty, reason: '失败不记为已下发');
      expect(device.trackEnabled, isTrue, reason: '报错也要继续出声，只是没放大');
      // 设备恢复后再设同一个值会重试下发
      device.failGain = false;
      await mixer.setGain('p1', 1.6);
      expect(device.gains, <double>[1.6]);
    });
  });
}
