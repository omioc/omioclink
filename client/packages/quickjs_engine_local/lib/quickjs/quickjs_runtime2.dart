/* START PARTS IMPORT QJS ENGINE */
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:quickjs_engine/quickjs_engine.dart';

import 'ffi.dart';

export 'ffi.dart' show JSEvalFlag, JSRef, QuickJsBytecodeBindings, quickjsBytecode;

part './isolate.dart';
part './object.dart';
part './wrapper.dart';

/// Handler function to manage js module.
typedef _JsModuleHandler = String Function(String name);

/// Handler to manage unhandled promise rejection.
typedef _JsHostPromiseRejectionHandler = void Function(dynamic reason);

/// Quickjs engine for flutter.
class QuickJsRuntime2 extends JavascriptRuntime {
  Pointer<JSRuntime>? _rt;
  Pointer<JSContext>? _ctx;

  /// Max stack size for quickjs.
  int stackSize;

  /// Max stack size for quickjs.
  final int? timeout;

  /// Max memory for quickjs.
  final int? memoryLimit;

  /// Message Port for event loop. Close it to stop dispatching event loop.
  ReceivePort port = ReceivePort();

  /// Handler function to manage js module.
  final _JsModuleHandler? moduleHandler;

  /// Handler function to manage js module.
  final _JsHostPromiseRejectionHandler? hostPromiseRejectionHandler;

  QuickJsRuntime2({
    this.moduleHandler,
    this.stackSize = 1024 * 1024,
    this.timeout,
    this.memoryLimit,
    this.hostPromiseRejectionHandler,
  }) {
    this.init();
  }

  _ensureEngine() {
    if (_rt != null) return;
    final rt = jsNewRuntime((ctx, type, ptr) {
      try {
        switch (type) {
          case JSChannelType.METHON:
            final pdata = ptr.cast<Pointer<JSValue>>();
            final argc = pdata[1].cast<Int32>().value;
            final pargs = [];
            for (var i = 0; i < argc; ++i) {
              pargs.add(_jsToDart(
                ctx,
                Pointer.fromAddress(
                  pdata[2].address + sizeOfJSValue * i,
                ),
              ));
            }
            final JSInvokable func = _jsToDart(
              ctx,
              pdata[3],
            );
            return _dartToJs(
                ctx,
                func.invoke(
                  pargs,
                  _jsToDart(ctx, pdata[0]),
                ));
          case JSChannelType.MODULE:
            if (moduleHandler == null) throw JSError('No ModuleHandler');
            final ret = moduleHandler!(
              ptr.cast<Utf8>().toDartString(),
            ).toNativeUtf8();
            Future.microtask(() {
              malloc.free(ret);
            });
            return ret.cast();
          case JSChannelType.PROMISE_TRACK:
            final err = _parseJSException(ctx, ptr);
            if (hostPromiseRejectionHandler != null) {
              hostPromiseRejectionHandler!(err);
            } else {
              print('unhandled promise rejection: $err');
            }
            return nullptr;
          case JSChannelType.FREE_OBJECT:
            final rt = ctx.cast<JSRuntime>();
            _DartObject.fromAddress(rt, ptr.address)?.free();
            return nullptr;
        }
        throw JSError('call channel with wrong type');
      } catch (e) {
        if (type == JSChannelType.FREE_OBJECT) {
          print('DartObject release error: $e');
          return nullptr;
        }
        if (type == JSChannelType.MODULE) {
          print('host Promise Rejection Handler error: $e');
          return nullptr;
        }
        final throwObj = _dartToJs(ctx, e);
        final err = jsThrow(ctx, throwObj);
        jsFreeValue(ctx, throwObj);
        if (type == JSChannelType.MODULE) {
          jsFreeValue(ctx, err);
          return nullptr;
        }
        return err;
      }
    }, timeout ?? 0, port);
    final stackSize = this.stackSize;
    if (stackSize > 0) jsSetMaxStackSize(rt, stackSize);
    final memoryLimit = this.memoryLimit ?? 0;
    if (memoryLimit > 0) jsSetMemoryLimit(rt, memoryLimit);
    _rt = rt;
    _ctx = jsNewContext(rt);
  }

  /// Free Runtime and Context which can be recreate when evaluate again.
  close() {
    final rt = _rt;
    final ctx = _ctx;
    _rt = null;
    _ctx = null;
    if (ctx != null) jsFreeContext(ctx);
    if (rt == null) return;
    _executePendingJob();
    try {
      for (final obj in localContext.values) {
        JSRef.freeRecursive(obj);
      }
      jsFreeRuntime(rt);
    } on String catch (e) {
      throw JSError(e);
    }
  }

  void _executePendingJob() {
    final rt = _rt;
    final ctx = _ctx;
    if (rt == null || ctx == null) return;
    while (true) {
      int err = jsExecutePendingJob(rt);
      if (err <= 0) {
        if (err < 0) print(_parseJSException(ctx));
        break;
      }
    }
  }

  /// Dispatch JavaScript Event loop.
  Future<void> dispatch() async {
    //await for (final _ in port) {
    _executePendingJob();
    //}
  }

  @override
  void setInspectable(bool inspectable) {
    // Nothing to do.
  }

  /// Evaluate js script.
  JsEvalResult evaluate(
    String command, {
    String? name,
    int? evalFlags,
    String? sourceUrl,
  }) {
    _ensureEngine();
    final ctx = _ctx!;
    final jsval = jsEval(
      ctx,
      command,
      name ?? '<eval>',
      evalFlags ?? JSEvalFlag.GLOBAL,
    );

    if (jsIsException(jsval) != 0) {
      jsFreeValue(ctx, jsval);
      JSError exception = _parseJSException(ctx);
      return JsEvalResult(exception.toString(), exception, isError: true);
    }
    final result = _jsToDart(ctx, jsval);
    jsFreeValue(ctx, jsval);
    return JsEvalResult(result?.toString() ?? "null", result);
  }

