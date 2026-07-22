import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'dart:io' show Platform;

final DynamicLibrary nativeLib = Platform.isAndroid
    ? DynamicLibrary.open("libminer.so")
    : DynamicLibrary.process();

typedef StartMiningC = Void Function(
    Pointer<Utf8> username,
    Pointer<Utf8> key,
    Pointer<Utf8> diff,
    Pointer<Utf8> rig,
    Int32 threads,
    Int32 nice,
    Pointer<Utf8> poolIp,
    Int32 poolPort,
);
typedef StartMiningDart = void Function(
    String username,
    String key,
    String diff,
    String rig,
    int threads,
    int nice,
    String poolIp,
    int poolPort,
);

typedef StopMiningC = Void Function();
typedef StopMiningDart = void Function();

typedef GetLogsC = Void Function(Pointer<Uint8> buffer, Int32 size);
typedef GetLogsDart = String Function();

typedef IsRunningC = Int32 Function();
typedef IsRunningDart = int Function();

final StartMiningDart startMining = nativeLib
    .lookup<NativeFunction<StartMiningC>>('start_mining')
    .asFunction();

final StopMiningDart stopMining = nativeLib
    .lookup<NativeFunction<StopMiningC>>('stop_mining')
    .asFunction();

final GetLogsDart getLogsNative = () {
  final ptr = nativeLib.lookup<NativeFunction<GetLogsC>>('get_logs');
  final func = ptr.asFunction<GetLogsC>();
  final buffer = calloc<Uint8>(4096);
  // Ép kiểu int → Int32 để khớp với C
  func(buffer, 4096 as Int32);
  final result = buffer.cast<Utf8>().toDartString();
  calloc.free(buffer);
  return result;
};

final IsRunningDart isMiningRunning = nativeLib
    .lookup<NativeFunction<IsRunningC>>('is_mining_running')
    .asFunction();
