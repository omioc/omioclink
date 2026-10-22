import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../core/app_theme.dart';
import '../core/formatting.dart';
import '../data/api_client.dart';
import '../media/media_engine.dart';
import '../media/media_models.dart';
import '../media/share_policy.dart';
import '../media/stun_probe.dart';
import '../musicfree/plugin_models.dart';
import '../widgets/common.dart';

/// 确认对话框。
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmText = '确定',
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        title,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      content: Text(
        message,
        style: TextStyle(
          color: context.palette.textSecondary,
          fontSize: 13,
          height: 1.6,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmText),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// 修改密码。
///
/// 成功后本机自动换用服务端新签发的令牌（不用重新登录），其他设备下次请求会被登出。
Future<void> showChangePasswordDialog(BuildContext context) async {
  final state = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  final currentController = TextEditingController();
  final nextController = TextEditingController();
  final confirmController = TextEditingController();
  String? error;
  var busy = false;

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) {
        Future<void> submit() async {
          final next = nextController.text;
          if (next.length < 8) {
            setState(() => error = '新密码至少 8 位');
            return;
          }
          if (next != confirmController.text) {
            setState(() => error = '两次输入的新密码不一致');
            return;
          }
          setState(() {
            busy = true;
            error = null;
          });
          try {
            await state.changePassword(
              currentPassword: currentController.text,
              newPassword: next,
            );
            if (!dialogContext.mounted) {
              return;
            }
            Navigator.of(dialogContext).pop();
            messenger.showSnackBar(
              const SnackBar(content: Text('密码已修改，其他设备需要重新登录')),
            );
          } on ApiException catch (failure) {
            if (dialogContext.mounted) {
              setState(() {
                error = failure.message;
                busy = false;
              });
            }
          }
        }

        return AlertDialog(
          title: const Text(
            '修改密码',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  textAlignVertical: TextAlignVertical.center,
                  controller: currentController,
                  autofocus: true,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '当前密码'),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  textAlignVertical: TextAlignVertical.center,
                  controller: nextController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '新密码',
                    helperText: '至少 8 位',
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  textAlignVertical: TextAlignVertical.center,
                  controller: confirmController,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '确认新密码'),
                  onSubmitted: (_) {
                    if (!busy) {
                      submit();
                    }
                  },
                ),
                if (error != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    error!,
                    style: TextStyle(
                      color: context.palette.danger,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: busy ? null : submit,
              child: Text(busy ? '提交中…' : '确认修改'),
            ),
          ],
        );
      },
    ),
  );

  currentController.dispose();
  nextController.dispose();
  confirmController.dispose();
}

/// 创建房间。
Future<void> showCreateRoomDialog(BuildContext context) async {
  final state = context.read<AppState>();
  final nameController = TextEditingController();
  final passwordController = TextEditingController();
  var capacity = state.serverInfo?.roomCapacity ?? 5;
  var isPublic = true;

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) => AlertDialog(
        title: const Text(
          '创建房间',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                textAlignVertical: TextAlignVertical.center,
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(hintText: '房间名称，例如 游戏开黑'),
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  const SizedBox(
                    width: 64,
                    child: Text('人数上限', style: TextStyle(fontSize: 12)),
                  ),
                  Expanded(
                    child: Slider(
                      value: capacity.toDouble(),
                      min: 2,
                      max: (state.serverInfo?.maxRoomCapacity ?? 8).toDouble(),
                      divisions: (state.serverInfo?.maxRoomCapacity ?? 8) - 2,
                      label: '$capacity 人',
                      onChanged: (value) =>
                          setState(() => capacity = value.round()),
                    ),
                  ),
                  Text('$capacity 人', style: const TextStyle(fontSize: 12)),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                textAlignVertical: TextAlignVertical.center,
                controller: passwordController,
                obscureText: true,
                decoration: const InputDecoration(hintText: '房间密码（可选）'),
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Switch(
                    value: isPublic,
                    onChanged: (value) => setState(() => isPublic = value),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    isPublic ? '公开展示在房间列表' : '仅凭房间号加入',
                    style: TextStyle(
                      fontSize: 12,
                      color: context.palette.textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '共享屏幕时，5 人房间建议把码率降到 2 Mbps / 720p，'
                '8 人房间必须启用自适应降档',
                style: TextStyle(
                  color: context.palette.textMuted,
                  fontSize: 11,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final name = nameController.text.trim();
              if (name.isEmpty) {
                return;
              }
              Navigator.of(dialogContext).pop();
              final room = await state.createRoom(
                name: name,
                capacity: capacity,
                password: passwordController.text.isEmpty
                    ? null
                    : passwordController.text,
                isPublic: isPublic,
              );
              if (room != null) {
                await state.joinRoom(
                  roomId: room.roomId,
                  password: passwordController.text.isEmpty
                      ? null
                      : passwordController.text,
                );
              }
            },
            child: const Text('创建并进入'),
          ),
        ],
      ),
    ),
  );

  nameController.dispose();
  passwordController.dispose();
}

