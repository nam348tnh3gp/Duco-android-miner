import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'dart:io' show Platform;

final DynamicLibrary nativeLib = Platform.isAndroid
    ? DynamicLibrary.open("libminer.so")
    : DynamicLibrary.process();

// ========== ĐỊNH NGHĨA KIỂU C ==========
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

typedef StopMiningC = Void Function();

typedef GetLogsC = Void Function(Pointer<Uint8> buffer, Int32 size);

typedef IsRunningC = Int32 Function();

// ========== ĐỊNH NGHĨA KIỂU DART TƯƠNG ỨNG ==========
typedef StartMiningDart = void Function(
    Pointer<Utf8> username,
    Pointer<Utf8> key,
    Pointer<Utf8> diff,
    Pointer<Utf8> rig,
    int threads,
    int nice,
    Pointer<Utf8> poolIp,
    int poolPort,
);

typedef StopMiningDart = void Function();
typedef GetLogsDart = void Function(Pointer<Uint8> buffer, int size);
typedef IsRunningDart = int Function();

// ========== LẤY HÀM TỪ THƯ VIỆN ==========
final StartMiningDart _startMiningC = nativeLib
    .lookup<NativeFunction<StartMiningC>>('start_mining')
    .asFunction<StartMiningDart>();

final StopMiningDart _stopMiningC = nativeLib
    .lookup<NativeFunction<StopMiningC>>('stop_mining')
    .asFunction<StopMiningDart>();

final GetLogsDart _getLogsC = nativeLib
    .lookup<NativeFunction<GetLogsC>>('get_logs')
    .asFunction<GetLogsDart>();

final IsRunningDart _isRunningC = nativeLib
    .lookup<NativeFunction<IsRunningC>>('is_mining_running')
    .asFunction<IsRunningDart>();

// ========== WRAPPER CHO DART (nhận kiểu Dart thông thường) ==========
void startMining(
  String username,
  String key,
  String diff,
  String rig,
  int threads,
  int nice,
  String poolIp,
  int poolPort,
) {
  final usernamePtr = username.toNativeUtf8();
  final keyPtr = key.toNativeUtf8();
  final diffPtr = diff.toNativeUtf8();
  final rigPtr = rig.toNativeUtf8();
  final poolIpPtr = poolIp.toNativeUtf8();

  _startMiningC(
    usernamePtr,
    keyPtr,
    diffPtr,
    rigPtr,
    threads,
    nice,
    poolIpPtr,
    poolPort,
  );

  calloc.free(usernamePtr);
  calloc.free(keyPtr);
  calloc.free(diffPtr);
  calloc.free(rigPtr);
  calloc.free(poolIpPtr);
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

bool isMiningRunning() {
  return _isRunningC() == 1;
}
