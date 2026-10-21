import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_theme.dart';
import '../media/media_models.dart';
import '../signaling/protocol.dart';

/// 圆形头像：有图显示图，否则用昵称首字 + 按 id 取的渐变。
class AvatarCircle extends StatelessWidget {
  const AvatarCircle({
    super.key,
    required this.seed,
    required this.label,
    this.bytes,
    this.size = 40,
    this.ring,
    this.dimmed = false,
  });

  final int seed;
  final String label;
  final Uint8List? bytes;
  final double size;
  final Color? ring;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final gradient = context.palette.avatarGradientFor(seed);
    final initial = label.isEmpty ? '?' : label.substring(0, 1);
    final avatar = DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: gradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: ClipOval(
        child: bytes != null
            ? Image.memory(bytes!, fit: BoxFit.cover, gaplessPlayback: true)
            : Center(
                child: Text(
                  initial,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: size * 0.4,
                    fontWeight: FontWeight.w600,
                    height: 1,
                  ),
                ),
              ),
      ),
    );
    return Opacity(
      opacity: dimmed ? 0.45 : 1,
      // 说话环直接叠在头像外缘上（同一个方形盒子里 Positioned.fill），
      // 不靠 padding 让位——用 padding 会把头像缩小，环和头像就容易看着不同心
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(child: avatar),
            if (ring != null)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: ring!, width: 2),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 小圆点状态指示。
class StatusDot extends StatelessWidget {
  const StatusDot({
    super.key,
    required this.color,
    this.size = 7,
    this.glow = false,
  });

  final Color color;
  final double size;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: glow
            ? <BoxShadow>[
                BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: 7),
              ]
            : null,
      ),
    );
  }
}

/// 带标题的卡片容器（设计稿里右栏与中栏的面板）。
class PanelCard extends StatelessWidget {
  const PanelCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.color,
    this.border,
    this.radius = AppRadii.card,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final Color? border;
  final BorderRadius radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? context.palette.panel,
        borderRadius: radius,
        border: Border.all(color: border ?? context.palette.hairline),
      ),
      child: child,
    );
  }
}

/// 小标题（右栏分组标题 / 卡片标题）。
class SectionLabel extends StatelessWidget {
  const SectionLabel({super.key, required this.text, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            text,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: context.palette.textSecondary,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
              height: 1.3,
            ),
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: AppSpacing.sm), trailing!],
      ],
    );
  }
}

/// 品牌标识（标题栏、连接页与左侧栏顶部）。
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.compact = false, this.size = 22});

  final bool compact;

  /// 图标边长；标题栏用默认值，连接页这类大场面可以放大。
  final double size;

  /// 品牌图（由仓库根的 `OmiocLink.png` 生成，见 `client/tool/make_brand_assets.py`）。
  static const String assetName = 'assets/branding/omioclink.png';

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(size * 0.28),
          child: Image.asset(
            assetName,
            width: size,
            height: size,
            fit: BoxFit.cover,
            // 资源缺失时退回原来的图标，别让标题栏开天窗
            errorBuilder: (context, error, stack) => Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [context.palette.accent, Color(0xFF8B5CF6)],
                ),
                borderRadius: BorderRadius.all(Radius.circular(6)),
              ),
              child: const Icon(Icons.link_rounded, size: 14, color: Colors.white),
            ),
          ),
        ),
        if (!compact) ...[
          const SizedBox(width: 9),
          Text(
            'OmiocLink',
            style: TextStyle(
              color: context.palette.textPrimary,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.1,
              height: 1.1,
            ),
          ),
        ],
      ],
    );
  }
}

/// 无边框窗口的自定义标题栏。
class WindowTitleBar extends StatelessWidget {
  const WindowTitleBar({super.key, this.statusText, this.statusColor});

