import 'dart:ffi';
import 'dart:io';

import '../core/app_log.dart';
import '../core/l10n_ext.dart';

/// 本机录音设备主音量的端口（测试可注入假实现）。
///
/// 只做一件事：把「当前默认录音设备的音量」读出来 / 写进去。
/// 失败一律不抛，用 [supported] + [lastError] 把「为什么调不了」说清楚。
abstract interface class MicVolumePort {
  /// Windows 且拿到了默认录音设备的主音量接口时为 true。
  bool get supported;

  /// 最近一次失败原因（中文，界面上要能显示「为什么调不了」）。
  String? get lastError;

  /// 读当前音量，0.0~1.0；失败/不支持返回 null。
  double? readVolume();

  /// 写音量，0.0~1.0（越界由实现钳制）；返回是否成功。
  bool writeVolume(double value);

  /// 释放 COM 接口（可重复调用）。
  void dispose();
}

/// 非 Windows / 无 COM 环境下的空实现（supported=false，读写都失败但绝不抛）。
class NullMicVolume implements MicVolumePort {
  NullMicVolume([this._reason]);

  /// 为空时回落到「没有可用的录音设备」那句。
  ///
  /// 默认参数必须是常量、取不到当前语言，所以推迟到读取时才取文案。
  final String? _reason;

  @override
  bool get supported => false;

  @override
  String? get lastError => _reason ?? appL10n.mediaMicVolumeDefaultReason;

  @override
  double? readVolume() => null;

  @override
  bool writeVolume(double value) => false;

  @override
  void dispose() {}
}

/// 当前平台可用的实现（Windows → [WindowsMicVolume]，其它 → [NullMicVolume]）。
MicVolumePort createMicVolumePort() {
  if (!Platform.isWindows) {
    return NullMicVolume(appL10n.mediaMicVolumeUnsupportedPlatform);
  }
  return WindowsMicVolume();
}

// ---------------------------------------------------------------------------
// Core Audio 的常量与 GUID（照抄 Windows SDK，别自己推）
// ---------------------------------------------------------------------------

/// `CLSID_MMDeviceEnumerator`：Core Audio 的设备枚举器。
const String _clsidMmDeviceEnumerator = 'BCDE0395-E52F-467C-8E3D-C4579291692E';

/// `IID_IMMDeviceEnumerator`。
const String _iidMmDeviceEnumerator = 'A95664D2-9614-4F35-A746-DE8DB63617E6';

/// `IID_IAudioEndpointVolume`：单个音频端点的主音量（0.0~1.0 标量）。
const String _iidAudioEndpointVolume = '5CDF2C82-841E-4546-9722-0CF74078229A';

/// `CLSCTX_ALL`（INPROC_SERVER | INPROC_HANDLER | LOCAL_SERVER | REMOTE_SERVER）。
const int _clsctxAll = 23;

/// `EDataFlow::eCapture`：录音设备。
const int _eCapture = 1;

/// `ERole::eConsole`：系统「默认设备」（设置里那根主滑块）用的角色。
const int _eConsole = 0;

/// vtable 索引。0..2 被 `IUnknown`（QueryInterface/AddRef/Release）占掉。
const int _vtRelease = 2;
const int _vtActivate = 3;
const int _vtGetDefaultAudioEndpoint = 4;
const int _vtSetMasterVolumeLevelScalar = 7;
const int _vtGetMasterVolumeLevelScalar = 9;

/// `RPC_E_CHANGED_MODE`：本线程已被初始化成别的套间，视同初始化成功继续用。
final int _rpcChangedMode = 0x80010106.toSigned(32);

/// `ERROR_NOT_FOUND`（作为 HRESULT）：没有默认录音设备。
final int _errorNotFound = 0x80070490.toSigned(32);

/// `E_FAIL`：vtable 上取不到方法时的兜底失败码。
final int _eFail = 0x80004005.toSigned(32);

