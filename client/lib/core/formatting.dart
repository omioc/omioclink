import 'package:intl/intl.dart';

/// 聊天时间：今天只显示时分，其余显示月-日 时:分。
String formatChatTime(DateTime time) {
  final local = time.toLocal();
  final now = DateTime.now();
  final isToday =
      local.year == now.year &&
      local.month == now.month &&
      local.day == now.day;
  return DateFormat(isToday ? 'HH:mm' : 'MM-dd HH:mm').format(local);
}

/// 毫秒 → 时长（设计稿里用于展示连接时长）。
String formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
}

/// 码率展示：1.2 Mbps / 320 kbps。
String formatBitrate(double bitsPerSecond) {
  if (bitsPerSecond <= 0 || !bitsPerSecond.isFinite) {
    return '—';
  }
  if (bitsPerSecond >= 1000 * 1000) {
    return '${(bitsPerSecond / 1000 / 1000).toStringAsFixed(1)} Mbps';
  }
  return '${(bitsPerSecond / 1000).round()} kbps';
}

/// 房间容量文案：3/5。
String formatCapacity(int members, int capacity) => '$members/$capacity';

/// kbps 展示（房间统计里已经是 kbps）。
String formatKbps(double? kbps) {
  if (kbps == null || kbps <= 0 || !kbps.isFinite) {
    return '—';
  }
  if (kbps >= 1000) {
    return '${(kbps / 1000).toStringAsFixed(1)} Mbps';
  }
  return '${kbps.toStringAsFixed(0)} kbps';
}
