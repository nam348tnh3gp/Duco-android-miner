// ==================== miner_bridge.dart ====================
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
    Int32 intensity,
    Pointer<Utf8> poolName,
);

typedef StopMiningC = Void Function();
typedef GetLogsC = Void Function(Pointer<Uint8> buffer, Int32 size);
typedef GetNewLogsC = Void Function(Pointer<Uint8> buffer, Int32 size);
typedef IsRunningC = Int32 Function();

typedef StartMiningDart = void Function(
    Pointer<Utf8> username,
    Pointer<Utf8> key,
    Pointer<Utf8> diff,
    Pointer<Utf8> rig,
    int threads,
    int nice,
    Pointer<Utf8> poolIp,
    int poolPort,
    int intensity,
    Pointer<Utf8> poolName,
);

typedef StopMiningDart = void Function();
typedef GetLogsDart = void Function(Pointer<Uint8> buffer, int size);
typedef GetNewLogsDart = void Function(Pointer<Uint8> buffer, int size);
typedef IsRunningDart = int Function();

final StartMiningDart _startMiningC = nativeLib
    .lookup<NativeFunction<StartMiningC>>('start_mining')
    .asFunction<StartMiningDart>();

final StopMiningDart _stopMiningC = nativeLib
    .lookup<NativeFunction<StopMiningC>>('stop_mining')
    .asFunction<StopMiningDart>();

final GetLogsDart _getLogsC = nativeLib
    .lookup<NativeFunction<GetLogsC>>('get_logs')
    .asFunction<GetLogsDart>();

final GetNewLogsDart _getNewLogsC = nativeLib
    .lookup<NativeFunction<GetNewLogsC>>('get_new_logs')
    .asFunction<GetNewLogsDart>();

final IsRunningDart _isRunningC = nativeLib
    .lookup<NativeFunction<IsRunningC>>('is_mining_running')
    .asFunction<IsRunningDart>();

void startMining(
  String username,
  String key,
  String diff,
  String rig,
  int threads,
  int nice,
  String poolIp,
  int poolPort,
  int intensity,
  String poolName,
) {
  final usernamePtr = username.toNativeUtf8();
  final keyPtr = key.toNativeUtf8();
  final diffPtr = diff.toNativeUtf8();
  final rigPtr = rig.toNativeUtf8();
  final poolIpPtr = poolIp.toNativeUtf8();
  final poolNamePtr = poolName.toNativeUtf8();

  _startMiningC(
    usernamePtr,
    keyPtr,
    diffPtr,
    rigPtr,
    threads,
    nice,
    poolIpPtr,
    poolPort,
    intensity,
    poolNamePtr,
  );

  calloc.free(usernamePtr);
  calloc.free(keyPtr);
  calloc.free(diffPtr);
  calloc.free(rigPtr);
  calloc.free(poolIpPtr);
  calloc.free(poolNamePtr);
}

void stopMining() {
  _stopMiningC();
}

String getLogsNative() {
  final buffer = calloc<Uint8>(4096);
  _getLogsC(buffer, 4096);
  final result = buffer.cast<Utf8>().toDartString();
  calloc.free(buffer);
  return result;
}

String getNewLogsNative() {
  final buffer = calloc<Uint8>(8192);
  _getNewLogsC(buffer, 8192);
  final result = buffer.cast<Utf8>().toDartString();
  calloc.free(buffer);
  return result;
}

bool isMiningRunning() {
  return _isRunningC() == 1;
}