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

// ========== LẤY CON TRỎ HÀM TỪ THƯ VIỆN ==========
final StartMiningC _startMiningC = nativeLib
    .lookup<NativeFunction<StartMiningC>>('start_mining')
    .asFunction();

final StopMiningC _stopMiningC = nativeLib
    .lookup<NativeFunction<StopMiningC>>('stop_mining')
    .asFunction();

final GetLogsC _getLogsC = nativeLib
    .lookup<NativeFunction<GetLogsC>>('get_logs')
    .asFunction();

final IsRunningC _isRunningC = nativeLib
    .lookup<NativeFunction<IsRunningC>>('is_mining_running')
    .asFunction();

// ========== WRAPPER CHO DART (nhận kiểu Dart thông thường) ==========

/// Gọi C start_mining với chuỗi Dart
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
  // Chuyển String → Pointer<Utf8>
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
    threads as Int32,
    nice as Int32,
    poolIpPtr,
    poolPort as Int32,
  );

  // Giải phóng bộ nhớ ngay sau khi gọi (C đã copy dữ liệu)
  calloc.free(usernamePtr);
  calloc.free(keyPtr);
  calloc.free(diffPtr);
  calloc.free(rigPtr);
  calloc.free(poolIpPtr);
}

/// Gọi C stop_mining
void stopMining() {
  _stopMiningC();
}

/// Lấy log từ C, trả về String
String getLogsNative() {
  final buffer = calloc<Uint8>(4096);
  _getLogsC(buffer, 4096 as Int32);
  final result = buffer.cast<Utf8>().toDartString();
  calloc.free(buffer);
  return result;
}

/// Kiểm tra mining đang chạy
bool isMiningRunning() {
  return _isRunningC() == 1;
}
