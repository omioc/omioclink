import 'package:flutter_test/flutter_test.dart';
import 'package:quickjs_engine/quickjs_engine.dart';

/// 引擎的事件循环 drain 必须有上限。
///
/// 背景（真机事故）：插件里 `Promise.resolve().then(spin)` 这种「自己排自己」的
/// 微任务链会让队列永远抽不空。旧的 `while (true) { JS_ExecutePendingJob() }` 于是
/// 把 worker isolate **同步冻住** —— 那个 worker 上排队的调用全部不返回，
/// 连 `invoke` 自己的超时都触发不了（超时靠 Dart 定时器，而定时器需要事件循环）。
/// 症状就是点歌台「排行榜一直转圈」。
void main() {
  test('微任务饥饿不会冻死 isolate：drain 到上限就返回，引擎仍可用', () {
    final js = getJavascriptRuntime(xhr: false) as QuickJsRuntime2;
    addTearDown(js.dispose);

    final started = js.evaluate('''
      globalThis.__spins = 0;
      globalThis.__spin = function spin() {
        globalThis.__spins += 1;
        return Promise.resolve().then(spin);
      };
      __spin();
      'ok';
    ''');
    expect(started.isError, isFalse, reason: started.stringResult);

    final watch = Stopwatch()..start();
    js.executePendingJob();
    final elapsed = watch.elapsed;
    expect(
      elapsed,
      lessThan(const Duration(seconds: 15)),
      reason: 'drain 没有上限，isolate 被微任务饿死了',
    );

    // 确实跑了（说明不是「根本没抽」），而且是有限次
    final spins = int.tryParse(js.evaluate('__spins').stringResult.trim()) ?? 0;
    expect(spins, greaterThan(0), reason: '一个微任务都没跑，说明 drain 没生效');
    expect(
      spins,
      lessThanOrEqualTo(QuickJsRuntime2.maxJobsPerDrain),
      reason: '抽的个数超过了上限，说明上限没被用上',
    );

    // 冻住的引擎是没法再干活的：这里要求还能正常求值
    expect(js.evaluate('1 + 1').stringResult.trim(), '2');
  }, timeout: const Timeout(Duration(seconds: 60)));
}
