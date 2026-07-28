// ==================== miner_task_handler.dart ====================
// GIỐNG HỆT TUNNEL_TASK_HANDLER - CHỈ GIỮ WAKELOCK VÀ NOTIFICATION
import 'dart:async';
import 'dart:isolate';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

@pragma('vm:entry-point')
void startMinerService() {
  FlutterForegroundTask.setTaskHandler(MinerTaskHandler());
}

class MinerTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, SendPort? sendPort) async {
    await WakelockPlus.enable();
  }

  @override
  Future<void> onEvent(DateTime timestamp, SendPort? sendPort) async {
    // Không cần xử lý
  }

  @override
  Future<void> onStop(DateTime timestamp) async {
    await WakelockPlus.disable();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, SendPort? sendPort) async {
    await WakelockPlus.disable();
  }

  @override
  void onButtonPressed(String id) {}

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }
}