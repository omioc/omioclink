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
        MusicPluginSettingsCard(
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


// --------------------------------------------------------------------------- //
// 音乐插件（MusicFree）
// --------------------------------------------------------------------------- //
/// 设置页的「音乐插件」卡片：订阅同步 + 插件启用/排序/卸载/配置 + 音质。
///
/// 数据全部来自 [MusicFreeLibrary]；订阅地址由服务器下发（`AppState`），
/// 这里**不发请求**，只调 [onRefreshSubscription]。
class MusicPluginSettingsCard extends StatefulWidget {
  const MusicPluginSettingsCard({
    super.key,
    required this.library,
    this.syncing = false,
    this.subscriptionUrls = const <String>[],
    this.onRefreshSubscription,
  });

  final MusicFreeLibrary library;

  /// `AppState.musicSyncing`：订阅同步/更新全部进行中。
  final bool syncing;

  /// 服务器下发的订阅地址（只用于展示与空态提示）。
  final List<String> subscriptionUrls;

  /// 刷新订阅（接到 `AppState.refreshMusicPlugins(force: true)`）。
  final Future<void> Function()? onRefreshSubscription;


  @override
  State<MusicPluginSettingsCard> createState() =>
      _MusicPluginSettingsCardState();
}

class _MusicPluginSettingsCardState extends State<MusicPluginSettingsCard> {
  MusicFreeLibrary get library => widget.library;

  bool get _busy => widget.syncing || library.syncing;

  // 刻意不在 initState 里自动装载插件：装载要起 worker、把插件源码装进 QuickJS，
  // 是一次实打实的 CPU/IO 活（字节码缓存之后快了很多，但仍然不该在打开设置页时
  // 偷偷跑一遍）。装载只由用户显式点「刷新订阅」触发，可预期、可取消。

  @override
  void initState() {
    super.initState();
    // 「刷新订阅」要先把订阅清单摆给用户选，再只装选中的那些。弹框需要
    // BuildContext，所以由这张卡片挂到 library 上（设置页是唯一入口）。
    library.pickSubscriptionEntries = _pickEntries;
  }

  @override
  void dispose() {
    library.pickSubscriptionEntries = null;
    super.dispose();
  }

  Future<Set<String>?> _pickEntries(
    List<MusicFreeSubscriptionEntry> entries,
    Set<String> preselected,
  ) {
    return showPluginPickerDialog(
      context,
      entries: entries,
      preselected: preselected,
    );
  }

  Future<void> _refresh() async {
    final action = widget.onRefreshSubscription;
    if (action == null) {
      return;
    }
    await action();
  }

  Future<void> _confirmUninstall(MusicFreePlugin plugin) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.settingsPluginUninstallTitle),
        content: Text(
          l10n.settingsPluginUninstallMessage(plugin.platform),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.palette.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.settingsPluginUninstall),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await library.uninstallPlugin(plugin.hash);
    }
  }

  /// 插件的用户自定义变量（MusicFree 的 `IUserVariable`）。
  Future<void> _editVariables(MusicFreePlugin plugin) async {
    final l10n = context.l10n;
    final current = library.userVariablesOf(plugin.platform);
    final controllers = <String, TextEditingController>{
      for (final variable in plugin.userVariables)
        variable.key: TextEditingController(text: current[variable.key] ?? ''),
    };
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.settingsPluginConfigure(plugin.platform)),
        content: SizedBox(
          // 手机弹窗可用宽只有屏宽减去边距：420 会被压扁，按可用宽封顶
          width: MediaQuery.sizeOf(context).width > 500
              ? 420
              : MediaQuery.sizeOf(context).width - 96,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final variable in plugin.userVariables) ...[
                  Text(
                    variable.name.isEmpty ? variable.key : variable.name,
                    style: TextStyle(
                      color: context.palette.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  if (variable.hint.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        variable.hint,
                        style: TextStyle(
                          color: context.palette.textMuted,
                          fontSize: 11,
                          height: 1.4,
                        ),
                      ),
                    ),
                  const SizedBox(height: 4),
                  TextField(
                    textAlignVertical: TextAlignVertical.center,
                    controller: controllers[variable.key],
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: variable.key,
                    ),
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.commonSave),
          ),
        ],
      ),
    );
    if (saved == true) {
      await library.savePluginVariables(plugin.hash, <String, String>{
        for (final variable in plugin.userVariables)
          variable.key: controllers[variable.key]?.text.trim() ?? '',
      });
    }
    for (final controller in controllers.values) {
      controller.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: library,
      builder: (context, _) {
        final l10n = context.l10n;
        final plugins = library.plugins;
        return PanelCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionLabel(
                text: l10n.settingsMusicPlugins,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton.icon(
                      onPressed: _busy || widget.onRefreshSubscription == null
                          ? null
                          : _refresh,
                      icon: _busy
                          ? const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.sync, size: 16),
                      // 装载期间把文案也换掉：只把按钮变灰不够明显，
                      // 用户会以为「点了没反应」，然后继续点
                      label: Text(
                        _busy
                            ? l10n.settingsPluginsLoading
                            : l10n.settingsPluginsRefreshSubscription,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    TextButton(
                      onPressed: _busy || plugins.isEmpty
                          ? null
                          : () => unawaited(library.updateAllPlugins()),
                      child: Text(l10n.settingsPluginsUpdateAll),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              _kv(
                context,
                l10n.pluginWord,
                plugins.isEmpty
                    ? l10n.settingsPluginsNone
                    : l10n.settingsPluginsCount(
                        plugins.length,
                        library.enabledPlugins.length,
                      ),
              ),
              _kv(
                context,
                l10n.settingsSubscriptionUrls,
                widget.subscriptionUrls.isEmpty
                    ? l10n.settingsSubscriptionNotProvided
                    : widget.subscriptionUrls.join(l10n.connectListSeparator),
              ),
              _qualityRow(),
              if (library.syncMessage != null)
                _hintText(library.syncMessage!, context.palette.textMuted),
              if (library.syncError != null)
                _hintText(
                  l10n.settingsPluginsSyncFailed(library.syncError!),
                  context.palette.danger,
                ),
              const SizedBox(height: AppSpacing.sm),
              if (plugins.isEmpty)
                _emptyHint()
              else
                for (var i = 0; i < plugins.length; i += 1)
                  _pluginBlock(plugins[i], i, plugins.length),
              const SizedBox(height: AppSpacing.sm),
              Text(
                l10n.settingsPluginsHint(MusicFreePlugins.defaultSelectionSize),
                style: TextStyle(
                  color: context.palette.textMuted,
                  fontSize: 11,
                  height: 1.5,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _qualityRow() {
    final l10n = context.l10n;
    return Row(
      children: [
        SizedBox(
          width: 84,
          child: Text(
            l10n.settingsQuality,
            style: TextStyle(color: context.palette.textMuted, fontSize: 11),
          ),
        ),
        DropdownButton<MusicFreeQuality>(
          value: library.quality,
          isDense: true,
          underline: const SizedBox.shrink(),
          style: TextStyle(color: context.palette.textSecondary, fontSize: 12),
          items: [
            for (final quality in MusicFreeQuality.values)
              DropdownMenuItem<MusicFreeQuality>(
                value: quality,
                child: Text(quality.label),
              ),
          ],
          onChanged: (next) {
            if (next != null) {
              unawaited(library.setQuality(next));
            }
          },
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            l10n.settingsQualityHint,
            style: TextStyle(color: context.palette.textMuted, fontSize: 11),
          ),
        ),
      ],
    );
  }

  Widget _emptyHint() {
    final l10n = context.l10n;
    // 两种空态各写一句完整的句子：把「前缀 + 后缀」拼起来在日 / 韩里语序不成立
    final message = widget.subscriptionUrls.isEmpty
        ? l10n.settingsPluginsNoSubscription
        : l10n.settingsPluginsEmptyHint;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          Icon(
            Icons.extension_outlined,
            size: 16,
            color: context.palette.textMuted,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: context.palette.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pluginBlock(MusicFreePlugin plugin, int index, int total) {
    final l10n = context.l10n;
    final source = _sourceOf(plugin);
    final details = <String>[
      plugin.subtitle,
      if (source.isNotEmpty) source,
      l10n.settingsPluginMethodsCount(plugin.supportedMethods.length),
    ].join(' · ');
    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.xs),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: context.palette.panelSubtle.withValues(alpha: 0.35),
        borderRadius: AppRadii.small,
        border: Border.all(color: context.palette.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            plugin.platform,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: context.palette.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (!plugin.enabled) ...[
                          const SizedBox(width: 6),
                          Text(
                            l10n.settingsPluginDisabled,
                            style: TextStyle(
                              color: context.palette.warning,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      details,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.palette.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              // 手机上这一行固定宽度太贵：把两个排序按钮收成 32dp 的紧凑点击区
              IconButton(
                onPressed: _busy || index <= 0
                    ? null
                    : () => unawaited(library.movePlugin(plugin.hash, -1)),
                iconSize: 16,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                tooltip: l10n.settingsPluginMoveUp,
                icon: const Icon(Icons.arrow_upward),
              ),
              IconButton(
                onPressed: _busy || index >= total - 1
                    ? null
                    : () => unawaited(library.movePlugin(plugin.hash, 1)),
                iconSize: 16,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                tooltip: l10n.settingsPluginMoveDown,
                icon: const Icon(Icons.arrow_downward),
              ),
              if (plugin.userVariables.isNotEmpty)
                TextButton(
                  onPressed: _busy ? null : () => unawaited(_editVariables(plugin)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                  ),
                  child: Text(
                    l10n.settingsPluginConfigureAction,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              TextButton(
                onPressed: _busy ? null : () => unawaited(_confirmUninstall(plugin)),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                ),
                child: Text(
                  l10n.settingsPluginUninstall,
                  style: TextStyle(fontSize: 11, color: context.palette.danger),
                ),
              ),
              Switch(
                value: plugin.enabled,
                onChanged: _busy
                    ? null
                    : (next) => unawaited(
                        library.setPluginEnabled(plugin.hash, next),
                      ),
              ),
            ],
          ),
          if (plugin.loadError != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                l10n.settingsPluginLoadFailed(plugin.loadError!),
                style: TextStyle(color: context.palette.danger, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  /// 插件来源只显示域名，完整 URL 太长。
  String _sourceOf(MusicFreePlugin plugin) {
    final url = plugin.srcUrl.trim();
    if (url.isEmpty) {
      return context.l10n.settingsPluginLocalInstall;
    }
    return Uri.tryParse(url)?.host ?? url;
  }

  Widget _hintText(String text, Color color) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 11, height: 1.5),
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
