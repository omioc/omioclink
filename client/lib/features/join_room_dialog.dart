import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../core/app_theme.dart';
import '../core/formatting.dart';
import '../core/l10n_ext.dart';
import '../data/api_client.dart';
import '../data/models.dart';
import '../widgets/common.dart';

/// 按房间号加入房间。
///
/// 这是**私有房间的唯一入口**——私有房间不出现在公开列表里，只能靠房间号进来。
/// 先查一次房间信息（存在性 / 是否需要密码 / 是否已满），查到了再进入，
/// 这样密码错误、房间不存在之类的问题在弹窗里就能说清楚，而不是进去以后才失败。
Future<bool> showJoinRoomDialog(BuildContext context) async {
  final state = context.read<AppState>();
  final joined = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _JoinRoomDialog(state: state),
  );
  return joined ?? false;
}

class _JoinRoomDialog extends StatefulWidget {
  const _JoinRoomDialog({required this.state});

  final AppState state;

  @override
  State<_JoinRoomDialog> createState() => _JoinRoomDialogState();
}

class _JoinRoomDialogState extends State<_JoinRoomDialog> {
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();
  final _codeFocus = FocusNode();

  Room? _room;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _codeFocus.requestFocus(),
    );
  }

  @override
  void dispose() {
    _codeController.dispose();
    _passwordController.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  String get _code =>
      _codeController.text.trim().toUpperCase().replaceAll(RegExp(r'\s'), '');

  Future<void> _lookup() async {
    final api = widget.state.api;
    final code = _code;
    if (api == null) {
      setState(() => _error = context.l10n.roomsJoinNotConnected);
      return;
    }
    if (code.isEmpty) {
      setState(() => _error = context.l10n.roomsJoinEnterCode);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _room = null;
    });
    try {
      final room = await api.getRoom(code);
      if (!mounted) {
        return;
      }
      // 记住过密码的房间直接填上，点「进入房间」即可
      final remembered = widget.state.roomPasswordFor(room.roomId);
      if (remembered != null && remembered.isNotEmpty) {
        _passwordController.text = remembered;
      }
      setState(() {
        _room = room;
        _busy = false;
      });
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _error = error.code == 'room_not_found'
            ? context.l10n.roomsJoinNotFound(code)
            : error.message;
      });
    }
  }

  Future<void> _join() async {
    final room = _room;
    if (room == null) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await widget.state.joinRoom(
      roomId: room.roomId,
      password: _passwordController.text.isEmpty
          ? null
          : _passwordController.text,
    );
    if (!mounted) {
      return;
    }
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }
    // 失败原因已经写在 state.error 里，这里取过来内联显示，并把顶部横幅清掉避免重复
    setState(() {
      _busy = false;
      _error = widget.state.error ?? context.l10n.roomsJoinFailed;
    });
    widget.state.clearMessages();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final room = _room;
    final full = room != null && room.isFull;

    return AlertDialog(
      title: Text(
        l10n.roomsJoinRoom,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.roomsJoinCodeHint,
              style: TextStyle(
                color: context.palette.textSecondary,
                fontSize: 12,
                height: 1.6,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    textAlignVertical: TextAlignVertical.center,
                    controller: _codeController,
                    focusNode: _codeFocus,
                    enabled: !_busy,
                    textCapitalization: TextCapitalization.characters,
                    inputFormatters: [
                      LengthLimitingTextInputFormatter(8),
                      FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
                    ],
                    onChanged: (_) {
                      if (_room != null) {
                        setState(() => _room = null);
                      }
                    },
                    onSubmitted: (_) => _lookup(),
                    style: const TextStyle(fontSize: 18, letterSpacing: 4),
                    decoration: const InputDecoration(
                      hintText: 'XXXXXX',
                      hintStyle: TextStyle(fontSize: 16, letterSpacing: 4),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilledButton(
                  onPressed: _busy ? null : _lookup,
                  child: Text(l10n.roomsJoinLookup),
                ),
              ],
            ),
            if (room != null) ...[
              const SizedBox(height: AppSpacing.md),
              PanelCard(
                color: context.palette.panelSubtle,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            room.name,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (!room.isPublic)
                          Icon(
                            Icons.lock_rounded,
                            size: 13,
                            color: context.palette.warning,
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      room.ownerName == null
                          ? formatCapacity(room.memberCount, room.capacity)
                          : l10n.roomsJoinOwnerLine(
                              formatCapacity(room.memberCount, room.capacity),
                              room.ownerName!,
                            ),
                      style: TextStyle(
                        color: context.palette.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              if (room.hasPassword) ...[
                const SizedBox(height: AppSpacing.md),
                TextField(
                  textAlignVertical: TextAlignVertical.center,
                  controller: _passwordController,
                  enabled: !_busy,
                  obscureText: true,
                  onSubmitted: (_) => _join(),
                  decoration: InputDecoration(
                    hintText: l10n.roomsPasswordHint,
                    prefixIcon: const Icon(Icons.key_rounded, size: 16),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  l10n.roomsPasswordRememberNote,
                  style: TextStyle(color: context.palette.textMuted, fontSize: 11),
                ),
              ],
            ],
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Icon(
                    Icons.error_outline_rounded,
                    size: 15,
                    color: context.palette.danger,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: context.palette.danger,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: room == null || full || _busy ? null : _join,
          child: Text(full ? l10n.roomsRoomFull : l10n.roomsEnterRoom),
        ),
      ],
    );
  }
}
