import 'dart:ffi';
import 'dart:io';

import '../core/app_log.dart';

// ---------------------------------------------------------------------------
// Core Audio 的常量与 GUID（照抄 Windows SDK，别自己推）
// ---------------------------------------------------------------------------

/// `CLSID_MMDeviceEnumerator`：Core Audio 的设备枚举器。
const String _clsidMmDeviceEnumerator = 'BCDE0395-E52F-467C-8E3D-C4579291692E';

/// `IID_IMMDeviceEnumerator`。
const String _iidMmDeviceEnumerator = 'A95664D2-9614-4F35-A746-DE8DB63617E6';

/// `CLSID_CPolicyConfigClient`：系统音频策略客户端（改「默认设备 / 默认通信设备」用）。
const String _clsidPolicyConfigClient = '870AF99C-171D-4F9E-AF0D-E63DF40C2BC9';

/// `IID_IPolicyConfig`：`SetDefaultEndpoint(deviceId, role)` 所在的接口。
///
/// 微软没有公开这个接口，但系统自带的「声音设置」就是通过它改默认设备的，
/// Windows 7 至今行为稳定；失败时下面的封装一律返回 false，不会抛出。
const String _iidPolicyConfig = 'F8679F50-850A-41CF-9C72-430F290290C8';

/// `CLSCTX_ALL`（INPROC_SERVER | INPROC_HANDLER | LOCAL_SERVER | REMOTE_SERVER）。
const int _clsctxAll = 23;

/// `EDataFlow::eRender`：播放设备。
const int _eRender = 0;

/// `ERole`：0 = 默认设备（媒体角色，音乐走它），2 = 默认通信设备（VoIP 走它）。
const int _eConsole = 0;
const int _eCommunications = 2;

/// vtable 索引。0..2 被 `IUnknown`（QueryInterface/AddRef/Release）占掉。
///
/// `IMMDeviceEnumerator`：3 = EnumAudioEndpoints，4 = GetDefaultAudioEndpoint。
/// `IMMDevice`：3 = Activate，4 = OpenPropertyStore，5 = GetId。
/// `IPolicyConfig`：3..12 是格式/周期/属性那套，13 = SetDefaultEndpoint。
const int _vtRelease = 2;
const int _vtGetDefaultAudioEndpoint = 4;
const int _vtGetId = 5;
const int _vtSetDefaultEndpoint = 13;

/// `RPC_E_CHANGED_MODE`：本线程已被初始化成别的套间，视同初始化成功继续用。
final int _rpcChangedMode = 0x80010106.toSigned(32);

/// 把 HRESULT 写成 `0x80004005` 这种形式，方便对着文档和日志查。
String _hexHr(int hr) =>
    '0x${hr.toUnsigned(32).toRadixString(16).toUpperCase().padLeft(8, '0')}';

/// 当前平台是否支持「把语音落到指定设备」这套 Core Audio 查询（只有 Windows 有）。
///
/// 判断放在这里而不是调用方：调用方不该为了一个平台判断去引 `dart:io`。
bool get windowsOutputRoutingAvailable => Platform.isWindows;

/// 「跟随系统」时语音该落到哪只设备：显式选择优先，否则用系统默认设备。
///
/// 这也是设置页第一项（「系统默认设备」）的语义：**和音乐同一只**，而不是
/// Windows 那套单独给 VoIP 用的「默认通信设备」。
String voiceOutputTarget({
  required String chosen,
  required String? mediaDefault,
}) => chosen.isNotEmpty ? chosen : (mediaDefault ?? '');

