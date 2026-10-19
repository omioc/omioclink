import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/data/volume_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('成员音量（userId → 0~2）', () {
    test('写入后新建 store 读到一致的值', () async {
      await VolumeStore().savePeerVolumes(<String, double>{'7': 1.6, '8': 0.2});

      final read = await VolumeStore().loadPeerVolumes();
      expect(read, <String, double>{'7': 1.6, '8': 0.2});
    });

    test('没设置过时返回空表，取值走默认 100%', () async {
      final read = await VolumeStore().loadPeerVolumes();
      expect(read, isEmpty);
      expect(VolumeStore.defaultPeerVolume, 1.0);
      expect(read['42'] ?? VolumeStore.defaultPeerVolume, 1.0);
    });

    test('写入时钳制到 [0, 2]', () async {
      await VolumeStore().savePeerVolumes(<String, double>{'1': 9, '2': -3});
      final read = await VolumeStore().loadPeerVolumes();
      expect(read['1'], 2.0);
      expect(read['2'], 0.0);
    });

    test('整块坏数据（不是 JSON / 不是对象）不崩溃，回落默认', () async {
      for (final bad in <String>['{不是 JSON', '[1,2,3]', 'not-json-at-all']) {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'omioclink.volume.peers': bad,
        });
        final read = await VolumeStore().loadPeerVolumes();
        expect(read, isEmpty, reason: '坏数据「$bad」应整体回落');
      }
    });

    test('单条坏数据只丢那一条，其它成员照常读出来', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'omioclink.volume.peers':
            '{"1":"loud","2":1.6,"3":null,"":"0.5","4":0.35}',
      });
      final read = await VolumeStore().loadPeerVolumes();
      expect(read, <String, double>{'2': 1.6, '4': 0.35});
    });

    test('存储类型存错了（不是字符串）也不崩溃', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'omioclink.volume.peers': 3,
      });
      final read = await VolumeStore().loadPeerVolumes();
      expect(read, isEmpty);
    });

    test('清空后写回去 = 移除这条偏好', () async {
      await VolumeStore().savePeerVolumes(<String, double>{'7': 1.6});
      await VolumeStore().savePeerVolumes(<String, double>{});
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('omioclink.volume.peers'), isFalse);
    });
  });

  group('麦克风音量（0~100）', () {
    test('没设置过返回 null，写入后读回一致', () async {
      expect(await VolumeStore().loadMicVolume(), isNull);
      await VolumeStore().saveMicVolume(42);
      expect(await VolumeStore().loadMicVolume(), 42.0);
    });

    test('越界被钳制，NaN/无穷不落盘成怪值', () async {
      await VolumeStore().saveMicVolume(300);
      expect(await VolumeStore().loadMicVolume(), 100.0);
      await VolumeStore().saveMicVolume(-5);
      expect(await VolumeStore().loadMicVolume(), 0.0);
      expect(VolumeStore.clampMicVolume(double.nan), 100.0);
    });

    test('存成别的类型时按没设置过处理（不崩）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'omioclink.volume.mic': 'loud',
      });
      expect(await VolumeStore().loadMicVolume(), isNull);
    });
  });
}
