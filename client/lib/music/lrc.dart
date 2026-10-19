/// 一行歌词：时间轴 + 正文。
class LyricLine {
  const LyricLine({required this.time, required this.text});

  final Duration time;
  final String text;
}

/// 时间标签：`[mm:ss]` / `[mm:ss.xx]` / `[mm:ss.xxx]`，一行可以带好几个。
final RegExp _lrcTimeTag = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');

/// 解析 LRC 文本。
///
/// * `[ti:]` `[ar:]` 这类元信息不含时间轴，天然被跳过；
/// * 一行多个时间标签（副歌复用同一句）会展开成多条；
/// * 只有时间标签、没有正文的「空拍」丢掉——它们没有显示价值；
/// * 结果按时间排好序，方便二分找当前那句。
List<LyricLine> parseLrc(String raw) {
  if (raw.trim().isEmpty) {
    return const <LyricLine>[];
  }
  final lines = <LyricLine>[];
  for (final rawLine in raw.split(RegExp(r'\r?\n'))) {
    final tags = _lrcTimeTag.allMatches(rawLine).toList(growable: false);
    if (tags.isEmpty) {
      continue;
    }
    final text = rawLine.substring(tags.last.end).trim();
    if (text.isEmpty) {
      continue;
    }
    for (final tag in tags) {
      final minutes = int.parse(tag.group(1)!);
      final seconds = int.parse(tag.group(2)!);
      // 「.5」「.50」「.500」都按十进制小数补成毫秒
      final fraction = tag.group(3);
      final millis = fraction == null
          ? 0
          : int.parse(fraction.padRight(3, '0').substring(0, 3));
      lines.add(
        LyricLine(
          time: Duration(minutes: minutes, seconds: seconds, milliseconds: millis),
          text: text,
        ),
      );
    }
  }
  lines.sort((a, b) => a.time.compareTo(b.time));
  return List<LyricLine>.unmodifiable(lines);
}

/// 当前播放位置对应第几句歌词；还没到第一句时返回 `-1`。
int activeLyricIndex(List<LyricLine> lines, Duration position) {
  if (lines.isEmpty) {
    return -1;
  }
  var low = 0;
  var high = lines.length - 1;
  var found = -1;
  while (low <= high) {
    final mid = (low + high) >> 1;
    if (lines[mid].time <= position) {
      found = mid;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  return found;
}