/// 系统默认**设备**（媒体角色）或默认**通信设备**的端点 id，形如
/// `{0.0.0.00000000}.{825fe633-d6cf-4f09-8a26-566125f6fc7e}`。
///
/// 为什么非要问系统：libwebrtc 的音频设备模块播放时用的是**默认通信设备**
/// （原生库里那条 `Default Communication endpoint device will be used`），
/// 而音乐（media_kit/mpv）用的是**默认设备**。Windows 允许两者指向不同硬件
/// （实测一台机器：耳机是默认设备、显示器是默认通信设备），于是别人说话从
/// 显示器出来、放歌却在耳机里。
///
/// 取不到（非 Windows、COM 失败、机器上没有任何播放设备）返回 null。
String? windowsDefaultOutputEndpointId({bool communications = false}) {
  if (!Platform.isWindows) {
    return null;
  }
  final ole = _Ole.instance;
  if (ole == null) {
    return null;
  }
  if (!_initCom(ole)) {
    return null;
  }
  // COM 任务堆上开出来的块，统一在 finally 里释放
  final blocks = <Pointer<Void>>[];
  Pointer<Void>? allocate(int size) {
    final block = ole.taskMemAlloc(size);
    if (block == nullptr) {
      return null;
    }
    blocks.add(block);
    return block;
  }

  Pointer<Void> enumerator = nullptr;
  Pointer<Void> device = nullptr;
  Pointer<Uint16> id = nullptr;
  try {
    final clsid = _guidBlock(allocate, _clsidMmDeviceEnumerator);
    final iid = _guidBlock(allocate, _iidMmDeviceEnumerator);
    final out = allocate(sizeOf<Pointer<Void>>())?.cast<Pointer<Void>>();
    if (clsid == null || iid == null || out == null) {
      AppLog.warn('读取系统播放设备失败：COM 任务堆分配失败');
      return null;
    }

    // 1) CLSID_MMDeviceEnumerator → IMMDeviceEnumerator
    out.value = nullptr;
    final hrCreate = ole.coCreateInstance(
      clsid,
      nullptr,
      _clsctxAll,
      iid,
      out,
    );
    enumerator = out.value;
    if (hrCreate < 0 || enumerator == nullptr) {
      AppLog.warn('打开音频设备枚举器失败：${_hexHr(hrCreate)}');
      return null;
    }

    // 2) IMMDeviceEnumerator::GetDefaultAudioEndpoint(eRender, role)
    out.value = nullptr;
    final hrEndpoint = _callGetDefaultAudioEndpoint(
      enumerator,
      _eRender,
      communications ? _eCommunications : _eConsole,
      out,
    );
    device = out.value;
    if (hrEndpoint < 0 || device == nullptr) {
      // 没有播放设备（拔掉最后一个耳机）时走到这里：正常情况，不必吵
      AppLog.debug('取默认播放设备失败：${_hexHr(hrEndpoint)}');
      return null;
    }

    // 3) IMMDevice::GetId()：端点 id（LPWSTR，同样在 COM 任务堆上）
    final idSlot = allocate(sizeOf<Pointer<Uint16>>())?.cast<Pointer<Uint16>>();
    if (idSlot == null) {
      AppLog.warn('读取系统播放设备失败：COM 任务堆分配失败');
      return null;
    }
    idSlot.value = nullptr;
    final hrId = _callGetId(device, idSlot);
    id = idSlot.value;
    if (hrId < 0 || id == nullptr) {
      AppLog.warn('读取播放设备 id 失败：${_hexHr(hrId)}');
      return null;
    }
    return _readUtf16(id);
  } on Object catch (error) {
    AppLog.warn('读取系统播放设备失败', error: error);
    return null;
  } finally {
    if (device != nullptr) {
      _release(device);
    }
    if (enumerator != nullptr) {
      _release(enumerator);
    }
    if (id != nullptr) {
      ole.taskMemFree(id.cast());
    }
    for (final block in blocks) {
      ole.taskMemFree(block);
    }
  }
}

