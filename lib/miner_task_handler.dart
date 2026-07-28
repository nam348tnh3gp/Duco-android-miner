import 'dart:async';
import 'dart:isolate';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'miner_bridge.dart' as miner;

@pragma('vm:entry-point')
void startMinerService() {
  FlutterForegroundTask.setTaskHandler(MinerTaskHandler());
}

class MinerTaskHandler extends TaskHandler {
  bool _isMining = false;
  bool _isStoppedByUser = false;
  Timer? _logTimer;
  DateTime? _startTime;
  int _acceptedShares = 0;
  double _currentHashrate = 0.0;
  double _avgHashrate = 0.0;
  double _totalHashrateSum = 0.0;
  int _hashrateCount = 0;
  SharedPreferences? _prefs;
  String _poolName = '';
  int _threads = 1;
  SendPort? _sendPort;

  @override
  Future<void> onStart(DateTime timestamp, SendPort? sendPort) async {
    _prefs = await SharedPreferences.getInstance();
    _sendPort = sendPort;
    await WakelockPlus.enable();
    
    // Gửi thông báo service đã start
    _sendPort?.send({'event': 'service_started'});
  }

  @override
  Future<void> onEvent(DateTime timestamp, SendPort? sendPort) async {
    // Không cần xử lý
  }

  @override
  Future<void> onStop(DateTime timestamp) async {
    _stopMining(clearLog: false);
    await WakelockPlus.disable();
    _sendPort?.send({'event': 'service_stopped'});
  }

  @override
  Future<void> onDestroy(DateTime timestamp, SendPort? sendPort) async {
    _stopMining(clearLog: _isStoppedByUser);
    await WakelockPlus.disable();
  }

  @override
  void onButtonPressed(String id) {}

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }

  // ====== MỚI: Nhận dữ liệu từ UI qua SendPort ======
  @override
  void onReceiveData(Object data) {
    final args = data as Map<String, dynamic>;
    final action = args['action'];

    if (action == 'start') {
      _startMining(args);
    } else if (action == 'stop') {
      _stopMining(clearLog: false);
    }
  }

  void _startMining(Map<String, dynamic> args) {
    if (_isMining) return;

    final username = args['username'] as String;
    final key = args['key'] as String;
    final diff = args['diff'] as String;
    final rig = args['rig'] as String;
    final threads = args['threads'] as int;
    final nice = args['nice'] as int;
    final poolIp = args['poolIp'] as String;
    final poolPort = args['poolPort'] as int;
    final intensity = args['intensity'] as int;
    final poolName = args['poolName'] as String;

    miner.startMining(
      username, key, diff, rig, threads, nice,
      poolIp, poolPort, intensity, poolName,
    );

    _isMining = true;
    _isStoppedByUser = false;
    _startTime = DateTime.now();
    _poolName = poolName;
    _threads = threads;
    _acceptedShares = 0;
    _currentHashrate = 0.0;
    _avgHashrate = 0.0;
    _totalHashrateSum = 0.0;
    _hashrateCount = 0;

    FlutterForegroundTask.updateService(
      notificationTitle: '⛏️ Duino Miner',
      notificationText: 'Mining started...',
    );

    _sendPort?.send({'event': 'mining_started'});

    _logTimer = Timer.periodic(const Duration(milliseconds: 500), (t) {
      _pollLogsAndUpdateNotification();
    });
  }

  void _stopMining({bool clearLog = false}) {
    if (!_isMining && !clearLog) return;
    if (_isMining) {
      miner.stopMining();
      _isMining = false;
      _logTimer?.cancel();
    }
    if (clearLog) {
      _clearLog();
    }
    _isStoppedByUser = true;

    FlutterForegroundTask.updateService(
      notificationTitle: '⛏️ Duino Miner',
      notificationText: 'Mining stopped',
    );

    _sendPort?.send({'event': 'mining_stopped'});
  }

  void _clearLog() {
    _prefs?.remove('miner_log');
    _acceptedShares = 0;
    _currentHashrate = 0.0;
    _avgHashrate = 0.0;
    _totalHashrateSum = 0.0;
    _hashrateCount = 0;
  }

  void _pollLogsAndUpdateNotification() {
    final logs = miner.getNewLogsNative();
    if (logs.isNotEmpty) {
      final currentLog = _prefs?.getString('miner_log') ?? '';
      _prefs?.setString('miner_log', currentLog + logs + '\n');

      final lines = logs.split('\n');
      for (final line in lines) {
        if (line.contains('Accepted') || line.contains('Block found')) {
          _acceptedShares++;
          final totalMatch = RegExp(r'\((\d+\.?\d*)\s+(H/s|kH/s|MH/s|GH/s)\s+total\)').firstMatch(line);
          if (totalMatch != null) {
            final value = double.tryParse(totalMatch.group(1) ?? '0') ?? 0;
            final unit = totalMatch.group(2) ?? 'H/s';
            double totalHashrate;
            if (unit == 'kH/s') totalHashrate = value * 1000;
            else if (unit == 'MH/s') totalHashrate = value * 1000000;
            else if (unit == 'GH/s') totalHashrate = value * 1000000000;
            else totalHashrate = value;

            _currentHashrate = totalHashrate;
            _totalHashrateSum += totalHashrate;
            _hashrateCount++;
            _avgHashrate = _totalHashrateSum / _hashrateCount;
          }
        }
      }

      final elapsed = DateTime.now().difference(_startTime!);
      final hours = elapsed.inHours.toString().padLeft(2, '0');
      final minutes = (elapsed.inMinutes % 60).toString().padLeft(2, '0');
      final seconds = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
      final uptime = '$hours:$minutes:$seconds';

      final currentStr = _formatHashrate(_currentHashrate);
      final avgStr = _formatHashrate(_avgHashrate);

      final msg = '⚡ $currentStr | 📊 $avgStr | ✅ $_acceptedShares | 🧵 $_threads | ⏱️ $uptime | 🌐 $_poolName';

      FlutterForegroundTask.updateService(
        notificationTitle: '⛏️ Duino Miner',
        notificationText: msg,
      );

      // Gửi log về UI
      _sendPort?.send({
        'event': 'log_update',
        'logs': logs,
        'hashrate': _currentHashrate,
        'accepted': _acceptedShares,
        'uptime': uptime,
      });
    }
  }

  String _formatHashrate(double h) {
    if (h >= 1e9) return '${(h / 1e9).toStringAsFixed(2)} GH/s';
    if (h >= 1e6) return '${(h / 1e6).toStringAsFixed(2)} MH/s';
    if (h >= 1e3) return '${(h / 1e3).toStringAsFixed(2)} kH/s';
    return '${h.toStringAsFixed(2)} H/s';
  }
}