package com.omioclink.omioclink_client

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * 通话保活：前台服务（话筒类型）+ 部分唤醒锁 + WiFi 高性能锁。
 *
 * 为什么需要它：手机息屏后系统会把普通进程按进暂停/省电状态，WebRTC 的采集与
 * 播放随之断掉——用户看到的就是「锁屏一会儿就掉出房间、也听不到人说话」。
 * 前台服务让系统知道我们正在通话（带常驻通知，可被系统展示），唤醒锁保证 CPU
 * 不休眠，WiFi 锁避免屏幕熄灭后网络被单独掐掉。
 *
 * 只负责「进程活着 + CPU/网络可用」；音频路由与音频焦点仍由 flutter_webrtc 管。
 */
class CallForegroundService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundCompat()
        acquireLocks()
        // 不自动重启：房间状态在 Dart 侧，重启一个没有会话的空服务没有意义
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }

    private fun startForegroundCompat() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "通话中",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "息屏后保持语音与麦克风继续工作"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle("OmiocLink 通话中")
            .setContentText("息屏后仍保持语音与麦克风")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Android 11+ 才有时长型前台服务类型；话筒类型必须在清单里声明，
            // 且 14 起还要配套 FOREGROUND_SERVICE_MICROPHONE 权限。
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun acquireLocks() {
        if (wakeLock == null) {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "omioclink:call").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        if (wifiLock == null) {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            wifiLock = wifi?.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "omioclink:call")
                ?.apply {
                    setReferenceCounted(false)
                    acquire()
                }
        }
    }

    private fun releaseLocks() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    companion object {
        private const val CHANNEL_ID = "omioclink_call"
        private const val NOTIFICATION_ID = 4711
    }
}