  final String? statusText;
  final Color? statusColor;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
      onDoubleTap: () async {
        if (await windowManager.isMaximized()) {
          await windowManager.unmaximize();
        } else {
          await windowManager.maximize();
        }
      },
      child: Container(
        height: AppSizes.titleBar,
        decoration: BoxDecoration(
          color: context.palette.rail,
          border: Border(bottom: BorderSide(color: context.palette.hairline)),
        ),
        child: Row(
          children: [
            const SizedBox(width: AppSpacing.lg),
            const BrandMark(),
            if (statusText != null) ...[
              const SizedBox(width: AppSpacing.lg),
              StatusDot(color: statusColor ?? context.palette.success, size: 6),
              const SizedBox(width: 7),
              Text(
                statusText!,
                style: TextStyle(
                  color: context.palette.textMuted,
                  fontSize: 11.5,
                  height: 1.2,
                ),
              ),
            ],
            const Spacer(),
            _WindowButton(
              icon: Icons.remove,
              tooltip: '最小化',
              onTap: () => windowManager.minimize(),
            ),
            _WindowButton(
              icon: Icons.crop_square_rounded,
              tooltip: '最大化',
              onTap: () async {
                if (await windowManager.isMaximized()) {
                  await windowManager.unmaximize();
                } else {
                  await windowManager.maximize();
                }
              },
            ),
            _WindowButton(
              icon: Icons.close,
              tooltip: '关闭',
              danger: true,
              onTap: () => windowManager.close(),
            ),
          ],
        ),
      ),
    );
  }
}

class _WindowButton extends StatefulWidget {
  const _WindowButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool danger;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 110),
            width: 46,
            height: AppSizes.titleBar,
            color: _hovering
                ? (widget.danger
                      ? context.palette.danger
                      : context.palette.hover)
                : Colors.transparent,
            child: Icon(
              widget.icon,
              size: 15,
              color: _hovering && widget.danger
                  ? Colors.white
                  : context.palette.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 信号强度格（三格，按 RTT 映射）。
class SignalBars extends StatelessWidget {
  const SignalBars({super.key, this.latencyMs});

  final double? latencyMs;

  int get _level {
    final rtt = latencyMs;
    if (rtt == null) {
      return 0;
    }
    if (rtt < 80) {
      return 3;
    }
    if (rtt < 200) {
      return 2;
    }
    return 1;
  }

  @override
  Widget build(BuildContext context) {
    final level = _level;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List<Widget>.generate(3, (index) {
        final active = index < level;
        return Padding(
          padding: const EdgeInsets.only(left: 1.5),
          child: Container(
            width: 2.5,
            height: 4.5 + index * 3,
            decoration: BoxDecoration(
              color: active
                  ? context.palette.success
                  : context.palette.textMuted.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        );
      }),
    );
  }
}

/// 成员状态徽标（静音 / 共享 / 直连状态）。
class MemberBadges extends StatelessWidget {
  const MemberBadges({
    super.key,
    required this.member,
    this.linkState,
    this.latencyMs,
    this.isSelf = false,
    this.micLevel = 0,
    this.micSpeaking = false,
    this.micMutedLocally = false,
    this.onToggleMic,
  });

  final MemberInfo member;
  final PeerLinkState? linkState;
  final double? latencyMs;
  final bool isSelf;

  /// 该成员的实时电平（0..1 展示值）。
  final double micLevel;

  /// 是否在说话（可能来自 P2P 电平广播，也可能来自服务端中继的成员状态）。
  final bool micSpeaking;

  /// 我是否本地屏蔽了这个人（只影响我听不听得到）。
  final bool micMutedLocally;

  /// 点击麦克风图标的动作：自己=开关麦克风，别人=本地静音 / 恢复收听。
  final VoidCallback? onToggleMic;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (member.sharing) ...[
          Icon(
            Icons.screen_share_rounded,
            size: 12,
            color: context.palette.accent,
          ),
          const SizedBox(width: 6),
        ],
        _MicBadge(
          muted: member.muted,
          mutedLocally: micMutedLocally,
          speaking: micSpeaking,
          level: micLevel,
          isSelf: isSelf,
          onTap: onToggleMic,
        ),
        const SizedBox(width: 6),
        if (isSelf)
          Icon(
            Icons.wifi_tethering_rounded,
            size: 12,
            color: context.palette.textMuted.withValues(alpha: 0.7),
          )
        else
          SignalBars(latencyMs: latencyMs),
      ],
    );
  }
}

