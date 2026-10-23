import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../core/app_theme.dart';
import '../core/l10n_ext.dart';
import '../data/models.dart';
import '../widgets/common.dart';

/// 首屏：连接服务器 + 登录。
class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key});

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  final _addressController = TextEditingController(text: '192.168.1.10:21077');
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscure = true;

  AppState? _state;

  /// 本地记住的凭据是否已经回填过（只回填一次，不覆盖用户正在输入的内容）。
  bool _prefilled = false;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    _state = state;
    state.addListener(_prefill);
    _prefill();
  }

  @override
  void dispose() {
    _state?.removeListener(_prefill);
    _addressController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// 回填上次用过的服务器地址 / 用户名 / 密码。
  ///
  /// 本地凭据是异步读出来的（[AppState.rememberedLoaded]），读完之前先不动输入框；
  /// 填过一次就摘掉监听，之后不再干扰用户输入。
  void _prefill() {
    if (_prefilled) {
      return;
    }
    final state = _state;
    if (state == null || !state.rememberedLoaded) {
      return;
    }
    _prefilled = true;
    state.removeListener(_prefill);

    final address = state.rememberedAddress;
    if (address != null && address.isNotEmpty) {
      _addressController.text = address;
    }
    final username = state.rememberedUsername;
    if (username != null && username.isNotEmpty) {
      _usernameController.text = username;
    }
    final password = state.rememberedPassword;
    if (password != null && password.isNotEmpty) {
      _passwordController.text = password;
    }
  }

  Future<void> _connect() async {
    final state = context.read<AppState>();
    await state.connectToServer(_addressController.text);
  }

  Future<void> _submit({required bool register}) async {
    final state = context.read<AppState>();
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.isEmpty || password.isEmpty) {
      return;
    }
    if (register) {
      await state.register(username: username, password: password);
    } else {
      await state.signIn(username: username, password: password);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final connected = state.isConnectedToServer;
    final info = state.serverInfo;
    final allowRegistration = info?.allowRegistration ?? false;
    final l10n = context.l10n;

    return Scaffold(
      backgroundColor: context.palette.background,
      body: Center(
        child: SingleChildScrollView(
          // 手机上左右要留边距：460 的封顶在 360dp 屏上等于贴边
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.page,
            vertical: AppSpacing.lg,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    BrandMark(size: 26),
                    SizedBox(width: 10),
                    Text(
                      l10n.connectTagline,
                      style: TextStyle(
                        color: context.palette.textMuted,
                        fontSize: 11.5,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                PanelCard(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SectionLabel(text: l10n.connectServerSection),
                      const SizedBox(height: AppSpacing.md),
                      TextField(
                        textAlignVertical: TextAlignVertical.center,
                        controller: _addressController,
                        enabled: !state.busy,
                        onSubmitted: (_) => _connect(),
                        decoration: InputDecoration(
                          hintText: l10n.connectAddressHint,
                          prefixIcon: const Icon(Icons.dns_rounded, size: 16),
                          suffixIcon: connected
                              ? Icon(
                                  Icons.check_circle,
                                  size: 16,
                                  color: context.palette.success,
                                )
                              : null,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      FilledButton(
                        onPressed: state.busy ? null : _connect,
                        child: Text(
                          connected ? l10n.connectReconnect : l10n.connectConnect,
                        ),
                      ),
                      if (info != null) ...[
                        const SizedBox(height: AppSpacing.md),
                        _ServerFacts(
                          info: info,
                          address: state.endpoint?.display ?? '',
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Opacity(
                  opacity: connected ? 1 : 0.5,
                  child: IgnorePointer(
                    ignoring: !connected,
                    child: PanelCard(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SectionLabel(text: l10n.connectAccountSection),
                          const SizedBox(height: AppSpacing.md),
                          TextField(
                            textAlignVertical: TextAlignVertical.center,
                            controller: _usernameController,
                            enabled: connected && !state.busy,
                            textInputAction: TextInputAction.next,
                            decoration: InputDecoration(
                              hintText: l10n.connectUsernameHint,
                              prefixIcon: Icon(
                                Icons.person_outline_rounded,
                                size: 16,
                              ),
                            ),
                          ),
                          const SizedBox(height: AppSpacing.md),
                          TextField(
                            textAlignVertical: TextAlignVertical.center,
                            controller: _passwordController,
                            enabled: connected && !state.busy,
                            obscureText: _obscure,
                            onSubmitted: (_) => _submit(register: false),
                            decoration: InputDecoration(
                              hintText: l10n.connectPasswordHint,
                              prefixIcon: const Icon(
                                Icons.lock_outline_rounded,
                                size: 16,
                              ),
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscure
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  size: 16,
                                ),
                                onPressed: () =>
                                    setState(() => _obscure = !_obscure),
                              ),
                            ),
                          ),
                          const SizedBox(height: AppSpacing.md),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton(
                                  onPressed: connected && !state.busy
                                      ? () => _submit(register: false)
                                      : null,
                                  child: Text(l10n.connectLogin),
                                ),
                              ),
                              // 注册入口只在服务器开放自注册时出现
                              if (allowRegistration) ...[
                                const SizedBox(width: AppSpacing.md),
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: connected && !state.busy
                                        ? () => _submit(register: true)
                                        : null,
                                    child: Text(l10n.connectRegister),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Text(
                            allowRegistration
                                ? l10n.connectOpenRegistration
                                : l10n.connectClosedRegistration,
                            style: TextStyle(
                              color: context.palette.textMuted,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (state.error != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  _Banner(
                    icon: Icons.error_outline_rounded,
                    color: context.palette.danger,
                    text: state.error!,
                  ),
                ] else if (state.notice != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  _Banner(
                    icon: Icons.info_outline_rounded,
                    color: context.palette.success,
                    text: state.notice!,
                  ),
                ],
                const SizedBox(height: AppSpacing.lg),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ServerFacts extends StatelessWidget {
  const _ServerFacts({required this.info, required this.address});

  final ServerDescriptor info;
  final String address;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Container(
      padding: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: context.palette.hairline)),
      ),
      child: Column(
        children: [
          _fact(context, l10n.connectFactAddress, address),
          _fact(context, l10n.connectFactName, info.name),
          _fact(
            context,
            l10n.connectFactVersion,
            l10n.connectProtocolLine(info.version, '${info.protocolVersion}'),
          ),
          _fact(
            context,
            l10n.connectRoomCapacity,
            l10n.connectRoomCapacityValue(info.roomCapacity, info.maxRoomCapacity),
          ),
          _fact(
            context,
            'STUN',
            info.iceServers.isEmpty
                ? l10n.connectIceNotProvided
                : info.iceServers.join(l10n.connectListSeparator),
          ),
        ],
      ),
    );
  }

  Widget _fact(BuildContext context, String label, String value) => Padding(
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
              height: 1.5,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: context.palette.textSecondary,
              fontSize: 11.5,
              height: 1.5,
            ),
          ),
        ),
      ],
    ),
  );
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: AppRadii.medium,
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: color, fontSize: 11.5, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}