/// 把 HRESULT 写成 `0x80004005` 这种形式，方便对着文档和日志查。
String _hexHr(int hr) =>
    '0x${hr.toUnsigned(32).toRadixString(16).toUpperCase().padLeft(8, '0')}';

/// Windows 实现：CLSID_MMDeviceEnumerator → GetDefaultAudioEndpoint(eCapture, eConsole)
/// → IMMDevice::Activate(IID_IAudioEndpointVolume) → Set/GetMasterVolumeLevelScalar。
///
/// 为什么直连 Core Audio：项目不允许新增 pub 依赖（用不了 `win32` 包），而「当前
/// 默认录音设备的音量」只有 COM 接口 `IAudioEndpointVolume` 能读写，所以这里用
/// dart:ffi 手工走一遍 vtable：COM 对象的头 8 字节是 vtable 指针，vtable 是一张
/// 函数指针表。这些方法都是 `__stdcall`，Windows x64 只有一种调用约定，因此签名
/// 直接写成普通的 `Int32 Function(...)` 即可。
///
/// 内存：GUID 块和出参槽都开在 COM 任务堆上（`CoTaskMemAlloc`），这样不必引入
/// `package:ffi` 的 `calloc`；[dispose] 里统一 `CoTaskMemFree`。
///
/// 失败语义：任何一步失败都只更新 [lastError]，绝不抛异常；接口指针在首次成功后
/// 缓存复用（换设备/拔设备导致失效时丢弃重取一次）。
class WindowsMicVolume implements MicVolumePort {
  /// `IAudioEndpointVolume*`（缓存；失效时置回 nullptr 重新获取）。
  Pointer<Void> _volume = nullptr;

  /// 缓存的 vtable 方法（避免每次读写真去查一遍表）。
  _SetMasterVolumeLevelScalarDart? _setMasterVolume;
  _GetMasterVolumeLevelScalarDart? _getMasterVolume;

  String? _lastError;

  /// `CoInitializeEx` 是否配对成功（为 true 时 [dispose] 要 `CoUninitialize`）。
  bool _comOwned = false;

  /// `CoInitializeEx` 是否已经试过（同一线程只该调一次，否则计数失衡）。
  bool _comTried = false;

  /// 是否已经尝试取过接口：失败后 [supported] 不再反复重建 COM 对象。
  bool _acquireTried = false;

  bool _disposed = false;

  /// COM 任务堆上的内存块，[dispose] 时统一释放。
  final List<Pointer<Void>> _blocks = <Pointer<Void>>[];

  /// 已写好的 GUID 块（按 GUID 字符串缓存）。
  final Map<String, Pointer<_Guid>> _guids = <String, Pointer<_Guid>>{};

  /// `GetDefaultAudioEndpoint` / `Activate` 复用的出参槽。
  Pointer<Pointer<Void>> _outSlot = nullptr;

  /// 读音量复用的出参槽。
  Pointer<Float> _levelSlot = nullptr;

  @override
  bool get supported {
    if (_disposed) {
      return false;
    }
    return _endpoint() != null;
  }

  @override
  String? get lastError => _lastError;

  @override
  double? readVolume() {
    if (_disposed) {
      _lastError = appL10n.mediaMicVolumeReleased;
      return null;
    }
    var endpoint = _endpoint(retry: true);
    if (endpoint == null) {
      return null;
    }
    var level = _readScalar(endpoint);
    if (level == null) {
      // 缓存的接口可能已失效（换了默认设备、设备被拔）：丢掉重取一次
      _releaseVolume();
      endpoint = _endpoint(retry: true);
      if (endpoint == null) {
        return null;
      }
      level = _readScalar(endpoint);
    }
    return level;
  }

