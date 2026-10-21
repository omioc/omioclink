import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'app_state.dart';
import 'core/app_log.dart';
import 'core/app_paths.dart';
import 'core/app_theme.dart';
import 'core/log_file.dart';
import 'core/platform.dart';

import 'data/theme_store.dart';
import 'features/connect_page.dart';
import 'features/home_shell.dart';

import 'signaling/signaling_client.dart';
import 'widgets/common.dart';

Future<void> main() async {
  // 启动时间线：每一段都打点，出问题时日志里 grep `ms` 就能定位是哪一段慢
  final boot = Stopwatch()..start();
  WidgetsFlutterBinding.ensureInitialized();

  // 手机上的数据目录要先定下来（应用私有目录），日志才有地方落盘
  await AppPaths.init();

  // 日志要最早挂上：后面每一步（窗口、插件、进房）都可能是出问题的地方。
  // 过期日志清理推迟到首帧之后（pruneExpired: false），别占启动路径。
  // 注意顺序：attachFile 之前的 timing 只会进 developer.log，**不会落盘**，
  // 所以 AppPaths 这一段要等文件挂上之后再补记（实测第一次启动日志里就缺了它）。
  AppLog.attachFile(LogFile.open(pruneExpired: false));
  AppLog.timing('启动.AppPaths', boot.elapsed);
  _installErrorHandlers();
  AppLog.info('启动 ${Platform.resolvedExecutable}');
  AppLog.info('系统 ${Platform.operatingSystemVersion}；pid=$pid');
  AppLog.info('日志文件 ${AppLog.filePath ?? '未落盘'}');
  AppLog.memory('启动');

  if (isDesktopPlatform) {
    final windowWatch = Stopwatch()..start();
    await _initDesktopWindow();
    AppLog.timing('启动.窗口就绪', windowWatch.elapsed);
    // 系统会在窗口最外圈描一道 1px 边框（DWM 画的，Dart 侧改不了），
    // 无边框窗口贴着它看就像「套了个相框」：交给 runner 关掉
    await _trimWindowBorder();
  } else {
    // 手机没有窗口：标题栏交给系统状态栏，内容顶到安全区里；状态栏与手势条
    // 设成透明，壁纸才能一直铺到窗口边缘
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
      ),
    );
  }

  // libmpv（14.8MB）不在这里同步加载：它要几十到几百毫秒，而用户很可能整个
  // 会话都不点歌。改成第一次真的要播时再加载，见 MusicPlayer.ensureMediaKitInitialized。
  // 系统代理也不再探测：代理交给用户的 TUN/虚拟网卡在系统层接管（设置页那块已删）。

  AppLog.timing('启动.runApp 前', boot.elapsed);
  runApp(const OmiocLinkApp());

  WidgetsBinding.instance.addPostFrameCallback((_) {
    AppLog.timing('启动.首帧', boot.elapsed);
    AppLog.memory('首帧');
    // 首帧之后再清 7 天前的旧日志（目录遍历 + 逐个 stat，属于同步 IO）
    Timer(const Duration(seconds: 3), () {
      LogFile.prune(Directory(LogFile.defaultDirectory()));
    });
  });
}

/// 桌面窗口：无边框 + 固定初始尺寸。手机上没有窗口，整段跳过。
Future<void> _initDesktopWindow() async {
  await windowManager.ensureInitialized();

  const options = WindowOptions(
    size: Size(1320, 860),
    minimumSize: Size(1120, 720),
    center: true,
    titleBarStyle: TitleBarStyle.hidden,
    title: 'OmiocLink',
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
  AppLog.memory('主窗口已就绪');
}

/// 关掉系统画在窗口最外侧的那 1px 边框。
///
/// 具体是 runner 里把 DWM 的 `DWMWA_BORDER_COLOR` 设成「不画」；Windows 10
/// 没有这个属性，调用失败也只是边框还在，所以异常全部吞掉，绝不因此起不来。
Future<void> _trimWindowBorder() async {
  try {
    await const MethodChannel(
      'omioclink/window',
    ).invokeMethod<void>('removeFrameBorder');
  } on Object {
    // 非 Windows 或系统不支持：保持系统默认外观
  }
}

/// 把三类「没人接」的异常都写进日志。
///
/// 这类异常原本只在控制台一闪而过（release 包里连闪都看不到），而闪退现场
/// 往往只剩它们留下的最后几行。`presentError` 保留调试期的红屏行为。
void _installErrorHandlers() {
  FlutterError.onError = (details) {
    AppLog.error(
      'Flutter 未捕获异常',
      error: details.exception,
      stackTrace: details.stack,
    );
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLog.error('异步未捕获异常', error: error, stackTrace: stack);
    return true;
  };
}

class OmiocLinkApp extends StatelessWidget {
  const OmiocLinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>(create: (_) => AppState()..bootstrap()),
        // 主题放在最外层：MaterialApp 的 theme 直接由它算出来，
        // 换主题时下游控件靠 Theme 的变更通知自己重画
        ChangeNotifierProvider<ThemeStore>(create: (_) => ThemeStore()..load()),
      ],
      child: const _App(),
    );
  }
}