  /// 上一次字节码操作失败的原因（成功为 null）。
  ///
  /// 只用于日志/诊断：字节码是纯优化，任何一步失败都要能无缝退回源码执行。
  String? lastBytecodeError;

  /// 把源码编译成字节码（**只编译、不执行**）。
  ///
  /// 返回 null 表示引擎不支持（桥里没有那几个符号）或源码语法错误，
  /// 失败原因在 [lastBytecodeError]；调用方这时应该退回 [evaluate]。
  Uint8List? compileToBytecode(String source, {String name = '<bytecode>'}) {
    final bindings = quickjsBytecode;
    if (bindings == null) {
      lastBytecodeError = '当前 JS 桥不支持字节码';
      return null;
    }
    _ensureEngine();
    final ctx = _ctx!;
    final input = source.toNativeUtf8();
    final filename = name.toNativeUtf8();
    final out = calloc<Pointer<Uint8>>();
    final outLen = calloc<IntPtr>();
    final errorSlot = calloc<Pointer<Utf8>>();
    Uint8List? bytes;
    try {
      final ok = bindings.compile(
        ctx,
        input,
        input.length,
        filename,
        JSEvalFlag.GLOBAL,
        out,
        outLen,
        errorSlot,
      );
      final buffer = out.value;
      if (ok != 0 && buffer.address != 0) {
        bytes = Uint8List.fromList(buffer.asTypedList(outLen.value));
        bindings.freeBuffer(ctx, buffer.cast<Void>());
        lastBytecodeError = null;
      } else {
        lastBytecodeError = _takeJsString(ctx, errorSlot) ?? '字节码编译失败';
      }
    } finally {
      malloc.free(input);
      malloc.free(filename);
      calloc.free(out);
      calloc.free(outLen);
      calloc.free(errorSlot);
    }
    return bytes;
  }

  /// 执行一份字节码：语义与 [evaluate] 相同，但省掉了解析整份源码那一步。
  JsEvalResult evaluateBytecode(Uint8List bytes) {
    final bindings = quickjsBytecode;
    if (bindings == null) {
      return JsEvalResult('当前 JS 桥不支持字节码', null, isError: true);
    }
    _ensureEngine();
    final ctx = _ctx!;
    final buffer = malloc.allocate<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    if (bytes.isNotEmpty) {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
    }
    final errorSlot = calloc<Pointer<Utf8>>();
    try {
      final jsval = bindings.evaluate(ctx, buffer, bytes.length, errorSlot);
      if (jsval.address == 0) {
        final message = _takeJsString(ctx, errorSlot) ?? '字节码执行失败';
        return JsEvalResult(message, null, isError: true);
      }
      final result = _jsToDart(ctx, jsval);
      jsFreeValue(ctx, jsval);
      // 与 jsEval 一致：叫一声事件循环，让脚本里挂上的 promise 能被推进。
      jsPokeEventLoop(ctx);
      return JsEvalResult(result?.toString() ?? 'null', result);
    } finally {
      malloc.free(buffer);
      calloc.free(errorSlot);
    }
  }

  /// 取走桥回传的 C 字符串（`char **`），读完立刻释放。
  static String? _takeJsString(Pointer<JSContext> ctx, Pointer<Pointer<Utf8>> slot) {
    final value = slot.value;
    if (value.address == 0) {
      return null;
    }
    final text = value.toDartString();
    jsFreeCString(ctx, value);
    slot.value = nullptr;
    return text;
  }

  @override
  JsEvalResult callFunction(Pointer<NativeType> fn, Pointer<NativeType> obj) {
    throw UnimplementedError();
  }

  @override
  T? convertValue<T>(JsEvalResult jsValue) {
    return true as T;
  }

  @override
  void dispose() {
    try {
      port.close(); // stop dispatch loop
      close(); // close engine
    } on JSError catch (e) {
      print(e); // catch reference leak exception
    }
  }

  @override
  Future<JsEvalResult> evaluateAsync(String code, {String? sourceUrl}) {
    return Future.value(evaluate(code, sourceUrl: sourceUrl));
  }

  @override
  int executePendingJob() {
    this.dispatch();
    return 0;
  }

  @override
  String getEngineInstanceId() {
    return this.hashCode.toString();
  }

  @override
  void initChannelFunctions() {
    JavascriptRuntime.channelFunctionsRegistered[getEngineInstanceId()] = {};
    final setToGlobalObject =
        evaluate("(key, val) => { this[key] = val; }").rawResult;
    localContext['setToGlobalObject'] = setToGlobalObject;
    (setToGlobalObject as JSInvokable).invoke([
      'sendMessage',
      (String channelName, String message) {
        final channelFunctions = JavascriptRuntime
            .channelFunctionsRegistered[getEngineInstanceId()]!;

        if (channelFunctions.containsKey(channelName)) {
          return channelFunctions[channelName]!.call(jsonDecode(message));
        } else {
          print('No channel $channelName registered');
        }
        if (JavascriptRuntime.debugEnabled) {
          print('CHANNEL: $channelName - Message: $message');
        }
      }
    ]);
  }

  @override
  String jsonStringify(JsEvalResult jsValue) {
    throw UnimplementedError();
  }

  @override
  bool setupBridge(String channelName, void Function(dynamic args) fn) {
    final channelFunctionCallbacks =
        JavascriptRuntime.channelFunctionsRegistered[getEngineInstanceId()]!;

    if (channelFunctionCallbacks.keys.contains(channelName)) return false;

    channelFunctionCallbacks[channelName] = fn;

    return true;
  }
}