  @override
  bool writeVolume(double value) {
    if (_disposed) {
      _lastError = appL10n.mediaMicVolumeReleased;
      return false;
    }
    // NaN 没有意义，按 0 处理；其余钳制到 0.0~1.0
    final level = value.isNaN ? 0.0 : value.clamp(0.0, 1.0).toDouble();
    var endpoint = _endpoint(retry: true);
    if (endpoint == null) {
      return false;
    }
    var hr = _writeScalar(endpoint, level);
    if (hr < 0) {
      _releaseVolume();
      endpoint = _endpoint(retry: true);
      if (endpoint == null) {
        return false;
      }
      hr = _writeScalar(endpoint, level);
    }
    if (hr < 0) {
      _lastError = appL10n.mediaMicVolumeWriteFailed(_hexHr(hr));
      return false;
    }
    _lastError = null;
    return true;
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _releaseVolume();
    final ole = _Ole.instance;
    if (ole != null) {
      for (final block in _blocks) {
        ole.taskMemFree(block);
      }
    }
    _blocks.clear();
    _guids.clear();
    _outSlot = nullptr;
    _levelSlot = nullptr;
    if (_comOwned) {
      _comOwned = false;
      ole?.coUninitialize();
    }
  }

  // -------------------------------------------------------------------------
  // 接口获取
  // -------------------------------------------------------------------------

  /// 取（并缓存）`IAudioEndpointVolume`；[retry] 为 true 时忽略上次的失败结论再试。
  Pointer<Void>? _endpoint({bool retry = false}) {
    if (_disposed) {
      return null;
    }
    if (_volume != nullptr) {
      return _volume;
    }
    if (retry) {
      _acquireTried = false;
    }
    if (_acquireTried) {
      return null;
    }
    _acquireTried = true;
    return _acquire();
  }

  /// 走一遍 `CoCreateInstance` → `GetDefaultAudioEndpoint` → `Activate`。
  Pointer<Void>? _acquire() {
    try {
      return _acquireUnchecked();
    } on Object catch (error) {
      _lastError = appL10n.mediaMicVolumeInitFailed('$error');
      AppLog.warn('初始化麦克风音量接口抛异常', error: error);
      return null;
    }
  }

  Pointer<Void>? _acquireUnchecked() {
    final ole = _Ole.instance;
    if (ole == null) {
      _lastError = appL10n.mediaMicVolumeOleMissing;
      return null;
    }
    if (!_initCom(ole)) {
      return null;
    }
    final clsid = _guidBlock(ole, _clsidMmDeviceEnumerator);
    final iidEnumerator = _guidBlock(ole, _iidMmDeviceEnumerator);
    final iidVolume = _guidBlock(ole, _iidAudioEndpointVolume);
    final out = _ensureOutSlot(ole);
    if (clsid == null ||
        iidEnumerator == null ||
        iidVolume == null ||
        out == null) {
      _lastError = appL10n.mediaMicVolumeInitOutOfMemory;
      return null;
    }

    // 1) CLSID_MMDeviceEnumerator → IMMDeviceEnumerator
    out.value = nullptr;
    final hrCreate = ole.coCreateInstance(
      clsid,
      nullptr,
      _clsctxAll,
      iidEnumerator,
      out,
    );
    final enumerator = out.value;
    if (hrCreate < 0 || enumerator == nullptr) {
      _lastError = appL10n.mediaMicVolumeEnumeratorFailed(_hexHr(hrCreate));
      AppLog.debug('打开音频设备枚举器失败：$_lastError');
      return null;
    }
    Pointer<Void> device = nullptr;
    try {
      // 2) IMMDeviceEnumerator::GetDefaultAudioEndpoint(eCapture, eConsole)
      out.value = nullptr;
      final hrEndpoint = _callGetDefaultAudioEndpoint(enumerator, out);
      device = out.value;
      if (hrEndpoint < 0 || device == nullptr) {
        _lastError = hrEndpoint == _errorNotFound
            ? appL10n.mediaMicVolumeNoDevice
            : appL10n.mediaMicVolumeDefaultDeviceFailed(_hexHr(hrEndpoint));
        AppLog.debug('获取默认录音设备失败：$_lastError');
        device = nullptr;
        return null;
      }
      // 3) IMMDevice::Activate(IID_IAudioEndpointVolume)
      out.value = nullptr;
      final hrActivate = _callActivate(device, iidVolume, out);
      final volume = out.value;
      if (hrActivate < 0 || volume == nullptr) {
        _lastError = appL10n.mediaMicVolumeActivateFailed(_hexHr(hrActivate));
        AppLog.debug('获取录音设备音量接口失败：$_lastError');
        return null;
      }
      final setMaster = _vtableSlot<_SetMasterVolumeLevelScalarNative>(
        volume,
        _vtSetMasterVolumeLevelScalar,
      );
      final getMaster = _vtableSlot<_GetMasterVolumeLevelScalarNative>(
        volume,
        _vtGetMasterVolumeLevelScalar,
      );
      if (setMaster == nullptr || getMaster == nullptr) {
        _release(volume);
        _lastError = appL10n.mediaMicVolumeNoMethods(_hexHr(_eFail));
        return null;
      }
      _setMasterVolume = setMaster.asFunction<_SetMasterVolumeLevelScalarDart>();
      _getMasterVolume = getMaster.asFunction<_GetMasterVolumeLevelScalarDart>();
      _volume = volume;
      _lastError = null;
      return volume;
    } finally {
      if (device != nullptr) {
        _release(device);
      }
      _release(enumerator);
    }
  }

