import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import 'common.dart';

/// 带真实头像的用户头像：有头像显示图片，否则退回「首字 + 渐变」。
///
/// 头像字节由 [AppState.avatars] 带着令牌拉回来并缓存，所以这里不需要
/// 把令牌拼进 URL 交给 `Image.network`；版本号变了（换了头像）会重新拉一次。
class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    required this.userId,
    required this.label,
    this.avatarVersion,
    this.size = 40,
    this.ring,
    this.dimmed = false,
  });

  final int userId;
  final String label;

  /// 账号资料里的 `avatar` 字段（内容哈希版本号）。
  final String? avatarVersion;

  final double size;
  final Color? ring;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final cache = context.read<AppState>().avatars;
    return AnimatedBuilder(
      animation: cache,
      builder: (context, _) {
        final bytes = cache.bytesFor(userId, avatarVersion);
        if (bytes == null) {
          // 在 build 里触发拉取是安全的：ensure 自身去重，重复调用只查几个集合
          cache.ensure(userId, avatarVersion);
        }
        return AvatarCircle(
          seed: userId,
          label: label,
          bytes: bytes,
          size: size,
          ring: ring,
          dimmed: dimmed,
        );
      },
    );
  }
}
