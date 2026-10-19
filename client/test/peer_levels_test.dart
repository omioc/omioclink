import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/room/peer_levels.dart';

void main() {
  late PeerLevels levels;

  setUp(() => levels = PeerLevels());

  test('没有记录时返回全零，不返回 null', () {
    final level = levels.levelOf('nobody');
    expect(level.level, 0);
    expect(level.speaking, isFalse);
    expect(level.measured, isFalse);
  });

  test('收到真实电平后标记为已测量', () {
    levels.applyRemote('p1', level: 0.42, speaking: true);
    final level = levels.levelOf('p1');
    expect(level.level, 0.42);
    expect(level.speaking, isTrue);
    expect(level.measured, isTrue);
  });

  test('服务端中继的说话状态不会覆盖已收到的真实电平', () {
    levels.applyRemote('p1', level: 0.42, speaking: true);
    levels.applySpeaking('p1', false);

    final level = levels.levelOf('p1');
    expect(level.level, 0.42, reason: '真实电平必须保留');
    expect(level.speaking, isFalse, reason: '说话状态取最新');
    expect(level.measured, isTrue);
  });

  test('只有服务端中继时，标记为「只知道在说话」', () {
    levels.applySpeaking('p1', true);
    final level = levels.levelOf('p1');
    expect(level.speaking, isTrue);
    expect(level.measured, isFalse, reason: '没有真实音量可画');
    expect(level.level, 0);
  });

  test('值没变就不通知，避免无谓重建', () {
    var notifications = 0;
    levels.addListener(() => notifications++);

    levels.applyRemote('p1', level: 0.4, speaking: true);
    levels.applyRemote('p1', level: 0.4, speaking: true);
    expect(notifications, 1);

    levels.applySpeaking('p1', true); // 与现值相同
    expect(notifications, 1);

    levels.applyRemote('p1', level: 0.5, speaking: true);
    expect(notifications, 2);
  });

  test('移除成员会丢掉他的电平并通知', () {
    var notifications = 0;
    levels.applyRemote('p1', level: 0.4, speaking: true);
    levels.addListener(() => notifications++);

    levels.remove('p1');
    expect(levels.levelOf('p1').measured, isFalse);
    expect(notifications, 1);

    // 移除不存在的成员不该通知
    levels.remove('p1');
    expect(notifications, 1);
  });

  test('清空用于离开房间后的复位', () {
    levels.applyRemote('p1', level: 0.4, speaking: true);
    levels.updateLocal('self', level: 0.2, speaking: false);

    levels.clear();
    expect(levels.levelOf('p1').measured, isFalse);
    expect(levels.levelOf('self').measured, isFalse);
  });
}