  /// `CoInitializeEx(null, 0)`：MTA。同一线程只调一次，成功时记下要配对 `CoUninitialize`。
  bool _initCom(_Ole ole) {
    if (_comTried) {
      return true;
    }
    _comTried = true;
    final hr = ole.coInitializeEx(nullptr, 0);
    if (hr >= 0) {
      // S_OK / S_FALSE（S_FALSE 表示本线程已初始化，仍需配对一次 Uninitialize）
      _comOwned = true;
      return true;
    }
    if (hr == _rpcChangedMode) {
      // 线程早被（别处）初始化成 STA：照样能用，只是我们不该再 Uninitialize
      return true;
    }
    _lastError = appL10n.mediaMicVolumeComInitFailed(_hexHr(hr));
    AppLog.debug('初始化 COM 失败：$_lastError');
    return false;
  }

  /// 把 GUID 写进一块 COM 任务堆内存（同一 GUID 只写一次）。
  Pointer<_Guid>? _guidBlock(_Ole ole, String guid) {
    final cached = _guids[guid];
    if (cached != null) {
      return cached;
    }
    final block = ole.taskMemAlloc(sizeOf<_Guid>());
    if (block == nullptr) {
      return null;
    }
    final typed = block.cast<_Guid>();
    final bytes = _guidToBytes(guid);
    for (var i = 0; i < bytes.length; i++) {
      typed.ref.bytes[i] = bytes[i];
    }
    _guids[guid] = typed;
    _blocks.add(block);
    return typed;
  }

  /// 出参槽（`IMMDevice**` / `void**` 复用一个）。
  Pointer<Pointer<Void>>? _ensureOutSlot(_Ole ole) {
    if (_outSlot != nullptr) {
      return _outSlot;
    }
    final block = ole.taskMemAlloc(sizeOf<Pointer<Void>>());
    if (block == nullptr) {
      return null;
    }
    final slot = block.cast<Pointer<Void>>();
    slot.value = nullptr;
    _outSlot = slot;
    _blocks.add(block);
    return slot;
  }

  /// `float*` 出参槽。
  Pointer<Float>? _ensureLevelSlot(_Ole ole) {
    if (_levelSlot != nullptr) {
      return _levelSlot;
    }
    final block = ole.taskMemAlloc(sizeOf<Float>());
    if (block == nullptr) {
      return null;
    }
    final slot = block.cast<Float>();
    slot.value = 0;
    _levelSlot = slot;
    _blocks.add(block);
    return slot;
  }

