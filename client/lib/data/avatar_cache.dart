import 'package:flutter/foundation.dart';

import '../core/app_log.dart';

/// 头像字节的内存缓存。
///
/// 为什么要缓存、而不是让 `Image.network` 直接吃 URL：拉头像的接口需要登录，
/// 把令牌拼进 URL 交给图片组件既难管又会把令牌写进日志。这里用带鉴权的
/// [loader] 取一次字节，之后按 `<userId>:<version>` 命中缓存。
///
/// 版本号是服务端算出来的内容哈希，所以「同一个人换了头像」= 换了个 key，
/// 缓存天然不会串；同一个人反复进出房间也不会重复请求。
class AvatarCache extends ChangeNotifier {
  AvatarCache({required this.loader});

  /// 拉取某个版本的头像字节；失败返回 null（调用方退回首字头像）。
  final Future<Uint8List?> Function(int userId, String version) loader;

  final Map<String, Uint8List> _bytes = <String, Uint8List>{};
  final Set<String> _failed = <String>{};
  final Set<String> _inflight = <String>{};

  static String _key(int userId, String version) => '$userId:$version';

  /// 命中缓存就返回字节，否则返回 null（同时会触发一次后台拉取）。
  Uint8List? bytesFor(int userId, String? version) {
    if (version == null || version.isEmpty || userId <= 0) {
      return null;
    }
    return _bytes[_key(userId, version)];
  }

  /// 确保某个版本的头像正在被拉取（没有、没失败过、没在飞行中才会真的发请求）。
  ///
  /// 在 build 里直接调用是安全的：重复调用只是查几次集合，真正的工作只做一次。
  void ensure(int userId, String? version) {
    if (version == null || version.isEmpty || userId <= 0) {
      return;
    }
    final key = _key(userId, version);
    if (_bytes.containsKey(key) ||
        _failed.contains(key) ||
        _inflight.contains(key)) {
      return;
    }
    _inflight.add(key);
    loader(userId, version)
        .then((bytes) {
          _inflight.remove(key);
          if (bytes == null || bytes.isEmpty) {
            _failed.add(key);
            return;
          }
          _bytes[key] = bytes;
          notifyListeners();
        })
        .catchError((Object error) {
          // 头像拿不到不是致命错误：界面会退回首字头像
          AppLog.debug('拉取头像失败 $key：$error');
          _inflight.remove(key);
          _failed.add(key);
        });
  }

  /// 清空（退出登录 / 换服务器时调用）。
  void clear() {
    if (_bytes.isEmpty && _failed.isEmpty) {
      return;
    }
    _bytes.clear();
    _failed.clear();
    notifyListeners();
  }
}
