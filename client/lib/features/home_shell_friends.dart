part of 'home_shell.dart';


// --------------------------------------------------------------------------- //
// 好友
// --------------------------------------------------------------------------- //
class _FriendsPane extends StatefulWidget {
  const _FriendsPane();

  @override
  State<_FriendsPane> createState() => _FriendsPaneState();
}

class _FriendsPaneState extends State<_FriendsPane> {
  final _usernameController = TextEditingController();

  @override
  void dispose() {
    _usernameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final incoming = state.friendRequests
        .where((r) => r.direction == FriendRequestDirection.incoming)
        .toList();
    final outgoing = state.friendRequests
        .where((r) => r.direction == FriendRequestDirection.outgoing)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: AppSizes.pageHeader,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
          child: Row(
            children: [
              const Text('好友', style: AppText.pageTitle),
              const SizedBox(width: 10),
              Text(
                '${state.friends.length} 位',
                style: TextStyle(
                  color: context.palette.textMuted,
                  fontSize: 11.5,
                  height: 1.2,
                ),
              ),
              const SizedBox(width: 10),
              Container(
                width: 3,
                height: 3,
                decoration: BoxDecoration(
                  color: context.palette.textMuted.withValues(alpha: 0.6),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${state.onlineFriends.length} 在线',
                style: TextStyle(
                  color: state.onlineFriends.isEmpty
                      ? context.palette.textMuted
                      : context.palette.success,
                  fontSize: 11.5,
                  height: 1.2,
                ),
              ),
              const Spacer(),
              // 手机上没有下拉刷新，页头这个按钮就是唯一的「手动拉一次」入口：
              // 首次登录那次请求抖掉时，用户不用等 15 秒轮询，也不用重启应用
              IconButton(
                tooltip: '刷新好友',
                onPressed: () => state.refreshFriends(),
                icon: Icon(
                  Icons.refresh_rounded,
                  size: 18,
                  color: context.palette.textSecondary,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.page,
                  16,
                  AppSpacing.page,
                  AppSpacing.xl,
                ),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: AppSizes.control,
                          child: TextField(
                            textAlignVertical: TextAlignVertical.center,
                            controller: _usernameController,
                            style: const TextStyle(fontSize: 12.5),
                            cursorHeight: 15,
                            onSubmitted: (value) =>
                                state.sendFriendRequest(value.trim()),
                            decoration: const InputDecoration(
                              hintText: '输入用户名添加好友',
                              prefixIcon: Icon(
                                Icons.person_add_alt_1_rounded,
                                size: 14,
                              ),
                              prefixIconConstraints: BoxConstraints(
                                minWidth: 32,
                                minHeight: 30,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () => state.sendFriendRequest(
                          _usernameController.text.trim(),
                        ),
                        child: const Text('添加'),
                      ),
                    ],
                  ),
                  if (incoming.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.xl),
                    const SectionLabel(text: '待处理的好友申请'),
                    const SizedBox(height: 8),
                    PanelCard(
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: [
                          for (var i = 0; i < incoming.length; i++) ...[
                            if (i > 0) const Divider(height: 1),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                12,
                                8,
                                10,
                                8,
                              ),
                              child: Row(
                                children: [
                                  UserAvatar(
                                    userId: incoming[i].user.id,
                                    label: incoming[i].user.displayName,
                                    avatarVersion: incoming[i].user.avatar,
                                    size: 28,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      incoming[i].user.displayName,
                                      style: const TextStyle(
                                        fontSize: 12.5,
                                        height: 1.3,
                                      ),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () =>
                                        state.respondFriendRequest(
                                          incoming[i].id,
                                          accept: false,
                                        ),
                                    child: const Text('拒绝'),
                                  ),
                                  const SizedBox(width: 4),
                                  FilledButton(
                                    onPressed: () =>
                                        state.respondFriendRequest(
                                          incoming[i].id,
                                          accept: true,
                                        ),
                                    child: const Text('同意'),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  if (outgoing.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.xl),
                    const SectionLabel(text: '已发出的申请'),
                    const SizedBox(height: 8),
                    PanelCard(
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: [
                          for (var i = 0; i < outgoing.length; i++) ...[
                            if (i > 0) const Divider(height: 1),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 11,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      outgoing[i].user.displayName,
                                      style: TextStyle(
                                        color: context.palette.textSecondary,
                                        fontSize: 12.5,
                                        height: 1.3,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    '等待对方处理',
                                    style: TextStyle(
                                      color: context.palette.textMuted,
                                      fontSize: 11,
                                      height: 1.3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.xl),
                  SectionLabel(text: '好友列表'),
                  const SizedBox(height: 8),
                  if (state.friends.isEmpty)
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 18),
                      child: Text(
                        '还没有好友，输入用户名添加',
                        style: TextStyle(
                          color: context.palette.textMuted,
                          fontSize: 11.5,
                          height: 1.5,
                        ),
                      ),
                    )
                  else
                    Column(
                      // 这一处列表不要卡片：底色与外框都去掉，只留行间分隔线
                      children: [
                        for (final (i, friend) in state.friends.indexed) ...[
                          // 内收：左端对齐头像左边（行内左留白 12），
                          // 右端对齐删除图标右边（行内右留白 10 + 图标盒居中多出的 7）
                          if (i > 0)
                            const Divider(
                              height: 1,
                              indent: 12,
                              endIndent: 17,
                            ),
                          _FriendRow(
                            friend: friend,
                            onRemove: () async {
                              final confirmed = await showConfirmDialog(
                                context,
                                title: '删除好友',
                                message:
                                    '确定删除好友「${friend.user.displayName}」吗',
                                confirmText: '删除',
                              );
                              if (confirmed) {
                                await state.api?.removeFriend(
                                  friend.user.username,
                                );
                                await state.refreshFriends();
                              }
                            },
                          ),
                        ],
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 好友列表的一行：头像 + 昵称/状态 + 删除。
///
/// 单独抽出来是因为它要记自己的悬停态——删除按钮平时只露一个很淡的图标，
/// 悬停才变得明确，一列红字「删除」会把整页的注意力拉走。
class _FriendRow extends StatefulWidget {
  const _FriendRow({required this.friend, required this.onRemove});

  final Friend friend;
  final Future<void> Function() onRemove;

  @override
  State<_FriendRow> createState() => _FriendRowState();
}

class _FriendRowState extends State<_FriendRow> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final friend = widget.friend;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        color: _hovering ? context.palette.hover : Colors.transparent,
        padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
        child: Row(
          children: [
            UserAvatar(
              userId: friend.user.id,
              label: friend.user.displayName,
              avatarVersion: friend.user.avatar,
              size: 30,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                friend.user.displayName,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, height: 1.3),
              ),
            ),
            const SizedBox(width: 8),
            StatusDot(
              color: friend.online
                  ? context.palette.success
                  : context.palette.textMuted.withValues(alpha: 0.5),
              size: 5,
            ),
            const SizedBox(width: 6),
            Text(
              friend.online ? '在线' : '离线',
              style: TextStyle(
                fontSize: 11,
                height: 1.3,
                color: friend.online
                    ? context.palette.textSecondary
                    : context.palette.textMuted,
              ),
            ),
            const SizedBox(width: 10),
            AnimatedOpacity(
              duration: const Duration(milliseconds: 120),
              // 红色本身已经是「危险动作」的信号，平时压到 0.6 够看清但不抢戏
              opacity: _hovering ? 1 : 0.6,
              child: IconButton(
                tooltip: '删除好友',
                onPressed: () => widget.onRemove(),
                icon: Icon(
                  Icons.delete_outline_rounded,
                  size: 14,
                  color: context.palette.danger,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