/// 把**系统默认通信设备**指向 [endpointId]，返回是否成功。
///
/// 为什么改系统设置而不是直接告诉 libwebrtc 用哪只设备：flutter_webrtc 的
/// `selectAudioOutput` 在 Windows 上是个空实现（实测 `SetPlayoutDevice` 连越界
/// 索引都返回成功，音频设备模块的设备从没被改过），所以只能从系统这一侧把
/// 「通信设备」摆到和「默认设备」同一个硬件上——音频设备模块下一次起播时
/// 会重新读这个默认值，于是别人说话就落到和音乐同一只设备。
///
/// 这是**用户可见的系统设置**（Windows 声音设置里的「默认通信设备」），
/// 所以调用方只在进房期间改动，并在出房时还原（见 `MediaEngine`）。
bool windowsPointCommunicationOutputAt(String endpointId) {
  if (!Platform.isWindows || endpointId.isEmpty) {
    return false;
  }
  final ole = _Ole.instance;
  if (ole == null) {
    return false;
  }
  if (!_initCom(ole)) {
    return false;
  }
  final blocks = <Pointer<Void>>[];
  Pointer<Void>? allocate(int size) {
    final block = ole.taskMemAlloc(size);
    if (block == nullptr) {
      return null;
    }
    blocks.add(block);
    return block;
  }

  Pointer<Void> policy = nullptr;
  try {
    final clsid = _guidBlock(allocate, _clsidPolicyConfigClient);
    final iid = _guidBlock(allocate, _iidPolicyConfig);
    final out = allocate(sizeOf<Pointer<Void>>())?.cast<Pointer<Void>>();
    final deviceIdBlock = _utf16Block(allocate, endpointId);
    if (clsid == null ||
        iid == null ||
        out == null ||
        deviceIdBlock == null) {
      AppLog.warn('设置默认通信设备失败：COM 任务堆分配失败');
      return false;
    }
    out.value = nullptr;
    final hrCreate = ole.coCreateInstance(
      clsid,
      nullptr,
      _clsctxAll,
      iid,
      out,
    );
    policy = out.value;
    if (hrCreate < 0 || policy == nullptr) {
      AppLog.warn('打开音频策略客户端失败：${_hexHr(hrCreate)}');
      return false;
    }
    final hrSet = _callSetDefaultEndpoint(
      policy,
      deviceIdBlock,
      _eCommunications,
    );
    if (hrSet < 0) {
      AppLog.warn('设置默认通信设备失败：${_hexHr(hrSet)}');
      return false;
    }
    return true;
  } on Object catch (error) {
    AppLog.warn('设置默认通信设备失败', error: error);
    return false;
  } finally {
    if (policy != nullptr) {
      _release(policy);
    }
    for (final block in blocks) {
      ole.taskMemFree(block);
    }
  }
}

// ---------------------------------------------------------------------------
// dart:ffi 基建（与 `mic_volume.dart` 同一套写法：直连 vtable，不引新依赖）
// ---------------------------------------------------------------------------

/// `CoInitializeEx` 只该在同一线程上成功配对一次，这里记下成功过没有。
bool _comTried = false;

/// `CoInitializeEx(null, COINIT_MULTITHREADED)`：和其它 Core Audio 调用方
/// （`mic_volume.dart`）用同一个套间，避免同线程 STA/MTA 打架。
///
/// 成功之后不配 `CoUninitialize`：应用是长活进程、这条线程跟进程同寿，
/// 反初始化反而会和别处的引用计数互相踩。
///
/// 失败不记 `_comTried`：一次瞬时失败不该让后面每一次都跳过初始化、直接撞
/// `CO_E_NOTINITIALIZED`。
bool _initCom(_Ole ole) {
  if (_comTried) {
    return true;
  }
  final hr = ole.coInitializeEx(nullptr, 0);
  // S_OK / S_FALSE 都是「现在能用」；RPC_E_CHANGED_MODE 表示线程早被别处
  // 初始化成别的套间，照样能拿 Core Audio 接口
  if (hr >= 0 || hr == _rpcChangedMode) {
    _comTried = true;
    return true;
  }
  AppLog.warn('初始化 COM 失败，取不到默认播放设备：${_hexHr(hr)}');
  return false;
}

/// 把 GUID 写进一块 COM 任务堆内存。
Pointer<_Guid>? _guidBlock(
  Pointer<Void>? Function(int size) allocate,
  String guid,
) {
  final block = allocate(sizeOf<_Guid>());
  if (block == null) {
    return null;
  }
  final typed = block.cast<_Guid>();
  final bytes = _guidToBytes(guid);
  for (var i = 0; i < bytes.length; i++) {
    typed.ref.bytes[i] = bytes[i];
  }
  return typed;
}

