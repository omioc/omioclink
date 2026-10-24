package com.omioclink.omioclink_client

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 除了跑 Flutter，只多做一件事：把「通话保活」开关接到 [CallForegroundService]。
 *
 * 为什么放在原生而不是引一个保活插件：只有三行调用（start/stop），加一个依赖
 * 反而要跟着它的生命周期策略走；这里由 Dart 侧在进房/离房时精确控制。
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        // 必须在应用可见时调用：Android 12+ 禁止从后台启动前台服务
                        startService(Intent(this, CallForegroundService::class.java))
                        result.success(null)
                    }
                    "stop" -> {
                        stopService(Intent(this, CallForegroundService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    companion object {
        /// 与 Dart 侧 `CallKeepalive` 里的通道名保持一致。
        private const val CHANNEL = "omioclink/keepalive"
    }
}
