import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/music/lrc.dart';

/// LRC 解析与「当前唱到第几句」的下标计算。
void main() {
  test('解析标准 LRC：[mm:ss] / [mm:ss.xx] / [mm:ss.xxx] 都认', () {
    final lines = parseLrc('''
[ti:测试标题]
[ar:测试歌手]
[00:12]十二秒
[01:02.5]一分零二秒半
[02:03.500]两分零三秒五
''');

    expect(
      lines.map((line) => line.text),
      <String>['十二秒', '一分零二秒半', '两分零三秒五'],
      reason: '元信息（ti / ar）没有时间轴，必须被跳过',
    );
    expect(lines[0].time, const Duration(seconds: 12));
    expect(
      lines[1].time,
      const Duration(minutes: 1, seconds: 2, milliseconds: 500),
    );
    expect(
      lines[2].time,
      const Duration(minutes: 2, seconds: 3, milliseconds: 500),
    );
  });

  test('一行多个时间标签会展开成多条，纯空拍被丢掉', () {
    final lines = parseLrc('''
[00:05.00]副歌
[00:10.00][00:30.00][00:50.00]副歌复用
[00:20.00]
''');

    expect(
      lines.map((line) => line.text),
      <String>['副歌', '副歌复用', '副歌复用', '副歌复用'],
    );
    expect(lines[1].time, const Duration(seconds: 10));
    expect(lines[2].time, const Duration(seconds: 30));
    expect(lines[3].time, const Duration(seconds: 50));
    expect(
      lines.any((line) => line.time == const Duration(seconds: 20)),
      isFalse,
      reason: '只有时间标签没有正文的空拍不该进列表',
    );
  });

  test('乱序输入按时间排好序；空文本返回空列表', () {
    final lines = parseLrc('[00:20.00]B\n[00:10.00]A\n');
    expect(lines.map((line) => line.text), <String>['A', 'B']);
    expect(parseLrc('   '), isEmpty);
    expect(parseLrc('没有时间轴的一行'), isEmpty);
  });

  test('activeLyricIndex：前奏 -1、跨句、最后一句之后都正确', () {
    final lines = parseLrc('[00:10.00]A\n[00:20.00]B\n');
    expect(activeLyricIndex(const <LyricLine>[], Duration.zero), -1);
    expect(activeLyricIndex(lines, const Duration(seconds: 9)), -1);
    expect(activeLyricIndex(lines, const Duration(seconds: 10)), 0);
    expect(activeLyricIndex(lines, const Duration(seconds: 19)), 0);
    expect(activeLyricIndex(lines, const Duration(seconds: 20)), 1);
    expect(activeLyricIndex(lines, const Duration(minutes: 5)), 1);
  });
}