/// 房间号（邀请好友）。
Future<void> showRoomCodeDialog(BuildContext context, String roomId) async {
  final code = roomId.isEmpty ? '——' : roomId.toUpperCase();
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text(
        '邀请好友',
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '把房间号发给好友，他们在「房间列表」里输入或直接进入即可',
            style: TextStyle(
              color: context.palette.textSecondary,
              fontSize: 12,
              height: 1.6,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Center(
            child: SelectableText(
              code,
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w700,
                letterSpacing: 6,
                color: context.palette.accent,
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: code));
            if (dialogContext.mounted) {
              ScaffoldMessenger.of(dialogContext)
                  .showSnackBar(const SnackBar(content: Text('房间号已复制')));
            }
          },
          child: const Text('复制房间号'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}

/// 屏幕/窗口选择器：返回选中的源、是否并入系统声音、以及编码策略。
Future<({String id, bool withSystemAudio, SharePolicy policy})?>
showScreenSourceDialog(BuildContext context, MediaEngine media) async {
  List<ScreenSource> sources = const <ScreenSource>[];
  String? error;
  try {
    sources = await media.listScreenSources();
  } on MediaException catch (exception) {
    error = exception.message;
  }
  if (!context.mounted) {
    return null;
  }

  ScreenSource? selected = sources.isEmpty ? null : sources.first;
  // 默认把系统声音一起分享：共享的游戏/视频本来就是为了让对方听到
  var withSystemAudio = true;
  var policy = SharePolicy.fallback;

  return showDialog<({String id, bool withSystemAudio, SharePolicy policy})>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) => AlertDialog(
        title: const Text(
          '选择共享内容',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: SizedBox(
          // 手机上 620×420 会被压成一条：按可用空间收窄，网格另降到 2 列
          width: MediaQuery.sizeOf(context).width > 700
              ? 620
              : MediaQuery.sizeOf(context).width - 80,
          height: MediaQuery.sizeOf(context).height > 520
              ? 420
              : MediaQuery.sizeOf(context).height * 0.6,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (error != null)
                Text(
                  error,
                  style: TextStyle(color: context.palette.danger, fontSize: 12),
                )
              else
                Expanded(
                  child: GridView.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: MediaQuery.sizeOf(context).width > 700
                          ? 3
                          : 2,
                      mainAxisSpacing: AppSpacing.md,
                      crossAxisSpacing: AppSpacing.md,
                      childAspectRatio: 1.5,
                    ),
                    itemCount: sources.length,
                    itemBuilder: (context, index) {
                      final source = sources[index];
                      final isSelected = source.id == selected?.id;
                      return GestureDetector(
                        onTap: () => setState(() => selected = source),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.black,
                                  borderRadius: AppRadii.small,
                                  border: Border.all(
                                    color: isSelected
                                        ? context.palette.accent
                                        : context.palette.divider,
                                    width: isSelected ? 2 : 1,
                                  ),
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: source.thumbnail == null
                                    ? Icon(
                                        Icons.desktop_windows_outlined,
                                        size: 22,
                                        color: context.palette.textMuted,
                                      )
                                    : Image.memory(
                                        source.thumbnail!,
                                        fit: BoxFit.cover,
                                        gaplessPlayback: true,
                                        // 原生返回的是源自身分辨率的图（主屏 1920×1080），
                                        // 卡片只有两百来像素宽，缩小解码省内存
                                        cacheWidth: 480,
                                      ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Icon(
                                  source.isWindow
                                      ? Icons.window_rounded
                                      : Icons.desktop_windows_rounded,
                                  size: 12,
                                  color: context.palette.textMuted,
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    source.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              const Divider(height: AppSpacing.xl),
              Row(
                children: [
                  SizedBox(
                    width: 56,
                    child: Text(
                      '优先保证',
                      style: TextStyle(
                        color: context.palette.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  for (final item in SharePolicy.values) ...[
                    if (item != SharePolicy.values.first)
                      const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: _PolicyCard(
                        policy: item,
                        selected: item == policy,
                        onTap: () => setState(() => policy = item),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '码率不用手调：按观众人数自动分配，单路上行不超过 30 Mbps',
                style: TextStyle(
                  color: context.palette.textMuted,
                  fontSize: 11,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 13,
                    color: context.palette.textMuted,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      policy.detail,
                      style: TextStyle(
                        color: context.palette.textMuted,
                        fontSize: 11,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Switch(
                    value: withSystemAudio,
                    onChanged: (value) =>
                        setState(() => withSystemAudio = value),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      '同时共享系统声音（游戏/播放器声音）。外放时远端可能听到回声，建议戴耳机',
                      style: TextStyle(
                        color: context.palette.textSecondary,
                        fontSize: 11,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: selected == null
                ? null
                : () {
                    final source = selected;
                    if (source == null) {
                      return;
                    }
                    Navigator.of(dialogContext).pop((
                      id: source.id,
                      withSystemAudio: withSystemAudio,
                      policy: policy,
                    ));
                  },
            child: const Text('开始共享'),
          ),
        ],
      ),
    ),
  );
}

/// 策略卡片：选中的用强调色描边 + 淡底，未选中的用面板底色，
/// 鼠标移上去描边微亮（和源选择卡片、导航项保持同一套视觉语言）。
class _PolicyCard extends StatefulWidget {
  const _PolicyCard({
    required this.policy,
    required this.selected,
    required this.onTap,
  });

  final SharePolicy policy;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_PolicyCard> createState() => _PolicyCardState();
}

class _PolicyCardState extends State<_PolicyCard> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
          decoration: BoxDecoration(
            color: selected ? context.palette.accentSoft : context.palette.panelSubtle,
            borderRadius: AppRadii.medium,
            border: Border.all(
              color: selected
                  ? context.palette.accent
                  : _hovering
                  ? context.palette.accent.withValues(alpha: 0.45)
                  : context.palette.divider,
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.policy.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected
                      ? context.palette.textPrimary
                      : context.palette.textSecondary,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                widget.policy.scene,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected
                      ? context.palette.textSecondary
                      : context.palette.textMuted,
                  fontSize: 11,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 网络诊断：STUN/NAT 判定 + 各成员直连方式。
Future<void> showDiagnosticsDialog(BuildContext context) async {
  final state = context.read<AppState>();
  final iceServers = state.serverInfo?.iceServers ?? const <String>[];

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      child: SizedBox(
        // 640×560 在手机上会顶出屏幕：按可用空间收，内容本身是可滚动的
        width: MediaQuery.sizeOf(context).width > 720
            ? 640
            : MediaQuery.sizeOf(context).width - 32,
        height: MediaQuery.sizeOf(context).height > 640
            ? 560
            : MediaQuery.sizeOf(context).height - 80,
        child: _DiagnosticsBody(iceServers: iceServers),
      ),
    ),
  );
}

class _DiagnosticsBody extends StatefulWidget {
  const _DiagnosticsBody({required this.iceServers});

  final List<String> iceServers;

  @override
  State<_DiagnosticsBody> createState() => _DiagnosticsBodyState();
}

class _DiagnosticsBodyState extends State<_DiagnosticsBody> {
  NatDiagnosis? _diagnosis;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    setState(() => _running = true);
    final diagnosis = await StunProbe.diagnose(widget.iceServers);
    if (!mounted) {
      return;
    }
    setState(() {
      _diagnosis = diagnosis;
      _running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppState>().session;

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.health_and_safety_rounded,
                size: 16,
                color: context.palette.accent,
              ),
              const SizedBox(width: AppSpacing.sm),
              const Text(
                '网络诊断',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: _running ? null : _run,
                icon: _running
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded, size: 15),
                label: const Text('重新检测'),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Expanded(
            child: ListView(
              children: [
                _section(
                  'NAT 与 UDP 可达性',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_diagnosis == null)
                        Text(
                          '正在探测…',
                          style: TextStyle(
                            color: context.palette.textMuted,
                            fontSize: 12,
                          ),
                        )
                      else ...[
                        _badge(switch (_diagnosis!.type) {
                          NatType.cone => ('锥型 NAT · 可打洞直连', context.palette.success),
                          NatType.symmetric => (
                            '对称型 NAT · 无法直连',
                            context.palette.danger,
                          ),
                          NatType.blocked => (
                            'UDP 不可达 · 无法通话',
                            context.palette.danger,
                          ),
                          NatType.unknown => ('未知', context.palette.textMuted),
                        }),
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          _diagnosis!.summary,
                          style: TextStyle(
                            color: context.palette.textSecondary,
                            fontSize: 12,
                            height: 1.7,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        for (final result in _diagnosis!.results)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              children: [
                                StatusDot(
                                  color: result.ok
                                      ? context.palette.success
                                      : context.palette.danger,
                                  size: 6,
                                ),
                                const SizedBox(width: AppSpacing.sm),
                                Expanded(
                                  child: Text(
                                    result.server,
                                    style: TextStyle(
                                      color: context.palette.textSecondary,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                                Text(
                                  result.ok
                                      ? '公网映射 ${result.mapped}${result.roundTrip == null ? '' : ' · ${result.roundTrip!.inMilliseconds}ms'}'
                                      : result.mapped,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: result.ok
                                        ? context.palette.textSecondary
                                        : context.palette.danger,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                _section(
                  '成员连接',
                  child: session == null || !session.phase.isActive
                      ? Text(
                          '尚未进入房间',
                          style: TextStyle(
                            color: context.palette.textMuted,
                            fontSize: 12,
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final view in session.members)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 3,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        view.local
                                            ? '${view.info.displayName}（我）'
                                            : view.info.displayName,
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ),
                                    if (view.local)
                                      Text(
                                        '本机',
                                        style: TextStyle(
                                          color: context.palette.textMuted,
                                          fontSize: 11,
                                        ),
                                      )
                                    else ...[
                                      Text(
                                        session
                                            .linkStateOf(view.info.peerId)
                                            .label,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color:
                                              session
                                                  .linkStateOf(view.info.peerId)
                                                  .isLive
                                              ? context.palette.success
                                              : context.palette.warning,
                                        ),
                                      ),
                                      const SizedBox(width: AppSpacing.md),
                                      Text(
                                        session.stats.peers[view.info.peerId] ==
                                                null
                                            ? '—'
                                            : '${session.stats.peers[view.info.peerId]!.toStringAsFixed(0)}ms',
                                        style: TextStyle(
                                          color: context.palette.textMuted,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            const SizedBox(height: AppSpacing.sm),
                            Text(
                              '上行 ${formatKbps(session.stats.outgoingKbps)} · '
                              '下行 ${formatKbps(session.stats.incomingKbps)}',
                              style: TextStyle(
                                color: context.palette.textMuted,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String title, {required Widget child}) => PanelCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(text: title),
        const SizedBox(height: AppSpacing.sm),
        child,
      ],
    ),
  );

  Widget _badge((String, Color) value) => Container(
    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 5),
    decoration: BoxDecoration(
      color: value.$2.withValues(alpha: 0.15),
      borderRadius: AppRadii.pill,
      border: Border.all(color: value.$2.withValues(alpha: 0.4)),
    ),
    child: Text(
      value.$1,
      style: TextStyle(
        color: value.$2,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

/// 刷新订阅时「要装哪些插件」的选择框。
///
/// 订阅里可能有几十个插件：全下载 + 全编译要好几分钟，还会一直占着内存。这里让
/// 用户先勾，没勾的连请求都不发。
///
/// 返回选中的插件地址集合；点「取消」返回 null —— 调用方据此**一个插件都不动**。
Future<Set<String>?> showPluginPickerDialog(
  BuildContext context, {
  required List<MusicFreeSubscriptionEntry> entries,
  required Set<String> preselected,
  String? subscriptionUrl,
}) {
  // 用副本：勾选过程中不要把调用方的集合改了（它可能就是「上次的选择」）
  final selected = <String>{...preselected};
  final source = (subscriptionUrl ?? '').trim();

  return showDialog<Set<String>>(
    context: context,
    // 点外面不关：这里一关就是「什么都没选」，容易误触
    barrierDismissible: false,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) {
        final allSelected =
            entries.isNotEmpty && selected.length == entries.length;
        return AlertDialog(
          title: const Text(
            '选择要安装的插件',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          content: SizedBox(
            // 手机上按可用宽收窄；高度也不硬顶，几十项不能把弹框撑出屏幕
            width: MediaQuery.sizeOf(context).width > 560
                ? 480
                : MediaQuery.sizeOf(context).width - 80,
            height: MediaQuery.sizeOf(context).height > 560
                ? 420
                : MediaQuery.sizeOf(context).height * 0.62,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '订阅里共 ${entries.length} 个插件，已选 ${selected.length} 个。'
                  '没选中的不会下载、也不会编译。',
                  style: TextStyle(
                    color: context.palette.textSecondary,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
                if (source.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      source,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.palette.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    TextButton(
                      onPressed: () => setState(() {
                        if (allSelected) {
                          selected.clear();
                        } else {
                          selected
                            ..clear()
                            ..addAll(entries.map((entry) => entry.url));
                        }
                      }),
                      child: Text(allSelected ? '全不选' : '全选'),
                    ),
                    const Spacer(),
                    Text(
                      '已选 ${selected.length} / ${entries.length}',
                      style: TextStyle(
                        color: context.palette.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Expanded(
                  child: ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      return CheckboxListTile(
                        value: selected.contains(entry.url),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        onChanged: (value) => setState(() {
                          if (value == true) {
                            selected.add(entry.url);
                          } else {
                            selected.remove(entry.url);
                          }
                        }),
                        title: Text(
                          entry.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                        subtitle: entry.detail.isEmpty
                            ? null
                            : Text(
                                entry.detail,
                                style: TextStyle(
                                  color: context.palette.textMuted,
                                  fontSize: 11,
                                ),
                              ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              // 一个都不选等于「把这条订阅的插件全删了」，太容易误触；
              // 真想清空可以逐个卸载。
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.of(dialogContext).pop(<String>{...selected}),
              child: Text('安装 ${selected.length} 个'),
            ),
          ],
        );
      },
    ),
  );
}
