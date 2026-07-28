// miner_task_handler.dart
import 'dart:async';
import 'dart:isolate';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'miner_bridge.dart' as miner; // << thêm import

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
    // Lấy log mới từ native và cập nhật notification
    try {
      final logs = miner.getNewLogsNative();
      if (logs.isNotEmpty) {
        final hashrate = _parseHashrateFromLogs(logs);
        await FlutterForegroundTask.updateService(
          notificationTitle: '⛏️ Duino Miner',
          notificationText: '⚡ ${_formatHashrate(hashrate)} | Mining...',
        );
      }
    } catch (e) {
      // Bỏ qua lỗi, không làm gián đoạn service
    }
  }

  String _formatHashrate(double h) {
    if (h >= 1e9) return '${(h / 1e9).toStringAsFixed(2)} GH/s';
    if (h >= 1e6) return '${(h / 1e6).toStringAsFixed(2)} MH/s';
    if (h >= 1e3) return '${(h / 1e3).toStringAsFixed(2)} kH/s';
    return '${h.toStringAsFixed(2)} H/s';
  }

  double _parseHashrateFromLogs(String logs) {
    double hashrate = 0.0;
    final lines = logs.split('\n');
    for (final line in lines) {
      if (line.contains('Accepted') || line.contains('Block found')) {
        final match = RegExp(r'(\d+\.?\d*)\s+(H/s|kH/s|MH/s|GH/s)').firstMatch(line);
        if (match != null) {
          final value = double.tryParse(match.group(1) ?? '0') ?? 0;
          final unit = match.group(2) ?? 'H/s';
          if (unit == 'kH/s') hashrate = value * 1000;
          else if (unit == 'MH/s') hashrate = value * 1000000;
          else if (unit == 'GH/s') hashrate = value * 1000000000;
          else hashrate = value;
        }
      }
    }
    return hashrate;
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