/// 把 Dart 字符串写成 NUL 结尾的 UTF-16 块（COM 侧的 `LPCWSTR` 入参）。
Pointer<Uint16>? _utf16Block(
  Pointer<Void>? Function(int size) allocate,
  String value,
) {
  final units = value.codeUnits;
  final block = allocate((units.length + 1) * sizeOf<Uint16>());
  if (block == null) {
    return null;
  }
  final typed = block.cast<Uint16>();
  for (var i = 0; i < units.length; i++) {
    (typed + i).value = units[i];
  }
  (typed + units.length).value = 0;
  return typed;
}

int _callGetDefaultAudioEndpoint(
  Pointer<Void> enumerator,
  int dataFlow,
  int role,
  Pointer<Pointer<Void>> out,
) {
  final method = _vtableSlot<_GetDefaultAudioEndpointNative>(
    enumerator,
    _vtGetDefaultAudioEndpoint,
  );
  if (method == nullptr) {
    return _eFail;
  }
  return method.asFunction<_GetDefaultAudioEndpointDart>()(
    enumerator,
    dataFlow,
    role,
    out,
  );
}

int _callGetId(Pointer<Void> device, Pointer<Pointer<Uint16>> out) {
  final method = _vtableSlot<_GetIdNative>(device, _vtGetId);
  if (method == nullptr) {
    return _eFail;
  }
  return method.asFunction<_GetIdDart>()(device, out);
}

int _callSetDefaultEndpoint(
  Pointer<Void> policy,
  Pointer<Uint16> deviceId,
  int role,
) {
  final method = _vtableSlot<_SetDefaultEndpointNative>(
    policy,
    _vtSetDefaultEndpoint,
  );
  if (method == nullptr) {
    return _eFail;
  }
  return method.asFunction<_SetDefaultEndpointDart>()(policy, deviceId, role);
}

/// `IUnknown::Release`。
void _release(Pointer<Void> target) {
  if (target == nullptr) {
    return;
  }
  final method = _vtableSlot<_ReleaseNative>(target, _vtRelease);
  if (method == nullptr) {
    return;
  }
  method.asFunction<_ReleaseDart>()(target);
}

/// 读一段 NUL 结尾的 UTF-16 字符串（`GetId` 返回的就是这种）。
String _readUtf16(Pointer<Uint16> pointer) {
  final units = <int>[];
  var index = 0;
  while (true) {
    final unit = (pointer + index).value;
    if (unit == 0) {
      break;
    }
    units.add(unit);
    index++;
  }
  return String.fromCharCodes(units);
}

/// GUID 的内存布局：`DWORD Data1; WORD Data2; WORD Data3; BYTE Data4[8]`。
///
/// 用 16 个字节直接写，省掉按字段写时的端序和对齐心算。
final class _Guid extends Struct {
  @Array(16)
  external Array<Uint8> bytes;
}

