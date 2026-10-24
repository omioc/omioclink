import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:omioclink_client/media/voice_profile.dart';
import 'package:omioclink_client/media/voice_tuning.dart';

/// 一份照 libwebrtc 实际生成格式写的 offer（行尾 CRLF）。
String offerSdp() => <String>[
  'v=0',
  'o=- 4611731400430051336 2 IN IP4 127.0.0.1',
  's=-',
  't=0 0',
  'a=group:BUNDLE 0',
  'm=audio 9 UDP/TLS/RTP/SAVPF 111 63 0 8 13',
  'c=IN IP4 0.0.0.0',
  'a=ice-ufrag:AbCd',
  'a=mid:0',
  'a=sendrecv',
  'a=rtpmap:111 opus/48000/2',
  'a=rtcp-fb:111 transport-cc',
  'a=fmtp:111 minptime=10;useinbandfec=1',
  'a=rtpmap:63 red/48000/2',
  'a=fmtp:63 111/111',
  'a=rtpmap:0 PCMU/8000',
].join('\r\n');

void main() {
  group('VoiceProfile', () {
    test('存储标识稳定并可往返', () {
      for (final profile in VoiceProfile.values) {
        expect(VoiceProfile.fromStorageId(profile.storageId), profile);
      }
    });

    test('认不出的标识回落默认档（旧版本残留 / 手改坏）', () {
      expect(VoiceProfile.fromStorageId(null), VoiceProfile.fallback);
      expect(VoiceProfile.fromStorageId(''), VoiceProfile.fallback);
      expect(VoiceProfile.fromStorageId('noisy'), VoiceProfile.fallback);
      expect(VoiceProfile.fallback, VoiceProfile.standard);
    });
  });

  group('micProcessingFor', () {
    test('回声消除任何档位都不关（关掉就是对方听到自己）', () {
      for (final profile in VoiceProfile.values) {
        expect(micProcessingFor(profile).echoCancellation, isTrue);
      }
    });

    test('标准档：降噪与高通留着，自动增益关掉', () {
      final processing = micProcessingFor(VoiceProfile.standard);
      expect(processing.noiseSuppression, isTrue);
      expect(processing.autoGainControl, isFalse, reason: '忽大忽小与底噪被抬起的主要来源');
      expect(processing.highpassFilter, isTrue);
    });

    test('强降噪档：打开自动增益', () {
      expect(micProcessingFor(VoiceProfile.aggressive).autoGainControl, isTrue);
      expect(micProcessingFor(VoiceProfile.aggressive).noiseSuppression, isTrue);
    });

    test('保真档：只留回声消除（降噪会把哼唱当噪声压掉）', () {
      final processing = micProcessingFor(VoiceProfile.preserve);
      expect(processing.noiseSuppression, isFalse);
      expect(processing.autoGainControl, isFalse);
      expect(processing.highpassFilter, isFalse);
    });
  });

  group('voiceMicrophoneConstraints', () {
    test('桌面端用 sourceId 选输入设备（那边的 deviceId 是播放设备）', () {
      final constraints = voiceMicrophoneConstraints(
        profile: VoiceProfile.standard,
        deviceId: 'mic-1',
        desktop: true,
      );
      final audio = constraints['audio'] as Map<String, dynamic>;
      expect(audio['sourceId'], 'mic-1');
      expect(audio.containsKey('deviceId'), isFalse);
    });

    test('Web / 移动端沿用 deviceId', () {
      final constraints = voiceMicrophoneConstraints(
        profile: VoiceProfile.standard,
        deviceId: 'mic-1',
        desktop: false,
      );
      final audio = constraints['audio'] as Map<String, dynamic>;
      expect(audio['deviceId'], 'mic-1');
      expect(audio.containsKey('sourceId'), isFalse);
    });

    test('空设备 id 不带设备约束（跟随系统默认）', () {
      final audio =
          voiceMicrophoneConstraints(
                profile: VoiceProfile.standard,
                deviceId: '',
                desktop: true,
              )['audio']
              as Map<String, dynamic>;
      expect(audio.containsKey('sourceId'), isFalse);
      expect(audio.containsKey('deviceId'), isFalse);
    });

    test('四个处理开关按档位下发，全程不带视频约束', () {
      final standard = voiceMicrophoneConstraints(
        profile: VoiceProfile.standard,
        desktop: true,
      );
      final audio = standard['audio'] as Map<String, dynamic>;
      expect(audio['echoCancellation'], isTrue);
      expect(audio['noiseSuppression'], isTrue);
      expect(audio['autoGainControl'], isFalse);
      // 原生的 map 分支里 highpassFilter 默认 false，不显式给就等于关着
      expect(audio['highpassFilter'], isTrue);
      expect(standard['video'], isFalse);
    });
  });

  group('opusFmtpOverrides', () {
    test('码率按档位，DTX 关，FEC 开', () {
      expect(opusFmtpOverrides(VoiceProfile.standard), <String, String>{
        'minptime': '10',
        'useinbandfec': '1',
        'usedtx': '0',
        'maxaveragebitrate': '64000',
      });
      expect(
        opusFmtpOverrides(VoiceProfile.preserve)['maxaveragebitrate'],
        '96000',
      );
    });

    test('不写 stereo：采集侧本来就单声道，写 stereo=1 只会白花一倍码率', () {
      for (final profile in VoiceProfile.values) {
        expect(opusFmtpOverrides(profile).containsKey('stereo'), isFalse);
        expect(opusFmtpOverrides(profile).containsKey('sprop-stereo'), isFalse);
      }
    });
  });

  group('applyVoiceCodecTuning', () {
    test('改写 opus 的 fmtp，并按固定顺序补上覆盖项', () {
      final tuned = applyVoiceCodecTuning(offerSdp(), VoiceProfile.standard);
      expect(
        tuned,
        contains(
          'a=fmtp:111 minptime=10;useinbandfec=1;usedtx=0;maxaveragebitrate=64000',
        ),
      );
    });

    test('别的编解码、其它 SDP 行原样保留', () {
      final tuned = applyVoiceCodecTuning(offerSdp(), VoiceProfile.standard);
      expect(tuned, contains('a=fmtp:63 111/111'));
      expect(tuned, contains('a=rtpmap:0 PCMU/8000'));
      expect(tuned, contains('a=group:BUNDLE 0'));
      expect(tuned, contains('a=ice-ufrag:AbCd'));
    });

    test('行尾仍是 CRLF，行数与顺序不变', () {
      final original = offerSdp();
      final tuned = applyVoiceCodecTuning(original, VoiceProfile.standard);
      expect(tuned.contains('\r\n'), isTrue);
      expect(tuned.split('\r\n').length, original.split('\r\n').length);
      final before = original.split('\r\n');
      final after = tuned.split('\r\n');
      for (var i = 0; i < before.length; i++) {
        if (before[i].startsWith('a=fmtp:111 ')) {
          continue;
        }
        expect(after[i], before[i], reason: '第 ${i + 1} 行不该被动到');
      }
    });

    test('原有的未知参数保留（不认识的参数不该被我们吃掉）', () {
      final sdp = offerSdp().replaceFirst(
        'a=fmtp:111 minptime=10;useinbandfec=1',
        'a=fmtp:111 minptime=20;cbr=1;maxplaybackrate=48000',
      );
      final tuned = applyVoiceCodecTuning(sdp, VoiceProfile.standard);
      expect(tuned, contains('cbr=1'));
      expect(tuned, contains('maxplaybackrate=48000'));
      // 被我们覆盖的项只出现一次，且取我们的值
      expect('minptime=10'.allMatches(tuned).length, 1);
      expect(tuned.contains('minptime=20'), isFalse);
    });

    test('没有 fmtp 行时在 rtpmap 后面补一行', () {
      final sdp = offerSdp().replaceFirst('a=fmtp:111 minptime=10;useinbandfec=1\r\n', '');
      final tuned = applyVoiceCodecTuning(sdp, VoiceProfile.standard);
      final lines = tuned.split('\r\n');
      final rtpmapAt = lines.indexOf('a=rtpmap:111 opus/48000/2');
      expect(rtpmapAt, isNonNegative);
      expect(
        lines[rtpmapAt + 1],
        'a=fmtp:111 minptime=10;useinbandfec=1;usedtx=0;maxaveragebitrate=64000',
      );
    });

    test('每个音频段各自补一行（麦克风与投屏回环是两条 m 行）', () {
      final secondSection = <String>[
        'm=audio 9 UDP/TLS/RTP/SAVPF 111',
        'c=IN IP4 0.0.0.0',
        'a=mid:1',
        'a=rtpmap:111 opus/48000/2',
        'a=fmtp:111 minptime=10;useinbandfec=1',
      ].join('\r\n');
      final tuned = applyVoiceCodecTuning(
        '${offerSdp()}\r\n$secondSection',
        VoiceProfile.preserve,
      );
      expect('usedtx=0'.allMatches(tuned).length, 2);
      expect('maxaveragebitrate=96000'.allMatches(tuned).length, 2);
    });

    test('没有 opus 的 SDP 原样返回（连对象都不新建）', () {
      final sdp = 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 0\r\na=rtpmap:0 PCMU/8000';
      expect(applyVoiceCodecTuning(sdp, VoiceProfile.standard), same(sdp));
      expect(applyVoiceCodecTuning('', VoiceProfile.standard), same(''));
    });

    test('只有 LF 的 SDP 也能改，行尾不被换成 CRLF', () {
      final sdp = offerSdp().replaceAll('\r\n', '\n');
      final tuned = applyVoiceCodecTuning(sdp, VoiceProfile.standard);
      expect(tuned.contains('\r'), isFalse);
      expect(tuned, contains('maxaveragebitrate=64000'));
    });
  });

  group('voiceSendParameters', () {
    test('码率上限跟着档位走，优先级拉满（投屏占满上行时语音先走）', () {
      final parameters = voiceSendParameters(VoiceProfile.standard);
      final encoding = parameters.encodings!.single;
      expect(encoding.maxBitrate, 64000);
      expect(encoding.priority, RTCPriorityType.high);
      expect(encoding.networkPriority, RTCPriorityType.high);
      expect(
        voiceSendParameters(VoiceProfile.preserve).encodings!.single.maxBitrate,
        96000,
      );
    });

    test('不给 minBitrate：网络差的时候不该硬逼编码器花比特', () {
      expect(voiceSendParameters(VoiceProfile.standard).encodings!.single.minBitrate, isNull);
    });
  });

  group('describeInboundAudioLatency', () {
    test('抖动缓冲按「累计延迟 / 出包数」算成毫秒', () {
      final text = describeInboundAudioLatency(<Object?, Object?>{
        'jitterBufferDelay': 0.744,
        'jitterBufferEmittedCount': 12,
      });
      expect(text, '抖动缓冲=62ms');
    });

    test('抖动以秒上报时换算成毫秒，已是毫秒时原样', () {
      expect(
        describeInboundAudioLatency(<Object?, Object?>{'jitter': 0.004}),
        '抖动=4.0ms',
      );
      expect(
        describeInboundAudioLatency(<Object?, Object?>{'jitter': 12}),
        '抖动=12.0ms',
      );
    });

    test('丢包与补偿比例', () {
      final text = describeInboundAudioLatency(<Object?, Object?>{
        'packetsLost': 3,
        'concealedSamples': 480,
        'samplesDecoded': 96000,
      });
      expect(text, contains('丢包=3'));
      expect(text, contains('补偿=0.5%'));
    });

    test('字段缺失就不出现，出包数为 0 时不做除法', () {
      expect(describeInboundAudioLatency(<Object?, Object?>{}), '');
      expect(
        describeInboundAudioLatency(<Object?, Object?>{
          'jitterBufferDelay': 1.0,
          'jitterBufferEmittedCount': 0,
        }),
        '',
      );
    });
  });
}
