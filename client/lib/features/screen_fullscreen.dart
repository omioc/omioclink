import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_log.dart';
import '../core/app_theme.dart';
import '../core/l10n_ext.dart';
import '../core/platform.dart';
import '../room/room_session.dart';

/// 全屏观看共享画面：画面按比例铺满整块屏幕。
///
/// 除了盖住应用自己的界面，还会把窗口切成系统全屏——无边框窗口下这是「更大」的
/// 唯一办法（否则画面再大也只在窗口里），退出时恢复窗口原状。
///
/// [rendererOf] 每次重建都会重新取一次渲染器：远端画面可能比点击晚到，
/// 共享中断时也会变成 null。
Future<void> showScreenFullscreen(
  BuildContext context, {
  required RoomSession session,
  required RTCVideoRenderer? Function() rendererOf,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  // 切窗口不 await：平台调用慢甚至不返回时，也要能立刻把画面铺出来
  unawaited(_setNativeFullscreen(true));
  try {
    await navigator.push<void>(
      PageRouteBuilder<void>(
        opaque: true,
        pageBuilder: (_, _, _) =>
            ScreenFullscreenView(session: session, rendererOf: rendererOf),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  } finally {
    unawaited(_setNativeFullscreen(false));
  }
}

Future<void> _setNativeFullscreen(bool value) async {
  // 桌面才有「窗口全屏」这回事；手机本身就是全屏，调用只会抛
  // MissingPluginException 再被 catch 成一条无意义的 warn 日志
  if (!isDesktopPlatform) {
    return;
  }
  try {
    await windowManager.setFullScreen(value);
  } on Object catch (error) {
    // 非致命：窗口没切成全屏，应用内依然是全屏观看
    AppLog.warn('切换系统全屏失败（$value）', error: error);
  }
}

/// 全屏观看界面本体：黑底 + 按比例铺满的共享画面 + 会自动隐藏的控制条。
///
/// 不碰窗口（进出系统全屏由 [showScreenFullscreen] 负责），因此可以直接单测。
/// 退出方式：右上角按钮、Esc、双击画面；共享结束时自己退出。
class ScreenFullscreenView extends StatefulWidget {
  const ScreenFullscreenView({
    super.key,
    required this.session,
    required this.rendererOf,
  });

  final RoomSession session;

  /// 当前共享画面的渲染器（自己共享 = 本地预览，别人共享 = 远端画面）。
  final RTCVideoRenderer? Function() rendererOf;

  @override
  State<ScreenFullscreenView> createState() => _ScreenFullscreenViewState();
}

class _ScreenFullscreenViewState extends State<ScreenFullscreenView> {
  /// 鼠标不动这么久之后控制条淡出，把画面让出来。
  static const Duration _controlsTimeout = Duration(seconds: 3);

  Timer? _hideTimer;
  bool _controlsVisible = true;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSessionChanged);
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    widget.session.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _onSessionChanged() {
    if (!mounted) {
      return;
    }
    // 共享结束（或换人共享）就别把一块黑屏留在全屏上
    if (widget.session.activeSharer == null) {
      scheduleMicrotask(() {
        if (mounted) {
          _exit();
        }
      });
      return;
    }
    setState(() {});
  }

  void _exit() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    }
  }

  void _showControls() {
    _scheduleHide();
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_controlsTimeout, () {
      if (mounted && _controlsVisible) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final sharer = session.activeSharer;
    final selfSharing = sharer != null && sharer.peerId == session.selfPeerId;
    final name = sharer?.displayName ?? '';
    final renderer = widget.rendererOf();

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _exit,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: MouseRegion(
            cursor: _controlsVisible
                ? MouseCursor.defer
                : SystemMouseCursors.none,
            onHover: (_) => _showControls(),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _showControls,
              onDoubleTap: _exit,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (renderer != null)
                    RTCVideoView(
                      renderer,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                    )
                  else
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.screen_share_rounded,
                            size: 34,
                            color: context.palette.accent,
                          ),
                          const SizedBox(height: AppSpacing.md),
                          Text(
                            selfSharing
                                ? context.l10n.callShareStarting
                                : context.l10n.callReceivingScreen(name),
                            style: TextStyle(
                              // 黑底舞台上的文字：不跟主题走，浅色主题的深灰字在这里看不清
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  Positioned.fill(
                    child: IgnorePointer(
                      ignoring: !_controlsVisible,
                      child: AnimatedOpacity(
                        opacity: _controlsVisible ? 1 : 0,
                        duration: const Duration(milliseconds: 220),
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.lg),
                          child: Column(
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // 必须让徽标**撑满**自己分到的那块宽度：只写 Flexible
                                  // 时它拿的是松约束、按内容宽度绘制，没用掉的部分会变成
                                  // Row 末尾的空白（RenderFlex 按子节点实际宽度累加），
                                  // 于是「退出全屏」停在画面中间而不是贴着右边。
                                  Flexible(
                                    child: Align(
                                      alignment:
                                          AlignmentDirectional.centerStart,
                                      child: _NameBadge(
                                        text: selfSharing
                                            ? context.l10n.callSharingSelfBadge
                                            : context.l10n.callSharingBadge(name),
                                      ),
                                    ),
                                  ),
                                  _ControlButton(
                                    icon: Icons.fullscreen_exit_rounded,
                                    label: context.l10n.callExitFullscreen,
                                    onPressed: _exit,
                                  ),
                                ],
                              ),
                              const Spacer(),
                              Text(
                                context.l10n.callFullscreenExitHint,
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 左上角「谁在共享」的胶囊标签，与通话页大画面上的那枚保持一致。
class _NameBadge extends StatelessWidget {
  const _NameBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: 6,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: AppRadii.pill,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.screen_share_rounded,
            size: 13,
            color: Colors.white,
          ),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// 压在画面上的半透明文字按钮。
class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.14),
      borderRadius: AppRadii.small,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: 8,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: Colors.white),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