/// 只负责「把主题翻译成 MaterialApp」：换主题重建的就是这一层。
class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeStore>();
    return MaterialApp(
      title: 'OmiocLink',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.data(theme.palette),
      home: const _Root(),
    );
  }
}

/// 无边框窗口：顶部自绘标题栏，内容区按登录状态切换。
///
/// 同时负责「关窗前收尾」：引擎销毁插件时会**先拆掉插件自己的任务运行器、
/// 之后才去停 WebRTC 线程**，中间那段窗口期里只要有 WebRTC 线程回调
/// （onRenegotiationNeeded 之类）进插件，就是一次访问违例闪退。所以关窗时
/// 先把房间/媒体收干净，再放行关闭。
class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> with WindowListener {
  /// 关闭流程是否已经在跑（避免重复收尾）。
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    // 窗口插件只有桌面端有实现：安卓上 addListener/setPreventClose 会抛
    // MissingPluginException，所以整个监听只挂在桌面端
    if (isDesktopPlatform) {
      windowManager.addListener(this);
      unawaited(windowManager.setPreventClose(true));
    }
  }

  @override
  void dispose() {
    if (isDesktopPlatform) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  void onWindowClose() => unawaited(_closeGracefully());

  @override
  void onWindowFocus() => AppLog.info('窗口获得焦点');

  @override
  void onWindowBlur() => AppLog.info('窗口失去焦点');

  /// 关窗：**先把窗口收起来**，再在后台把房间/媒体收干净，最后销毁窗口。
  ///
  /// 为什么不直接等收尾跑完再关：收尾要真的去关 PeerConnection、渲染器、
  /// 采集流（进过房间之后是几百毫秒级的原生活儿，卡住时更久），等着它跑完
  /// 用户就会看到窗口「卡一会儿才关」。窗口先隐藏，观感上就是立刻关闭，
  /// 收尾该做的一件不少（它必须在引擎销毁插件之前做完，理由见 [shutdownMedia]）。
  Future<void> _closeGracefully() async {
    if (_closing) {
      // 收尾还没跑完又被点了一次关闭：直接把窗口销毁掉，别让用户等第二遍
      await windowManager.destroy();
      return;
    }
    _closing = true;
    final stopwatch = Stopwatch()..start();
    // 状态在隐藏窗口之前先取出来：hide() 之后再用 context 就跨了 await
    final state = context.read<AppState>();
    AppLog.info('收到关闭请求：先隐藏窗口，再收尾');
    await windowManager.hide();
    try {
      await state.shutdownMedia().timeout(const Duration(milliseconds: 1500));
      AppLog.info('关闭前收尾完成（${stopwatch.elapsedMilliseconds}ms）');
    } on Object catch (error) {
      // 收尾超时或失败也要放行：关不掉窗口比崩溃更让人难受
      AppLog.warn('关闭前收尾超时或失败（${stopwatch.elapsedMilliseconds}ms）', error: error);
    } finally {
      AppLog.info('销毁窗口（收尾共 ${stopwatch.elapsedMilliseconds}ms）');
      await windowManager.destroy();
    }
  }

  @override
  Widget build(BuildContext context) {
    // 只盯这几个字段：AppState 是个大 ChangeNotifier，房间轮询、码率统计、麦克风
    // 电平都会 notify；用 watch 就是「任何一处变化 → 整棵树重建」。select 用 record
    // 的按值比较，只有真正影响这一层的字段变了才重建。
    final (loggedIn, error, signaling, connected, roomName, sessionActive) =
        context.select<
          AppState,
          (bool, String?, SignalingClient?, bool, String?, bool)
        >(
          (state) => (
            state.isLoggedIn,
            state.error,
            state.signaling,
            state.isConnectedToServer,
            state.session?.room?.name,
            state.session?.phase.isActive ?? false,
          ),
        );
    final statusText = !connected
        ? '未连接服务器'
        : sessionActive
        ? '房间内 · ${roomName ?? ''}'
        : '已连接到服务器';
    final statusColor = !connected
        ? context.palette.textMuted
        : sessionActive
        ? context.palette.accent
        : context.palette.success;
    final phase = signaling?.phase.value;
    final showReconnect =
        phase == SignalingPhase.reconnecting || phase == SignalingPhase.failed;

    final content = Column(
      children: [
        // 标题栏是桌面无边框窗口自绘的：手机上系统状态栏已经占住这一条，
        // 再画一遍会多出一条「假标题栏」
        if (isDesktopPlatform)
          _TitleBar(
            statusText: statusText,
            statusColor: statusColor,
          ),
        // 房间内发生的错误（房间被解散、账号被禁用、被管理员踢出…）之前只写进了
        // 状态里没人显示，用户会莫名其妙回到房间列表——这里统一提示出来
        if (error != null)
          _ErrorBanner(
            text: error,
            onDismiss: context.read<AppState>().clearMessages,
          ),
        Expanded(child: loggedIn ? const HomeShell() : const ConnectPage()),
        if (showReconnect && signaling != null)
          ValueListenableBuilder<SignalingPhase>(
            valueListenable: signaling.phase,
            builder: (context, phase, _) => _ReconnectBar(
              text: phase == SignalingPhase.reconnecting
                  ? '信令连接中断，正在自动重连…'
                  : '信令连接失败：${signaling.lastError.value ?? '未知原因'}',
              danger: phase == SignalingPhase.failed,
            ),
          ),
      ],
    );

    return Scaffold(
      backgroundColor: context.palette.background,
      body: Stack(
        children: [
          // 壁纸铺满整个窗口：标题栏、内容区、底部状态条都压在它上面，
          // 所以它是最底的一层，也不参与布局
          const Positioned.fill(child: _AppWallpaper()),
          // 手机要避开状态栏与手势条；桌面窗口自己就是边界，不需要 SafeArea
          if (isDesktopPlatform) content else SafeArea(child: content),
        ],
      ),
    );
  }

}