/// `XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX` → 16 字节（前三个分组小端）。
List<int> _guidToBytes(String guid) {
  final parts = guid.split('-');
  if (parts.length != 5) {
    throw ArgumentError.value(guid, 'guid', 'GUID 段数不对');
  }
  final bytes = <int>[];
  void littleEndian(String hex) {
    for (var i = hex.length - 2; i >= 0; i -= 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
  }

  littleEndian(parts[0]);
  littleEndian(parts[1]);
  littleEndian(parts[2]);
  final rest = parts[3] + parts[4];
  for (var i = 0; i < rest.length; i += 2) {
    bytes.add(int.parse(rest.substring(i, i + 2), radix: 16));
  }
  return bytes;
}

/// 从 COM 接口指针的 vtable 上取出第 [index] 个方法。
Pointer<NativeFunction<T>> _vtableSlot<T extends Function>(
  Pointer<Void> instance,
  int index,
) {
  if (instance == nullptr) {
    return nullptr;
  }
  final table = instance.cast<Pointer<IntPtr>>().value;
  if (table == nullptr) {
    return nullptr;
  }
  return Pointer<NativeFunction<T>>.fromAddress((table + index).value);
}

/// `E_FAIL`：vtable 上取不到方法时的兜底失败码。
final int _eFail = 0x80004005.toSigned(32);

typedef _CoInitializeExNative = Int32 Function(
  Pointer<Void> reserved,
  Uint32 coInit,
);
typedef _CoInitializeExDart = int Function(Pointer<Void> reserved, int coInit);

typedef _CoCreateInstanceNative = Int32 Function(
  Pointer<_Guid> clsid,
  Pointer<Void> outer,
  Uint32 clsctx,
  Pointer<_Guid> iid,
  Pointer<Pointer<Void>> out,
);
typedef _CoCreateInstanceDart = int Function(
  Pointer<_Guid> clsid,
  Pointer<Void> outer,
  int clsctx,
  Pointer<_Guid> iid,
  Pointer<Pointer<Void>> out,
);

typedef _CoTaskMemAllocNative = Pointer<Void> Function(IntPtr size);
typedef _CoTaskMemAllocDart = Pointer<Void> Function(int size);

typedef _CoTaskMemFreeNative = Void Function(Pointer<Void> block);
typedef _CoTaskMemFreeDart = void Function(Pointer<Void> block);

typedef _GetDefaultAudioEndpointNative = Int32 Function(
  Pointer<Void> self,
  Int32 dataFlow,
  Int32 role,
  Pointer<Pointer<Void>> device,
);
typedef _GetDefaultAudioEndpointDart = int Function(
  Pointer<Void> self,
  int dataFlow,
  int role,
  Pointer<Pointer<Void>> device,
);

typedef _GetIdNative = Int32 Function(
  Pointer<Void> self,
  Pointer<Pointer<Uint16>> id,
);
typedef _GetIdDart = int Function(
  Pointer<Void> self,
  Pointer<Pointer<Uint16>> id,
);

typedef _SetDefaultEndpointNative = Int32 Function(
  Pointer<Void> self,
  Pointer<Uint16> deviceId,
  Int32 role,
);
typedef _SetDefaultEndpointDart = int Function(
  Pointer<Void> self,
  Pointer<Uint16> deviceId,
  int role,
);

typedef _ReleaseNative = Uint32 Function(Pointer<Void> self);
typedef _ReleaseDart = int Function(Pointer<Void> self);

/// ole32.dll 的入口点集合（进程内只加载一次）。
class _Ole {
  _Ole._(DynamicLibrary lib)
    : coInitializeEx = lib
          .lookupFunction<_CoInitializeExNative, _CoInitializeExDart>(
            'CoInitializeEx',
          ),
      coCreateInstance = lib
          .lookupFunction<_CoCreateInstanceNative, _CoCreateInstanceDart>(
            'CoCreateInstance',
          ),
      taskMemAlloc = lib
          .lookupFunction<_CoTaskMemAllocNative, _CoTaskMemAllocDart>(
            'CoTaskMemAlloc',
          ),
      taskMemFree = lib
          .lookupFunction<_CoTaskMemFreeNative, _CoTaskMemFreeDart>(
            'CoTaskMemFree',
          );

  final _CoInitializeExDart coInitializeEx;
  final _CoCreateInstanceDart coCreateInstance;
  final _CoTaskMemAllocDart taskMemAlloc;
  final _CoTaskMemFreeDart taskMemFree;

  static bool _loaded = false;
  static _Ole? _cache;

  /// 非 Windows 或加载失败时为 null（调用方据此降级）。
  static _Ole? get instance {
    if (_loaded) {
      return _cache;
    }
    _loaded = true;
    if (!Platform.isWindows) {
      return null;
    }
    try {
      _cache = _Ole._(DynamicLibrary.open('ole32.dll'));
    } on Object catch (error) {
      AppLog.warn('加载 ole32.dll 失败，取不到默认播放设备', error: error);
      _cache = null;
    }
    return _cache;
  }
}
