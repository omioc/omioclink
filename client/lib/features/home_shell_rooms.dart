part of 'home_shell.dart';


/// 「我创建的 / 我加入的 / 公开」分段切换。
///
/// 桌面上「我创建的房间」挂在左栏导航上（点一下就是这一套），这排 tab 只放
/// 后两档；手机上左栏没有位置，「我创建的」必须放进这排 tab，否则用户点完
/// 「公开」就再也找不到回自己房间的入口了（除非想起来再点一次底部导航）。
///
/// 这是与导航「我的房间」并列的**另一套逻辑**：点 tab 切换的是左栏/中栏展示的
/// 房间列表，不动「我创建的房间」那份数据；反过来点导航也不会改这里的选中态。
class _ScopeTabs extends StatelessWidget {
  const _ScopeTabs({
    required this.source,
    required this.joinedCount,
    required this.publicCount,
    required this.onChanged,
    this.createdCount,
    this.compactLabel = false,
  });

  /// 当前展示的那一套：命中哪个 tab 就高亮哪个；
  /// 「我创建的房间」只有传了 [createdCount] 时才在这排里。
  final RoomListSource source;
  final int joinedCount;
  final int publicCount;

  /// 「我创建的」数量；null = 不显示这一档（桌面端）。
  final int? createdCount;

  /// 窄屏：文案缩成「我创建 / 我加入」，三个 tab 才挤得下 360dp 宽的屏幕。
  final bool compactLabel;