/// 麦克风徽标：既是实时电平指示（外圈进度环），也是一个静音开关。
class _MicBadge extends StatelessWidget {
  const _MicBadge({
    required this.muted,
    required this.mutedLocally,
    required this.speaking,
    required this.level,
    required this.isSelf,
    this.onTap,
  });

  /// 对方（或自己）把自己的麦克风关了。
  final bool muted;

  /// 我把对方的声音屏蔽了。
  final bool mutedLocally;

  final bool speaking;
  final double level;
  final bool isSelf;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final off = muted || mutedLocally;
    // 自己关麦=灰；我把别人屏蔽了=红（这是「我做的动作」，要显眼）
    final color = mutedLocally && !muted
        ? context.palette.danger
        : context.palette.textMuted;

    const size = 24.0;
    final badge = SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (!off)
            SizedBox(
              width: size,
              height: size,
              child: CircularProgressIndicator(
                value: level.clamp(0.0, 1.0),
                strokeWidth: 1.8,
                backgroundColor: context.palette.panelElevated,
                valueColor: AlwaysStoppedAnimation<Color>(
                  speaking
                      ? context.palette.success
                      : context.palette.success.withValues(alpha: 0.45),
                ),
              ),
            ),
          Icon(
            off ? Icons.mic_off_rounded : Icons.mic_rounded,
            size: 13,
            color: off ? color : context.palette.success,
          ),
        ],
      ),
    );

    final tooltip = off && mutedLocally
        ? (isSelf ? '打开麦克风' : '恢复收听')
        : (isSelf ? '静音（关闭我的麦克风）' : '静音（不再收听对方）');

    final content = Tooltip(message: tooltip, child: badge);
    if (onTap == null) {
      return content;
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: onTap, child: content),
    );
  }
}

/// 麦克风电平条：绿色填充随音量实时涨落。
///
/// [level] 是 0..1 的**展示值**（本地取 `MicLevel.display`，远端取电平广播里收到的值）。
/// 静音 / 麦克风不可用 / 被本地屏蔽时传 `enabled: false`，退化为灰条——
/// 避免出现「有电平在跳但麦克风其实是坏的」这种误导。
class MicLevelBar extends StatelessWidget {
  const MicLevelBar({
    super.key,
    required this.level,
    this.height = 6,
    this.enabled = true,
    this.speaking = false,
  });

  final double level;
  final double height;
  final bool enabled;
  final bool speaking;

  @override
  Widget build(BuildContext context) {
    final fill = enabled
        ? (speaking
              ? context.palette.success
              : context.palette.success.withValues(alpha: 0.7))
        : context.palette.textMuted.withValues(alpha: 0.5);
    final fraction = enabled ? level.clamp(0.0, 1.0) : 0.0;

    // 静默时不做补间：TweenAnimationBuilder 每进来一个新值就要排一帧动画，
    // 电平一直是 0 也会让这根条永远「动画中」，应用再也回不到空闲帧。
    // 用零尺寸孩子而不是 SizedBox.expand：宽度无约束时后者会撑出无穷宽。
    final Widget bar = fraction <= 0.001
        ? const SizedBox.shrink()
        : TweenAnimationBuilder<double>(
            // 采样 200ms 一次，这里补一点插值，看起来才是连续起伏的
            tween: Tween<double>(begin: 0, end: fraction),
            duration: const Duration(milliseconds: 160),
            builder: (context, value, _) => FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: value,
              child: ColoredBox(color: fill),
            ),
          );

    // 单独一层重绘边界：电平每 200ms 变一次，不该带着整块面板重画
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(height / 2),
        child: Container(
          height: height,
          color: context.palette.panelElevated,
          child: bar,
        ),
      ),
    );
  }
}

