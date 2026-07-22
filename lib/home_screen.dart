import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'miner_bridge.dart' as miner;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Controllers cho các trường nhập
  final _usernameCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _difficultyCtrl = TextEditingController(text: 'LOW');
  final _rigCtrl = TextEditingController(text: 'FlutterRig');
  final _threadsCtrl = TextEditingController(text: '1');
  final _niceCtrl = TextEditingController(text: '0');

  String _logText = '';
  bool _isMining = false;
  Timer? _timer;
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = false;

  // Thống kê
  int _acceptedShares = 0;
  int _rejectedShares = 0;
  double _hashrate = 0.0;
  String _uptime = '00:00:00';
  DateTime? _startTime;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _timer?.cancel();
    miner.stopMining();
    _usernameCtrl.dispose();
    _keyCtrl.dispose();
    _difficultyCtrl.dispose();
    _rigCtrl.dispose();
    _threadsCtrl.dispose();
    _niceCtrl.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ========== LOAD CONFIG TỪ SHARED PREFERENCES ==========
  Future<void> _loadConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _usernameCtrl.text = prefs.getString('username') ?? '';
        _keyCtrl.text = prefs.getString('mining_key') ?? '';
        _difficultyCtrl.text = prefs.getString('difficulty') ?? 'LOW';
        _rigCtrl.text = prefs.getString('rig_identifier') ?? 'FlutterRig';
        _threadsCtrl.text = prefs.getInt('thread_count')?.toString() ?? '1';
        _niceCtrl.text = prefs.getInt('nice_level')?.toString() ?? '0';
      });
    } catch (e) {
      _addLog('⚠️ Không thể load config: $e');
    }
  }

  // ========== SAVE CONFIG TO SHARED PREFERENCES ==========
  Future<void> _saveConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('username', _usernameCtrl.text.trim());
      await prefs.setString('mining_key', _keyCtrl.text.trim());
      await prefs.setString('difficulty', _difficultyCtrl.text.trim());
      await prefs.setString('rig_identifier', _rigCtrl.text.trim());
      await prefs.setInt('thread_count', int.tryParse(_threadsCtrl.text) ?? 1);
      await prefs.setInt('nice_level', int.tryParse(_niceCtrl.text) ?? 0);
      
      _addLog('✅ Đã lưu cấu hình thành công!');
    } catch (e) {
      _addLog('❌ Lỗi lưu config: $e');
    }
  }

  // ========== THÊM LOG ==========
  void _addLog(String msg) {
    setState(() {
      _logText = _logText + msg + '\n';
      // Giới hạn log
      final lines = _logText.split('\n');
      if (lines.length > 200) {
        _logText = lines.sublist(lines.length - 200).join('\n');
      }
    });
    // Auto scroll
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ========== START MINING ==========
  Future<void> _startMining() async {
    // Validate inputs
    if (_usernameCtrl.text.trim().isEmpty) {
      _showSnackBar('❌ Vui lòng nhập Username!', Colors.red);
      return;
    }
    if (_keyCtrl.text.trim().isEmpty) {
      _showSnackBar('❌ Vui lòng nhập Mining Key!', Colors.red);
      return;
    }

    setState(() => _isLoading = true);

    try {
      // 1. Lưu config
      await _saveConfig();

      // 2. Lấy pool từ server
      _addLog('🌐 Đang lấy pool từ server...');
      final resp = await http.get(
        Uri.parse('https://server.duinocoin.com/getPool'),
      ).timeout(const Duration(seconds: 10));
      
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      final data = jsonDecode(resp.body);
      final ip = data['ip'] as String;
      final port = data['port'] as int;
      _addLog('✅ Pool: $ip:$port');

      // 3. Lấy thông số
      final username = _usernameCtrl.text.trim();
      final key = _keyCtrl.text.trim();
      final difficulty = _difficultyCtrl.text.trim();
      final rig = _rigCtrl.text.trim();
      final threads = int.tryParse(_threadsCtrl.text) ?? 1;
      final nice = int.tryParse(_niceCtrl.text) ?? 0;

      // 4. Gọi native start
      _addLog('⛏️ Khởi động mining với $threads thread(s)...');
      miner.startMining(username, key, difficulty, rig, threads, nice, ip, port);
      
      setState(() {
        _isMining = true;
        _startTime = DateTime.now();
        _acceptedShares = 0;
        _rejectedShares = 0;
        _hashrate = 0.0;
      });

      // 5. Bắt đầu polling log
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(milliseconds: 500), (t) {
        final logs = miner.getLogsNative();
        if (logs.isNotEmpty) {
          // Phân tích log để cập nhật thống kê
          _parseLogs(logs);
        }
      });

      _showSnackBar('⛏️ Mining started!', Colors.green);
      
    } catch (e) {
      _addLog('❌ Lỗi: $e');
      _showSnackBar('❌ Không thể start mining: $e', Colors.red);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // ========== PARSE LOG ==========
  void _parseLogs(String logs) {
    final lines = logs.split('\n');
    for (final line in lines) {
      if (line.contains('Share accepted')) {
        setState(() {
          _acceptedShares++;
          // Trích xuất hashrate từ log
          final match = RegExp(r'(\d+\.?\d*)\s+(H/s|kH/s|MH/s|GH/s)').firstMatch(line);
          if (match != null) {
            final value = double.tryParse(match.group(1) ?? '0') ?? 0;
            final unit = match.group(2) ?? 'H/s';
            // Quy đổi về H/s
            if (unit == 'kH/s') _hashrate = value * 1000;
            else if (unit == 'MH/s') _hashrate = value * 1000000;
            else if (unit == 'GH/s') _hashrate = value * 1000000000;
            else _hashrate = value;
          }
        });
      } else if (line.contains('Rejected')) {
        setState(() => _rejectedShares++);
      }
    }
    // Cập nhật uptime
    if (_startTime != null) {
      final elapsed = DateTime.now().difference(_startTime!);
      final hours = elapsed.inHours.toString().padLeft(2, '0');
      final minutes = (elapsed.inMinutes % 60).toString().padLeft(2, '0');
      final seconds = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
      setState(() {
        _uptime = '$hours:$minutes:$seconds';
      });
    }
  }

  // ========== STOP MINING ==========
  void _stopMining() {
    _addLog('🛑 Đang dừng mining...');
    miner.stopMining();
    _timer?.cancel();
    setState(() {
      _isMining = false;
    });
    _showSnackBar('🛑 Mining stopped', Colors.orange);
  }

  // ========== CLEAR LOG ==========
  void _clearLog() {
    setState(() {
      _logText = '';
      _acceptedShares = 0;
      _rejectedShares = 0;
      _hashrate = 0.0;
      _uptime = '00:00:00';
    });
  }

  // ========== SHOW SNACKBAR ==========
  void _showSnackBar(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ========== BUILD UI ==========
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '⛏️ Duino Miner',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
        elevation: 4,
        actions: [
          IconButton(
            icon: const Icon(Icons.clear_all),
            onPressed: _clearLog,
            tooltip: 'Clear log',
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ====== THỐNG KÊ ======
                  _buildStatsSection(),
                  
                  const SizedBox(height: 16),
                  const Divider(),
                  
                  // ====== CẤU HÌNH ======
                  const Text(
                    '⚙️ Cấu hình',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  
                  // Username
                  TextField(
                    controller: _usernameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Username *',
                      hintText: 'Nhập username của bạn',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.person),
                    ),
                    enabled: !_isMining,
                  ),
                  const SizedBox(height: 10),
                  
                  // Mining Key
                  TextField(
                    controller: _keyCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Mining Key *',
                      hintText: 'Nhập mining key',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.key),
                    ),
                    obscureText: true,
                    enabled: !_isMining,
                  ),
                  const SizedBox(height: 10),
                  
                  // Difficulty
                  DropdownButtonFormField<String>(
                    value: _difficultyCtrl.text,
                    decoration: const InputDecoration(
                      labelText: 'Difficulty',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.speed),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'LOW', child: Text('🟢 LOW')),
                      DropdownMenuItem(value: 'MEDIUM', child: Text('🟡 MEDIUM')),
                      DropdownMenuItem(value: 'HIGH', child: Text('🔴 HIGH')),
                    ],
                    onChanged: _isMining ? null : (value) {
                      setState(() => _difficultyCtrl.text = value!);
                    },
                  ),
                  const SizedBox(height: 10),
                  
                  // Rig Identifier
                  TextField(
                    controller: _rigCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Rig Identifier',
                      hintText: 'Tên rig của bạn',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.computer),
                    ),
                    enabled: !_isMining,
                  ),
                  const SizedBox(height: 10),
                  
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _threadsCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Threads',
                            hintText: '1-100',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.cpu),
                          ),
                          enabled: !_isMining,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _niceCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Nice Level',
                            hintText: '-20..19',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.speed),
                          ),
                          enabled: !_isMining,
                        ),
                      ),
                    ],
                  ),
                  
                  const SizedBox(height: 16),
                  
                  // ====== BUTTONS ======
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: (_isMining || _isLoading) ? null : _startMining,
                          icon: _isLoading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.play_arrow),
                          label: Text(_isLoading ? 'ĐANG KHỞI ĐỘNG...' : 'START'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            minimumSize: const Size(double.infinity, 50),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _isMining ? _stopMining : null,
                          icon: const Icon(Icons.stop),
                          label: const Text('STOP'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            minimumSize: const Size(double.infinity, 50),
                          ),
                        ),
                      ),
                    ],
                  ),
                  
                  const SizedBox(height: 16),
                  const Divider(),
                  
                  // ====== LOG ======
                  Row(
                    children: [
                      const Icon(Icons.article, size: 20, color: Colors.blue),
                      const SizedBox(width: 8),
                      const Text(
                        '📊 Logs',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      if (_isMining)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.green,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Text(
                            '● RUNNING',
                            style: TextStyle(color: Colors.white, fontSize: 12),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 200,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    child: SingleChildScrollView(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        _logText.isEmpty ? 'Chưa có log...' : _logText,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ====== WIDGET THỐNG KÊ ======
  Widget _buildStatsSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.deepPurple.shade700, Colors.purple.shade300],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.deepPurple.withOpacity(0.3),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildStatItem(
                '✅ Accepted',
                '$_acceptedShares',
                Icons.check_circle,
                Colors.green.shade200,
              ),
              _buildStatItem(
                '❌ Rejected',
                '$_rejectedShares',
                Icons.cancel,
                Colors.red.shade200,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildStatItem(
                '⚡ Hashrate',
                _hashrate > 0 ? _formatHashrate(_hashrate) : '0 H/s',
                Icons.speed,
                Colors.yellow.shade200,
              ),
              _buildStatItem(
                '⏱️ Uptime',
                _uptime,
                Icons.timer,
                Colors.cyan.shade200,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, String value, IconData icon, Color color) {
    return Column(
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  String _formatHashrate(double h) {
    if (h >= 1e9) return '${(h / 1e9).toStringAsFixed(2)} GH/s';
    if (h >= 1e6) return '${(h / 1e6).toStringAsFixed(2)} MH/s';
    if (h >= 1e3) return '${(h / 1e3).toStringAsFixed(2)} kH/s';
    return '${h.toStringAsFixed(2)} H/s';
  }
}