  final ValueChanged<RoomListSource> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Container(
      height: 34,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        // 槽底平时是舞台色，贴壁纸后舞台透明：用 track 才不会变成一个空框
        color: context.palette.track,
        borderRadius: AppRadii.medium,
        border: Border.all(color: context.palette.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (createdCount != null) ...[
            Expanded(
              child: _tab(
                context,
                compactLabel
                    ? l10n.roomsTabCreatedShort
                    : l10n.roomsTabCreated,
                createdCount!,
                RoomListSource.created,
              ),
            ),
            const SizedBox(width: 3),
          ],
          Expanded(
            child: _tab(
              context,
              compactLabel
                  ? l10n.roomsTabJoinedShort
                  : l10n.roomsTabJoined,
              joinedCount,
              RoomListSource.joined,
            ),
          ),
          const SizedBox(width: 3),
          Expanded(
            child: _tab(
              context,
              l10n.roomsTabPublic,
              publicCount,
              RoomListSource.public,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tab(
    BuildContext context,
    String label,
    int count,
    RoomListSource value,
  ) {
    final selected = source == value;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => onChanged(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 130),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? context.palette.panelElevated : Colors.transparent,
            borderRadius: AppRadii.small,
            border: Border.all(
              color: selected ? context.palette.divider : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.2,
                  color: selected
                      ? context.palette.textPrimary
                      : context.palette.textMuted,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.2,
                  color: selected
                      ? context.palette.textSecondary
                      : context.palette.textMuted.withValues(alpha: 0.75),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoomsPane extends StatelessWidget {
  const _RoomsPane({
    required this.roomSource,
    required this.rooms,
    required this.selectedRoomId,
    required this.onSelectRoom,
    required this.onEnterRoom,
    required this.onReturnToCall,
  });

  final RoomListSource roomSource;
  final List<Room> rooms;
  final String? selectedRoomId;
  final ValueChanged<Room> onSelectRoom;
  final ValueChanged<Room> onEnterRoom;
  final VoidCallback onReturnToCall;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = context.l10n;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: AppSizes.pageHeader,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
          child: Row(
            children: [
              // 标题跟着当前这一套走（我创建的 / 我加入的 / 公开）
              Text(
                _roomListTitle(l10n, roomSource),
                style: AppText.pageTitle,
              ),
              const SizedBox(width: 10),
              Text(
                l10n.roomsCount(rooms.length),
                style: TextStyle(
                  color: context.palette.textMuted,
                  fontSize: 11.5,
                  height: 1.2,
                ),
              ),
              if (rooms.isNotEmpty) ...[
                const SizedBox(width: 14),
                Text(
                  l10n.roomsDoubleTapHint,
                  style: TextStyle(
                    color: context.palette.textMuted,
                    fontSize: 11,
                    height: 1.2,
                  ),
                ),
              ],
              const Spacer(),
              TextButton.icon(
                onPressed: () => state.refreshRooms(),
                icon: const Icon(Icons.refresh_rounded, size: 14),
                label: Text(l10n.roomsRefresh),
                style: TextButton.styleFrom(
                  foregroundColor: context.palette.textMuted,
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(width: 4),
              OutlinedButton.icon(
                onPressed: () => showJoinRoomDialog(context),
                icon: const Icon(Icons.login_rounded, size: 14),
                label: Text(l10n.roomsJoinRoom),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () => showCreateRoomDialog(context),
                icon: const Icon(Icons.add_rounded, size: 15),
                label: Text(l10n.roomsCreateRoom),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: rooms.isEmpty
              ? _EmptyRooms(roomSource: roomSource)
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.page,
                    14,
                    AppSpacing.page,
                    AppSpacing.xl,
                  ),
                  itemCount: rooms.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final room = rooms[index];
                    // 选中的房间**就地展开**（密码 / 进入 / 解散），列表本身不再被换掉：
                    // 以前选中就把整张列表替换成详情页，看起来像「我的房间没显示全」
                    return _RoomCard(
                      key: ValueKey(room.roomId),
                      room: room,
                      expanded: room.roomId == selectedRoomId,
                      onTap: () => onSelectRoom(room),
                      onDoubleTap: () => onEnterRoom(room),
                      onReturnToCall: onReturnToCall,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _EmptyRooms extends StatelessWidget {
  const _EmptyRooms({required this.roomSource});

  final RoomListSource roomSource;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (icon, title, hint) = switch (roomSource) {
      RoomListSource.created => (
        Icons.meeting_room_outlined,
        l10n.roomsEmptyCreatedTitle,
        l10n.roomsEmptyCreatedHint,
      ),
      RoomListSource.joined => (
        Icons.exit_to_app_rounded,
        l10n.roomsEmptyJoinedTitle,
        l10n.roomsEmptyJoinedHint,
      ),
      RoomListSource.public => (
        Icons.public_off_rounded,
        l10n.roomsEmptyPublicTitle,
        l10n.roomsEmptyPublicHint,
      ),
    };
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: context.palette.panel,
                borderRadius: AppRadii.card,
                border: Border.fromBorderSide(
                  BorderSide(color: context.palette.hairline),
                ),
              ),
              child: Icon(icon, size: 20, color: context.palette.textMuted),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.palette.textPrimary,
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.palette.textMuted,
                fontSize: 11.5,
                height: 1.6,
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: () => showJoinRoomDialog(context),
                  icon: const Icon(Icons.login_rounded, size: 14),
                  label: Text(l10n.roomsJoinByCode),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () => showCreateRoomDialog(context),
                  icon: const Icon(Icons.add_rounded, size: 15),
                  label: Text(l10n.roomsCreateRoom),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RoomCard extends StatefulWidget {
  const _RoomCard({
    super.key,
    required this.room,
    required this.expanded,
    required this.onTap,
    required this.onDoubleTap,
    required this.onReturnToCall,
  });

  final Room room;

  /// 选中：卡片高亮，并在卡片下方展开操作区（房间密码 / 进入房间 / 解散）。
  final bool expanded;

  /// 单击：选中房间（等双击判定结束再执行，否则双击会先被单击吃掉）。
  final VoidCallback onTap;

  /// 双击：直接进房（没密码或密码已记住时一步到位）。
  final VoidCallback onDoubleTap;

  /// 已经在这个房间里时，「进入房间」会变成「回到通话」，点它就是切回通话视图。
  final VoidCallback onReturnToCall;

  @override
  State<_RoomCard> createState() => _RoomCardState();
}

class _RoomCardState extends State<_RoomCard> {
  bool _hovering = false;

  /// 按下即高亮：单击选中要等双击判定，不给即时反馈会显得很迟钝。
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) {
      setState(() => _pressed = value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final room = widget.room;
    final l10n = context.l10n;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        child: PanelCard(
          color: widget.expanded || _hovering || _pressed
              ? context.palette.panelElevated
              : context.palette.panel,
          border: widget.expanded ? context.palette.divider : context.palette.hairline,
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: context.palette.accent.withValues(alpha: 0.13),
                      borderRadius: AppRadii.small,
                    ),
                    child: Icon(
                      room.isPublic ? Icons.forum_rounded : Icons.lock_rounded,
                      size: 15,
                      color: context.palette.accent,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                room.name,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  height: 1.35,
                                ),
                              ),
                            ),
                            if (room.hasPassword) ...[
                              const SizedBox(width: 5),
                              Icon(
                                Icons.key_rounded,
                                size: 11,
                                color: context.palette.warning.withValues(alpha: 0.9),
                              ),
                            ],
                          ],
                        ),
                        Text(
                          _roomIdLine(l10n, room),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.palette.textMuted,
                            fontSize: 10.5,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  // 人数 / 状态并成一行，右侧只留一个安静的箭头
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      StatusDot(
                        color: room.online
                            ? context.palette.success
                            : context.palette.textMuted.withValues(alpha: 0.5),
                        size: 5,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        formatCapacity(
                          context.watch<AppState>().memberCountFor(room),
                          room.capacity,
                        ),
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.2,
                          color: room.online
                              ? context.palette.textSecondary
                              : context.palette.textMuted,
                        ),
                      ),
                      if (room.online) ...[
                        const SizedBox(width: 6),
                        Text(
                          l10n.shellInCall,
                          style: TextStyle(
                            fontSize: 10.5,
                            height: 1.2,
                            color: context.palette.success,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(width: 6),
                  // 复制只在该出现的时候出现：悬停或展开
                  SizedBox(
                    width: 26,
                    child: (_hovering || widget.expanded)
                        ? IconButton(
                            tooltip: l10n.roomsCopyRoomId,
                            onPressed: () async {
                              await Clipboard.setData(
                                ClipboardData(text: room.roomId),
                              );
                              if (!context.mounted) {
                                return;
                              }
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(l10n.roomsRoomIdCopied(room.roomId)),
                                ),
                              );
                            },
                            icon: const Icon(Icons.copy_rounded, size: 13),
                          )
                        : null,
                  ),
                  Icon(
                    widget.expanded
                        ? Icons.expand_less_rounded
                        : Icons.chevron_right_rounded,
                    size: 16,
                    color: context.palette.textMuted,
                  ),
                ],
              ),
              if (widget.expanded) ...[
                const Divider(height: 18),
                _RoomDetail(
                  key: ValueKey(room.roomId),
                  room: room,
                  onReturnToCall: widget.onReturnToCall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 选中房间后展开在卡片里的操作区：房间密码 + 进入 / 解散。
///
/// 以前它是一整页详情（选中就把列表顶掉），现在挂在房间卡片下方就地展开——
/// 「我的房间」任何时候都能把房间列全。
class _RoomDetail extends StatefulWidget {
  /// 带上房间 id 作为 key：切换房间时重建状态，密码框才不会残留上一个房间的输入。
  const _RoomDetail({
    super.key,
    required this.room,
    required this.onReturnToCall,
    this.onJoined,
  });

  final Room room;

  /// 已经在这个房间里时，按钮就是「回到通话」。
  final VoidCallback onReturnToCall;

  /// 进房成功后的回调：手机上的底部面板靠它自己关掉。
  ///
  /// 不用「监听 AppState 变了就 pop」：那会在面板重建的同一帧里销毁密码框
  /// 的 controller，Flutter 会先报 `TextEditingController was used after
  /// being disposed`，再抛一次渲染断言，整页变空白。
  final VoidCallback? onJoined;

  @override
  State<_RoomDetail> createState() => _RoomDetailState();
}

class _RoomDetailState extends State<_RoomDetail> {
  final _passwordController = TextEditingController();
  bool _joining = false;

  @override
  void initState() {
    super.initState();
    // 记住过密码的房间直接填上，双击列表就能一步进
    final remembered = context.read<AppState>().roomPasswordFor(
      widget.room.roomId,
    );
    if (remembered != null && remembered.isNotEmpty) {
      _passwordController.text = remembered;
    }
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final state = context.read<AppState>();
    setState(() => _joining = true);
    try {
      final joined = await state.joinRoom(
        roomId: widget.room.roomId,
        password: _passwordController.text.isEmpty
            ? null
            : _passwordController.text,
      );
      if (joined) {
        widget.onJoined?.call();
      }
    } finally {
      if (mounted) {
        setState(() => _joining = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final room = widget.room;
    final isOwner = room.ownerId == state.user?.id;
    // 自己正待在这个房间里（通话中）
    final inThisRoom = state.isInRoom(room.roomId);
    final l10n = context.l10n;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (room.hasPassword && !inThisRoom) ...[
          SizedBox(
            // 手机上给满宽：260dp 的输入框在 360dp 屏里贴着边很难点
            width: MediaQuery.sizeOf(context).width < 420
                ? double.infinity
                : 260,
            child: TextField(
              textAlignVertical: TextAlignVertical.center,
              controller: _passwordController,
              obscureText: true,
              onSubmitted: (_) => _join(),
              style: const TextStyle(fontSize: 12.5),
              decoration: InputDecoration(
                hintText: l10n.roomsPasswordHint,
                prefixIcon: const Icon(Icons.key_rounded, size: 14),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            state.hasRememberedRoomPassword(room.roomId)
                ? l10n.roomsPasswordRemembered
                : l10n.roomsPasswordWillRemember,
            style: TextStyle(
              color: context.palette.textMuted,
              fontSize: 10.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        Row(
          children: [
            // 已经在这个房间里：别再「重新进一次」（那会把连接和媒体层拆了重建），
            // 按钮改成回到通话视图。
            if (inThisRoom)
              FilledButton.icon(
                onPressed: widget.onReturnToCall,
                icon: const Icon(Icons.meeting_room_rounded, size: 14),
                label: Text(l10n.roomsBackToCall),
              )
            else
              FilledButton.icon(
                onPressed: room.isFull || _joining ? null : _join,
                icon: _joining
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.8),
                      )
                    : const Icon(Icons.login_rounded, size: 14),
                label: Text(room.isFull ? l10n.roomsRoomFull : l10n.roomsEnterRoom),
              ),
            if (isOwner) ...[
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  final confirmed = await showConfirmDialog(
                    context,
                    title: l10n.roomsDissolveTitle,
                    message: l10n.roomsDissolveMessage(room.name),
                    confirmText: l10n.roomsDissolve,
                  );
                  if (confirmed) {
                    await state.deleteRoom(room.roomId);
                  }
                },
                icon: const Icon(Icons.delete_outline_rounded, size: 14),
                label: Text(l10n.roomsDissolve),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// 房间号那一行：房间号 +（有房主时）房主；桌面卡片与手机端详情共用一份拼法。
///
/// 分隔符留在代码里：四个语言的取值都只是「房主 X」，把「 · 」也塞进 ARB
/// 会让每个译文都得带一段与语言无关的标点，反而更容易被译错。
String _roomIdLine(AppL10n l10n, Room room) {
  final owner = room.ownerName;
  return l10n.roomsRoomId(room.roomId) +
      (owner == null ? '' : ' · ${l10n.roomsRoomOwner(owner)}');
}