  // -------------------------------------------------------------------------
  // vtable 调用
  // -------------------------------------------------------------------------

  int _callGetDefaultAudioEndpoint(
    Pointer<Void> enumerator,
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
      _eCapture,
      _eConsole,
      out,
    );
  }

  int _callActivate(
    Pointer<Void> device,
    Pointer<_Guid> iid,
    Pointer<Pointer<Void>> out,
  ) {
    final method = _vtableSlot<_ActivateNative>(device, _vtActivate);
    if (method == nullptr) {
      return _eFail;
    }
    return method.asFunction<_ActivateDart>()(
      device,
      iid,
      _clsctxAll,
      nullptr,
      out,
    );
  }

  /// 写一次音量；返回 HRESULT。
  int _writeScalar(Pointer<Void> endpoint, double level) {
    final setMaster = _setMasterVolume;
    if (setMaster == null) {
      return _eFail;
    }
    return setMaster(endpoint, level, nullptr);
  }

  /// 读一次音量；失败返回 null 并写 [lastError]。
  double? _readScalar(Pointer<Void> endpoint) {
    final getMaster = _getMasterVolume;
    if (getMaster == null) {
      _lastError = appL10n.mediaMicVolumeReadFailed(_hexHr(_eFail));
      return null;
    }
    final ole = _Ole.instance;
    final level = ole == null ? null : _ensureLevelSlot(ole);
    if (level == null) {
      _lastError = appL10n.mediaMicVolumeReadOutOfMemory;
      return null;
    }
    final hr = getMaster(endpoint, level);
    if (hr < 0) {
      _lastError = appL10n.mediaMicVolumeReadFailed(_hexHr(hr));
      return null;
    }
    _lastError = null;
    return level.value;
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

  void _releaseVolume() {
    final volume = _volume;
    _volume = nullptr;
    _setMasterVolume = null;
    _getMasterVolume = null;
    if (volume != nullptr) {
      _release(volume);
    }
  }
}

// ---------------------------------------------------------------------------
// dart:ffi 基建
// ---------------------------------------------------------------------------

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
///
/// COM 对象头 8 字节是 vtable 指针，vtable 本身就是一张函数指针表，所以按
/// `Pointer<IntPtr>` 取第 [index] 项再 `fromAddress` 即可。
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

typedef _CoUninitializeNative = Void Function();
typedef _CoUninitializeDart = void Function();

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

typedef _ActivateNative = Int32 Function(
  Pointer<Void> self,
  Pointer<_Guid> iid,
  Uint32 clsctx,
  Pointer<Void> activationParams,
  Pointer<Pointer<Void>> out,
);
typedef _ActivateDart = int Function(
  Pointer<Void> self,
  Pointer<_Guid> iid,
  int clsctx,
  Pointer<Void> activationParams,
  Pointer<Pointer<Void>> out,
);

typedef _SetMasterVolumeLevelScalarNative = Int32 Function(
  Pointer<Void> self,
  Float level,
  Pointer<Void> eventContext,
);
typedef _SetMasterVolumeLevelScalarDart = int Function(
  Pointer<Void> self,
  double level,
  Pointer<Void> eventContext,
);

typedef _GetMasterVolumeLevelScalarNative = Int32 Function(
  Pointer<Void> self,
  Pointer<Float> level,
);
typedef _GetMasterVolumeLevelScalarDart = int Function(
  Pointer<Void> self,
  Pointer<Float> level,
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
      coUninitialize = lib
          .lookupFunction<_CoUninitializeNative, _CoUninitializeDart>(
            'CoUninitialize',
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
  final _CoUninitializeDart coUninitialize;
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
      AppLog.warn('加载 ole32.dll 失败，调不了麦克风音量', error: error);
      _cache = null;
    }
    return _cache;
  }
}