class _TitleBar extends StatelessWidget {
  const _TitleBar({this.statusText, this.statusColor});

  final String? statusText;
  final Color? statusColor;

  @override
  Widget build(BuildContext context) {
    // 标题栏自己带底色与下边发丝线，这里不再套一层容器
    return WindowTitleBar(statusText: statusText, statusColor: statusColor);
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.text, required this.onDismiss});

  final String text;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: context.palette.danger.withValues(alpha: 0.10),
        border: Border(
          bottom: BorderSide(color: context.palette.hairline),
        ),
      ),
      padding: const EdgeInsets.only(left: AppSpacing.page, right: 6),
      height: 32,
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 14,
            color: context.palette.danger,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.palette.danger,
                fontSize: 11.5,
                height: 1.3,
              ),
            ),
          ),
          IconButton(
            tooltip: '知道了',
            onPressed: onDismiss,
            iconSize: 14,
            icon: Icon(Icons.close_rounded, color: context.palette.danger),
          ),
        ],
      ),
    );
  }
}

class _ReconnectBar extends StatelessWidget {
  const _ReconnectBar({required this.text, required this.danger});

  final String text;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? context.palette.danger : context.palette.warning;
    return Container(
      width: double.infinity,
      height: 30,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border(top: BorderSide(color: context.palette.hairline)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
      child: Row(
        children: [
          if (!danger)
            SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(
                strokeWidth: 1.6,
                color: color,
                backgroundColor: color.withValues(alpha: 0.2),
              ),
            )
          else
            Icon(Icons.cloud_off_rounded, size: 13, color: color),
          const SizedBox(width: AppSpacing.sm),
          Text(
            text,
            style: TextStyle(color: color, fontSize: 11.5, height: 1.3),
          ),
        ],
      ),
    );
  }
}

/// 应用窗口的底：没贴壁纸时就是主题的舞台色，贴了就是「图 + 一层蒙版」。
///
/// 蒙版走 [DecorationImage] 的 colorFilter，而不是再套一层 Stack：
/// 少一层结构，壁纸也不会被兄弟节点切开。
class _AppWallpaper extends StatelessWidget {
  const _AppWallpaper();

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeStore>();
    final path = theme.wallpaperPath;
    // 底色取主题包里的原值：贴了壁纸时 palette.stage 是透明的，
    // 拿它兜底等于没有兜底（图读不出来时会看见窗口底下的黑）
    final stage = theme.pack.stage;
    if (path == null) {
      return ColoredBox(color: stage);
    }
    // 按窗口尺寸解码：壁纸原图可能长边 2400px，以前是「原图解码 + 每帧缩放到窗口」，
    // 这是 Windows 上最贵的合成路径之一。解码时就缩到目标像素，后续帧只做贴图。
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final size = MediaQuery.sizeOf(context);
    final targetWidth = (size.width * dpr).round();
    final targetHeight = (size.height * dpr).round();
    return ColoredBox(
      color: stage,
      // 换图走同一个文件路径，DecorationImage 又按值比较：不换 key 的话
      // 新旧的 BoxDecoration 相等，渲染层会早退、继续画缓存里那张旧图
      child: KeyedSubtree(
        key: ValueKey<int>(theme.wallpaperRevision),
        child: DecoratedBox(
          decoration: BoxDecoration(
            image: DecorationImage(
              image: ResizeImage(
                FileImage(File(path)),
                width: targetWidth,
                height: targetHeight,
                allowUpscaling: false,
                policy: ResizeImagePolicy.fit,
              ),
              fit: BoxFit.cover,
              // 蒙版：深浅主题各压一层，正文落在花哨的图上才读得出来
              colorFilter: ColorFilter.mode(
                theme.palette.wallpaperScrim,
                BlendMode.srcOver,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