/// 麦克风状态行：状态点 + 文案。
///
/// 这就是「麦克风是否有效」的界面答案：绿=可用、黄=静音、灰=未启动、红=采集失败。
class MicStatusLine extends StatelessWidget {
  const MicStatusLine({super.key, required this.level, this.dense = false});

  final MicLevel level;

  /// 紧凑模式（右栏面板用）。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final Color dot;
    final Color textColor;
    if (level.error != null) {
      dot = context.palette.danger;
      textColor = context.palette.danger;
    } else if (!level.capturing) {
      dot = context.palette.textMuted;
      textColor = context.palette.textMuted;
    } else if (level.muted) {
      dot = context.palette.warning;
      textColor = context.palette.textSecondary;
    } else if (level.speaking) {
      dot = context.palette.success;
      textColor = context.palette.success;
    } else {
      dot = context.palette.success;
      textColor = context.palette.textSecondary;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: dense ? 6 : 7,
          height: dense ? 6 : 7,
          decoration: BoxDecoration(
            color: dot,
            shape: BoxShape.circle,
            // 说话指示用一圈实边，不用模糊阴影：boxShadow + blurRadius 每次重绘都要
            // 做一次高斯模糊，而电平每 200ms 刷一次，代价比这点效果值钱。
            border: level.speaking
                ? Border.all(
                    color: context.palette.success.withValues(alpha: 0.55),
                    width: 1.5,
                  )
                : null,
          ),
        ),
        SizedBox(width: dense ? 6 : 7),
        Flexible(
          child: Text(
            level.statusText,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: dense ? 11 : 11.5,
              color: textColor,
              height: 1.3,
            ),
          ),
        ),
      ],
    );
  }
}

/// 左侧栏的一行导航 / 房间项。
///
/// 选中态只用「抬一格的底色 + 左侧 2px 强调条」，不做实心胶囊：
/// 胶囊在深色侧栏里太重，也会把旁边的一列数字挤得没地方站。
class NavRow extends StatefulWidget {
  const NavRow({
    super.key,
    required this.icon,
    required this.label,
    this.trailing,
    this.selected = false,
    this.onTap,
    this.accent,
    this.dense = false,
  });

  final IconData icon;
  final String label;
  final Widget? trailing;
  final bool selected;
  final VoidCallback? onTap;
  final Color? accent;

  /// 紧凑样式：更小的图标和字号，用在空间紧张的面板（如点歌台导航）。
  final bool dense;

  @override
  State<NavRow> createState() => _NavRowState();
}

class _NavRowState extends State<NavRow> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final idle = widget.accent ?? context.palette.textSecondary;
    final iconColor = widget.selected ? context.palette.accent : idle;
    final labelColor = widget.selected
        ? context.palette.textPrimary
        : (_hovering ? context.palette.textPrimary : context.palette.textSecondary);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: widget.dense ? 28 : AppSizes.navRow,
          padding: EdgeInsets.only(
            left: widget.dense ? 7 : 9,
            right: widget.dense ? 7 : 8,
          ),
          decoration: BoxDecoration(
            color: widget.selected
                ? context.palette.panelElevated
                : (_hovering ? context.palette.hover : Colors.transparent),
            borderRadius: AppRadii.small,
          ),
          child: Row(
            children: [
              // 强调条槽位常驻，选中与否文字位置都不跳
              Container(
                width: 2.5,
                height: widget.dense ? 11 : 13,
                decoration: BoxDecoration(
                  color: widget.selected
                      ? context.palette.accent
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              SizedBox(width: widget.dense ? 7 : 9),
              Icon(widget.icon, size: widget.dense ? 13 : 15, color: iconColor),
              SizedBox(width: widget.dense ? 6 : 9),
              Expanded(
                child: Text(
                  widget.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: widget.dense ? 11 : 12.5,
                    color: labelColor,
                    fontWeight: widget.selected
                        ? FontWeight.w500
                        : FontWeight.w400,
                    height: 1.2,
                  ),
                ),
              ),
              if (widget.trailing != null) ...[
                const SizedBox(width: 6),
                widget.trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
