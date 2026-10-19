/// SNTP 式时钟偏移估计（房间点歌同步用）。
///
/// 播放同步只看**服务器时钟**：`serverNow = localNow + offset`。
/// 样本来自 `ping/pong`（客户端发 `t`、服务端回 `serverTimeMs`）：
///
/// ```
/// offset = serverTimeMs - (t0 + t1) / 2      // t0 发出、t1 收到（本机毫秒）
/// rtt    = t1 - t0
/// ```
///
/// 只保留 **RTT 最小**的那条样本：网络抖动对它的污染最小（协议 §5.1）。
class ClockSync {
  int? _bestRttMs;
  int _offsetMs = 0;
  bool _hasSample = false;

  /// 是否已经有过一次「可信」样本（ping/pong）。
  bool get hasSample => _hasSample;

  /// 当前偏移（毫秒）：服务器时钟 − 本机时钟。
  int get offsetMs => _offsetMs;

  /// 当前最好样本的往返时延（毫秒），没样本时为 null。
  int? get bestRttMs => _bestRttMs;

  /// 喂一条 ping/pong 样本。
  void addSample({
    required int t0,
    required int serverTimeMs,
    required int t1,
  }) {
    if (serverTimeMs <= 0 || t1 < t0) {
      return;
    }
    final rtt = t1 - t0;
    final offset = serverTimeMs - (t0 + t1) ~/ 2;
    final best = _bestRttMs;
    if (best != null && rtt >= best) {
      return;
    }
    _bestRttMs = rtt;
    _offsetMs = offset;
    _hasSample = true;
  }

  /// 还没拿到 ping/pong 样本时的兜底：用一条服务端消息自带的 `serverTimeMs`
  /// 粗估一次（偏大或偏小约 RTT/2，只用于「首屏别等太久」，一旦有真样本就被替换）。
  void addBootstrapSample({required int serverTimeMs, required int localNowMs}) {
    if (_hasSample || serverTimeMs <= 0) {
      return;
    }
    _offsetMs = serverTimeMs - localNowMs;
  }

  /// 服务器此刻的毫秒时间；没有样本时退回本机时钟。
  int serverNowMs() => DateTime.now().millisecondsSinceEpoch + _offsetMs;

  /// 把一条服务器时间戳换算成「本机时钟」上的时刻（便于与播放位置比较）。
  int toLocalMs(int serverMs) => serverMs - _offsetMs;

  void reset() {
    _bestRttMs = null;
    _offsetMs = 0;
    _hasSample = false;
  }
}
