part of 'home_shell.dart';


class _ServerCard extends StatelessWidget {
  const _ServerCard();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = context.l10n;
    final endpoint = state.endpoint;
    final info = state.serverInfo;
    final connected = state.isConnectedToServer;

    return PanelCard(
      color: context.palette.panel,
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: context.palette.accent.withValues(alpha: 0.14),
              borderRadius: AppRadii.small,
            ),
            child: Icon(
              Icons.cloud_rounded,
              size: 14,
              color: context.palette.accent,
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  info?.name ?? l10n.settingsServerFallbackName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    height: 1.35,
                  ),
                ),
                Text(
                  endpoint?.display ?? l10n.settingsServerNotConfigured,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.palette.textMuted,
                    fontSize: 10.5,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          StatusDot(
            color: connected ? context.palette.success : context.palette.textMuted,
            size: 6,
            glow: connected,
          ),
        ],
      ),
    );
  }
}

// --------------------------------------------------------------------------- //
// 中栏
// --------------------------------------------------------------------------- //

// --------------------------------------------------------------------------- //
// 设置
// --------------------------------------------------------------------------- //
class _SettingsPane extends StatelessWidget {
  const _SettingsPane();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = context.l10n;
    final session = state.session;
    final info = state.serverInfo;
    final library = state.music;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: AppSizes.pageHeader,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
          child: Row(
            children: [
              Text(l10n.settingsTitle, style: AppText.pageTitle),
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
        const _AccountCard(),
        const SizedBox(height: AppSpacing.md),
        PanelCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionLabel(text: l10n.settingsAudioDevices),
              const SizedBox(height: AppSpacing.sm),
              _DeviceRow(
                media: state.media,
                input: true,
                onSwitched: state.reapplyMicVolume,
              ),
              const SizedBox(height: AppSpacing.sm),
              _DeviceRow(media: state.media, input: false),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        const _MicCheckCard(),
        const SizedBox(height: AppSpacing.md),
        const _VolumeCard(),
        const SizedBox(height: AppSpacing.md),
        const _VoiceProfileCard(),
        const SizedBox(height: AppSpacing.md),
        MusicPluginCard(
          library: library,
          syncing: state.musicSyncing,
          subscriptionUrls: state.musicSubscriptionUrls,
          onRefreshSubscription: () => state.refreshMusicPlugins(force: true),
        ),
        const SizedBox(height: AppSpacing.md),
        const _LogCard(),
        const SizedBox(height: AppSpacing.md),
        PanelCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: AppSpacing.sm),
              _kv(
                context,
                l10n.shellServerAddress,
                state.endpoint?.display ?? l10n.shellNotConnected,
              ),
              _kv(context, l10n.shellServerName, info?.name ?? '—'),
              _kv(
                context,
                l10n.connectFactVersion,
                info == null
                    ? '—'
                    : l10n.connectProtocolLine(
                        info.version,
                        '${info.protocolVersion}',
                      ),
              ),
              _kv(
                context,
                l10n.settingsIceServers,
                info == null || info.iceServers.isEmpty
                    ? '—'
                    : info.iceServers.join(l10n.connectListSeparator),
              ),
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton.icon(
                onPressed: () => showDiagnosticsDialog(context),
                icon: const Icon(Icons.health_and_safety_rounded, size: 16),
                label: Text(l10n.settingsRunDiagnostics),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        PanelCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionLabel(text: l10n.settingsCurrentConnection),
              const SizedBox(height: AppSpacing.sm),
              if (session == null || !session.phase.isActive)
                Text(
                  l10n.settingsNotInRoom,
                  style: TextStyle(color: context.palette.textMuted, fontSize: 12),
                )
              else ...[
                _kv(
                  context,
                  l10n.callRoomFallbackName,
                  l10n.settingsRoomValue(
                    session.room?.name ?? '',
                    session.room?.roomId ?? '',
                  ),
                ),
                _kv(
                  context,
                  l10n.shellDirectConnected,
                  l10n.shellDirectConnectedValue(
                    session.connectedPeerCount,
                    session.peerCount,
                  ),
                ),
                _kv(
                  context,
                  l10n.settingsUplinkRate,
                  formatKbps(session.stats.outgoingKbps),
                ),
                _kv(
                  context,
                  l10n.settingsDownlinkRate,
                  formatKbps(session.stats.incomingKbps),
                ),
                if (session.hasPunchFailure)
                  Padding(
                    padding: EdgeInsets.only(top: AppSpacing.sm),
                    child: Text(
                      l10n.shellPunchFailure,
                      style: TextStyle(
                        color: context.palette.warning,
                        fontSize: 11,
                        height: 1.6,
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
        // 手机上退出登录放在设置页最底部：桌面在左栏页脚有常驻入口，手机没有左栏，
        // 危险动作放到底部也更符合「翻到底才点」的习惯
        if (useCompactLayout(context)) ...[
          const SizedBox(height: AppSpacing.md),
          PanelCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionLabel(text: l10n.connectAccountSection),
                const SizedBox(height: AppSpacing.sm),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final confirmed = await showConfirmDialog(
                        context,
                        title: l10n.shellSignOut,
                        message: l10n.settingsLogoutMessage,
                        confirmText: l10n.shellSignOut,
                      );
                      if (confirmed && context.mounted) {
                        await context.read<AppState>().logout();
                      }
                    },
                    icon: const Icon(Icons.logout_rounded, size: 16),
                    label: Text(l10n.shellSignOut),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: context.palette.danger,
                      side: BorderSide(color: context.palette.hairline),
                      minimumSize: const Size.fromHeight(AppSizes.control),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  l10n.settingsLogoutHint,
                  style: TextStyle(
                    color: context.palette.textMuted,
                    fontSize: 11,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 设置页的账号卡片：改昵称（通话中立刻同步给同房间的人）+ 改密码。
class _AccountCard extends StatefulWidget {
  const _AccountCard();

  @override
  State<_AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends State<_AccountCard> {
  final TextEditingController _name = TextEditingController();
  final AvatarPicker _picker = const AvatarPicker();
  String? _nameError;
  String? _avatarError;
  bool _busy = false;
  bool _avatarBusy = false;

  /// 上次挑头像用的目录；再点「更换头像」时从这里开始，不用每次从头翻。
  String? _avatarDir;

  /// 已经同步进输入框的昵称，避免用户正在输入时被重建覆盖掉
  String? _synced;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    setState(() {
      _busy = true;
      _nameError = null;
    });
    try {
      await state.updateDisplayName(_name.text);
      if (!mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.settingsDisplayNameUpdated)),
      );
    } on ApiException catch (failure) {
      if (mounted) {
        setState(() => _nameError = failure.message);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  /// 选图 → 本地缩放 → 上传。用户取消时静默返回。
  Future<void> _uploadAvatar() async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    // 选图分两端：桌面走应用内选图框（系统文件框在无边框窗口上会把主窗口
    // 压住又禁用），手机走系统相册（安卓分区存储下列不出照片目录），
    // 见 pickImagePath 的注释。
    final path = await pickImagePath(
      context,
      title: l10n.imagePickerAvatarTitle,
      confirmLabel: l10n.imagePickerAvatarConfirm,
      initialDirectory: _avatarDir,
    );
    if (path == null || !mounted) {
      return; // 用户取消
    }
    _avatarDir = File(path).parent.path;
    setState(() {
      _avatarBusy = true;
      _avatarError = null;
    });
    try {
      final picked = await _picker.fromPath(path);
      if (!mounted) {
        return;
      }
      if (picked.error != null) {
        setState(() => _avatarError = picked.error);
        return;
      }
      final bytes = picked.bytes;
      if (bytes == null) {
        return;
      }
      await state.uploadAvatar(bytes);
      if (!mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.settingsAvatarUpdated)),
      );
    } on ApiException catch (failure) {
      if (mounted) {
        setState(() => _avatarError = failure.message);
      }
    } finally {
      if (mounted) {
        setState(() => _avatarBusy = false);
      }
    }
  }

  Future<void> _removeAvatar() async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    setState(() {
      _avatarBusy = true;
      _avatarError = null;
    });
    try {
      await state.removeAvatar();
      if (!mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.settingsAvatarRemoved)),
      );
    } on ApiException catch (failure) {
      if (mounted) {
        setState(() => _avatarError = failure.message);
      }
    } finally {
      if (mounted) {
        setState(() => _avatarBusy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final user = state.user;
    final l10n = context.l10n;
    if (user == null) {
      return const SizedBox.shrink();
    }
    // 昵称也可能在别处被改（比如另一台设备），这里跟随一次
    if (_synced != user.displayName && !_busy) {
      _synced = user.displayName;
      _name.text = user.displayName;
    }

    return PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionLabel(text: l10n.connectAccountSection),
          const SizedBox(height: AppSpacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 96,
                child: Column(
                  children: [
                    UserAvatar(
                      userId: user.id,
                      label: user.displayName,
                      avatarVersion: user.avatar,
                      size: 64,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextButton(
                      onPressed: _avatarBusy ? null : _uploadAvatar,
                      child: Text(
                        user.avatar == null
                            ? l10n.settingsAvatarUpload
                            : l10n.settingsAvatarChange,
                      ),
                    ),
                    if (user.avatar != null)
                      TextButton(
                        onPressed: _avatarBusy ? null : _removeAvatar,
                        child: Text(l10n.settingsAvatarRemove),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _kv(context, l10n.settingsUsername, user.username),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        SizedBox(
                          width: 84,
                          child: Text(
                            l10n.settingsDisplayName,
                            style: TextStyle(
                              color: context.palette.textMuted,
                              fontSize: 11.5,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 320),
                              child: SizedBox(
                                height: AppSizes.control,
                                child: TextField(
                                  textAlignVertical: TextAlignVertical.center,
                                  controller: _name,
                                  maxLength: 48,
                                  style: const TextStyle(fontSize: 12.5),
                                  cursorHeight: 15,
                                  decoration: InputDecoration(
                                    isDense: true,
                                    counterText: '',
                                    hintText: l10n.settingsDisplayNameHint,
                                  ),
                                  onSubmitted: (_) {
                                    if (!_busy) {
                                      _save();
                                    }
                                  },
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_nameError != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        _nameError!,
                        style: TextStyle(
                          color: context.palette.danger,
                          fontSize: 12,
                        ),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.md),
                    Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.sm,
                      children: [
                        FilledButton(
                          onPressed: _busy ? null : _save,
                          child: Text(
                            _busy
                                ? l10n.settingsSaving
                                : l10n.settingsSaveDisplayName,
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => showChangePasswordDialog(context),
                          icon: const Icon(Icons.lock_reset_rounded, size: 16),
                          label: Text(l10n.settingsChangePassword),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_avatarError != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              _avatarError!,
              style: TextStyle(color: context.palette.danger, fontSize: 12),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          Text(
            l10n.settingsAvatarHint,
            style: TextStyle(
              color: context.palette.textMuted,
              fontSize: 11,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// 设置页的麦克风自检：是否有效 + 实时电平，不进房间也能试麦。
///
/// 「试麦」就是让媒体层单独采集一次麦克风：房间外没有 PeerConnection，
/// 媒体层会用一条本地回环连接产出电平统计，所以不需要服务器也不需要对方在线。
/// 三条音量通道里的两条「本机通道」：麦克风输出音量与音乐播放音量。
///
/// 成员音量在右栏成员列表里（每人一条）。三者互不影响：音乐音量只关本机播放器，
/// 麦克风音量改的是系统录音设备的主音量（对方听到的大小）。
class _VolumeCard extends StatelessWidget {
  const _VolumeCard();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = context.l10n;
    return PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionLabel(text: l10n.settingsVolume),
          const SizedBox(height: AppSpacing.sm),
          AnimatedBuilder(
            animation: Listenable.merge(<Listenable>[
              state.micVolumeController,
              state.musicPlayer,
            ]),
            builder: (context, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                VolumeSliderTile(
                  label: l10n.settingsMicVolume,
                  value: state.micVolume,
                  max: 100,
                  icon: Icons.mic_rounded,
                  subtitle: l10n.settingsMicVolumeHint,
                  notice: state.micVolumeSupported
                      ? null
                      : (state.micVolumeNotice ??
                            l10n.settingsMicVolumeUnsupported),
                  sliderKey: const Key('mic-volume-slider'),
                  onChanged: state.setMicVolume,
                ),
                const SizedBox(height: AppSpacing.md),
                VolumeSliderTile(
                  label: l10n.settingsMusicVolume,
                  value: state.musicVolume,
                  max: 100,
                  icon: Icons.music_note_rounded,
                  subtitle: l10n.settingsMusicVolumeHint,
                  sliderKey: const Key('music-volume-slider'),
                  onChanged: state.setMusicVolume,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 语音处理档位：采集侧的降噪 / 自动增益 / 高通，加上行 Opus 码率一起换。
///
/// 为什么做成用户可选：libwebrtc 的降噪只给了「开 / 关」，没有强度档
/// （见 `voice_profile.dart` 里的说明）。默认档已经按「保哼唱、不忽大忽小」调过，
/// 但每个人的房间和麦克风差别很大——安静的独居房与开着的风扇/键盘，不该共用一套参数。
/// 这里只影响自己上行，别人听不听得到、怎么听，都不受这张卡片影响。
class _VoiceProfileCard extends StatelessWidget {
  const _VoiceProfileCard();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = context.l10n;
    final current = state.voiceProfile;
    return PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionLabel(text: l10n.settingsVoiceProfile),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              for (final profile in VoiceProfile.values) ...[
                if (profile != VoiceProfile.values.first)
                  const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: _VoiceProfileTile(
                    profile: profile,
                    selected: profile == current,
                    onTap: () => state.setVoiceProfile(profile),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            l10n.settingsVoiceProfileHint,
            style: TextStyle(
              color: context.palette.textMuted,
              fontSize: 11,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            current.detail,
            style: TextStyle(
              color: context.palette.textSecondary,
              fontSize: 11,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// 档位卡片：选中的用强调色描边 + 淡底，未选中用面板底色，鼠标移上去描边微亮
/// （与共享策略卡片、源选择卡片同一套视觉语言）。
class _VoiceProfileTile extends StatefulWidget {
  const _VoiceProfileTile({
    required this.profile,
    required this.selected,
    required this.onTap,
  });

  final VoiceProfile profile;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_VoiceProfileTile> createState() => _VoiceProfileTileState();
}

class _VoiceProfileTileState extends State<_VoiceProfileTile> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        // 测试按档位点选时用这个 key，别按坐标或文案
        key: Key('voice-profile-${widget.profile.storageId}'),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
          decoration: BoxDecoration(
            color: selected
                ? context.palette.accentSoft
                : context.palette.panelSubtle,
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
                widget.profile.label,
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
                widget.profile.scene,
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

class _MicCheckCard extends StatefulWidget {
  const _MicCheckCard();

  @override
  State<_MicCheckCard> createState() => _MicCheckCardState();
}

class _MicCheckCardState extends State<_MicCheckCard> {
  bool _busy = false;

  Future<void> _toggle() async {
    final state = context.read<AppState>();
    final capturing = state.media.micLevel.value.capturing;
    setState(() => _busy = true);
    try {
      if (capturing) {
        await state.media.stopLocalAudio();
      } else {
        // 用设置页当前选中的麦克风试麦（空值即跟随系统默认设备）
        await state.media.startLocalAudio(
          deviceId: state.media.activeAudioInputId,
        );
      }
    } on MediaException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = context.l10n;
    final inCall = state.session?.phase.isActive ?? false;

    return PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionLabel(text: l10n.settingsMicrophone),
          const SizedBox(height: AppSpacing.sm),
          ValueListenableBuilder<MicLevel>(
            valueListenable: state.media.micLevel,
            builder: (context, mic, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MicStatusLine(level: mic),
                const SizedBox(height: 10),
                // 没在采集时不画电平条：一条灰条只会多出一段看不懂的空白
                if (mic.capturing) ...[
                  MicLevelBar(
                    level: mic.display,
                    enabled: mic.healthy && !mic.muted,
                    speaking: mic.speaking,
                    height: 8,
                  ),
                  const SizedBox(height: 10),
                ],
                Text(
                  mic.healthy
                      ? l10n.settingsMicCheckHealthyHint
                      : l10n.settingsMicCheckIdleHint,
                  style: TextStyle(
                    color: context.palette.textMuted,
                    fontSize: 11,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                if (inCall)
                  Text(
                    l10n.settingsMicCheckInCall,
                    style: TextStyle(color: context.palette.textMuted, fontSize: 11),
                  )
                else
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _toggle,
                    icon: Icon(
                      mic.capturing ? Icons.stop_rounded : Icons.mic_rounded,
                      size: 16,
                    ),
                    label: Text(
                      mic.capturing
                          ? l10n.settingsMicCheckStop
                          : l10n.settingsMicCheckStart,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 运行日志：闪退这类问题只能靠日志定位，这里把本次运行的文件路径摆出来，
/// 并提供「打开日志文件夹」——出问题的机器上用户要能把文件发出来。
class _LogCard extends StatelessWidget {
  const _LogCard();

  @override
  Widget build(BuildContext context) {
    final path = AppLog.filePath;
    final l10n = context.l10n;
    return PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionLabel(text: l10n.settingsLogs),
          const SizedBox(height: AppSpacing.sm),
          Text(
            path ?? l10n.settingsLogsNotWritten,
            style: TextStyle(
              color: context.palette.textMuted,
              fontSize: 11,
              height: 1.5,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton.icon(
            onPressed: path == null ? null : () => _openDirectory(context, path),
            icon: const Icon(Icons.folder_open_rounded, size: 16),
            label: Text(l10n.settingsOpenLogFolder),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            l10n.settingsLogsHint,
            style: TextStyle(
              color: context.palette.textMuted,
              fontSize: 11,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openDirectory(BuildContext context, String filePath) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    final directory = File(filePath).parent.path;
    try {
      if (isDesktopPlatform) {
        await Process.run('explorer.exe', <String>[directory]);
      } else {
        // 手机没有「打开所在文件夹」这个概念：把路径本身给用户看
        messenger.showSnackBar(SnackBar(content: Text(filePath)));
      }
    } on Object catch (error) {
      AppLog.warn('打开日志目录失败', error: error);
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.settingsOpenLogFailed(directory))),
      );
    }
  }
}

/// 音频设备选择：麦克风（输入）与扬声器（输出）。
///
/// 列表第一项是「系统默认设备」（空串哨兵），选中表示不指定、跟随系统。
/// 输入设备在桌面端要走 `sourceId` 约束，输出设备要走原生
/// `selectAudioOutput`——两者都在媒体层落地，这里只管选。
class _DeviceRow extends StatefulWidget {
  const _DeviceRow({
    required this.media,
    required this.input,
    this.onSwitched,
  });

  final MediaEngine media;
  final bool input;

  /// 设备切换成功后的回调（麦克风音量要按新设备重新压一次）。
  final VoidCallback? onSwitched;

  @override
  State<_DeviceRow> createState() => _DeviceRowState();
}

class _DeviceRowState extends State<_DeviceRow> {
  /// 「系统默认设备」的哨兵值：空串不会与任何真实 deviceId 冲突。
  static const String _systemDefault = '';

  List<AudioDevice> _devices = const <AudioDevice>[];
  bool _loading = true;
  bool _switching = false;

  @override
  void initState() {
    super.initState();
    // 耳机插拔等设备变化时自动刷新（媒体层订阅系统事件后自增）
    widget.media.audioDevicesVersion.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.media.audioDevicesVersion.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    // 首次加载时 _loading 已是初始值 true，不必再 setState（initState 期间也少一次）
    if (mounted && !_loading) {
      setState(() => _loading = true);
    }
    final devices = await widget.media.audioDevices(input: widget.input);
    if (!mounted) {
      return;
    }
    setState(() {
      _devices = devices;
      _loading = false;
    });
  }

  Future<void> _apply(String deviceId) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _switching = true);
    try {
      if (widget.input) {
        await widget.media.switchAudioInput(deviceId);
      } else {
        await widget.media.switchAudioOutput(deviceId);
      }
      // 新设备有它自己的系统音量：把本机记住的值再压一次
      widget.onSwitched?.call();
    } on MediaException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) {
        setState(() => _switching = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final current = widget.input
        ? widget.media.activeAudioInputId
        : widget.media.activeAudioOutputId;
    // 选中的设备被拔掉（或还没采集）时回落到「系统默认设备」，别让下拉空白
    final selected = _devices.any((device) => device.deviceId == current)
        ? current!
        : _systemDefault;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 84,
              child: Text(
                widget.input ? l10n.settingsMicrophone : l10n.settingsSpeaker,
                style: TextStyle(
                  color: context.palette.textMuted,
                  fontSize: 11.5,
                ),
              ),
            ),
            Expanded(
              child: SizedBox(
                height: AppSizes.control,
                child: DropdownButtonFormField<String>(
                  initialValue: selected,
                  isDense: true,
                  decoration: const InputDecoration(),
                  items: <DropdownMenuItem<String>>[
                    DropdownMenuItem<String>(
                      value: _systemDefault,
                      child: Text(
                        l10n.settingsSystemDefaultDevice,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    for (final device in _devices)
                      DropdownMenuItem<String>(
                        value: device.deviceId,
                        child: Text(
                          device.displayName,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                  ],
                  onChanged: _switching
                      ? null
                      : (value) {
                          if (value != null) {
                            _apply(value);
                          }
                        },
                ),
              ),
            ),
          ],
        ),
        if (!_loading && _devices.isEmpty) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              const SizedBox(width: 84),
              Icon(
                Icons.warning_amber_rounded,
                size: 14,
                color: context.palette.warning,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.settingsNoDevices,
                  style: TextStyle(color: context.palette.textMuted, fontSize: 11),
                ),
              ),
              TextButton(
                onPressed: _load,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: Text(l10n.settingsRedetect),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

Widget _kv(BuildContext context, String label, String value) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 3),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 84,
        child: Text(
          label,
          style: TextStyle(
            color: context.palette.textMuted,
            fontSize: 11.5,
            height: 1.6,
          ),
        ),
      ),
      Expanded(
        child: Text(
          value,
          style: TextStyle(
            color: context.palette.textSecondary,
            fontSize: 12,
            height: 1.5,
          ),
        ),
      ),
    ],
  ),
);

// --------------------------------------------------------------------------- //
// 右栏
// --------------------------------------------------------------------------- //
