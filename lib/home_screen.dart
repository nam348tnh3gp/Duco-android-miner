// ==================== home_screen.dart ====================
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'miner_bridge.dart' as miner;
import 'miner_task_handler.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _usernameCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _difficultyCtrl = TextEditingController(text: 'MEDIUM');
  final _rigCtrl = TextEditingController(text: 'FlutterRig');
  final _threadsCtrl = TextEditingController(text: '1');
  final _niceCtrl = TextEditingController(text: '0');
  final _intensityCtrl = TextEditingController(text: '95');

  String _logText = '';
  bool _isMining = false;
  Timer? _timer;
  Timer? _uptimeTimer;
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = false;
  
  bool _isUserScrolling = false;
  double _lastScrollOffset = 0.0;

  double _hashrate = 0.0;
  String _uptime = '00:00:00';
  DateTime? _startTime;

  @override
  void initState() {
    super.initState();
    _loadConfig();
    _setupScrollListener();
    _startUptimeTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _uptimeTimer?.cancel();
    miner.stopMining();
    _usernameCtrl.dispose();
    _keyCtrl.dispose();
    _difficultyCtrl.dispose();
    _rigCtrl.dispose();
    _threadsCtrl.dispose();
    _niceCtrl.dispose();
    _intensityCtrl.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _setupScrollListener() {
    _scrollController.addListener(() {
      final maxScroll = _scrollController.position.maxScrollExtent;
      final currentScroll = _scrollController.position.pixels;
      
      if (maxScroll - currentScroll < 50) {
        _isUserScrolling = false;
      } else if (currentScroll < _lastScrollOffset - 10) {
        _isUserScrolling = true;
      }
      _lastScrollOffset = currentScroll;
    });
  }

  void _startUptimeTimer() {
    _uptimeTimer?.cancel();
    _uptimeTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_isMining && _startTime != null) {
        _updateUptime();
      }
    });
  }

  void _updateUptime() {
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

  Future<void> _loadConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _usernameCtrl.text = prefs.getString('username') ?? '';
        _keyCtrl.text = prefs.getString('mining_key') ?? '';
        _difficultyCtrl.text = prefs.getString('difficulty') ?? 'MEDIUM';
        _rigCtrl.text = prefs.getString('rig_identifier') ?? 'FlutterRig';
        _threadsCtrl.text = prefs.getInt('thread_count')?.toString() ?? '1';
        _niceCtrl.text = prefs.getInt('nice_level')?.toString() ?? '0';
        _intensityCtrl.text = prefs.getInt('intensity')?.toString() ?? '95';
      });
    } catch (e) {
      _addLog('⚠️ Failed to load config: $e');
    }
  }

  Future<void> _saveConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('username', _usernameCtrl.text.trim());
      await prefs.setString('mining_key', _keyCtrl.text.trim());
      await prefs.setString('difficulty', _difficultyCtrl.text.trim());
      await prefs.setString('rig_identifier', _rigCtrl.text.trim());
      await prefs.setInt('thread_count', int.tryParse(_threadsCtrl.text) ?? 1);
      await prefs.setInt('nice_level', int.tryParse(_niceCtrl.text) ?? 0);
      await prefs.setInt('intensity', int.tryParse(_intensityCtrl.text) ?? 95);
      
      _addLog('✅ Config saved successfully!');
    } catch (e) {
      _addLog('❌ Failed to save config: $e');
    }
  }

  void _addLog(String msg) {
    setState(() {
      _logText = _logText + msg + '\n';
      final lines = _logText.split('\n');
      if (lines.length > 500) {
        _logText = lines.sublist(lines.length - 500).join('\n');
      }
    });
    _autoScrollIfNeeded();
  }

  void _autoScrollIfNeeded() {
    if (!_isUserScrolling) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  // ========== START MINING (GIỐNG CÁCH TUNNEL) ==========
  Future<void> _startMining() async {
    if (_usernameCtrl.text.trim().isEmpty) {
      _showSnackBar('❌ Please enter Username!', Colors.red);
      return;
    }
    if (_keyCtrl.text.trim().isEmpty) {
      _showSnackBar('❌ Please enter Mining Key!', Colors.red);
      return;
    }

    int intensity = int.tryParse(_intensityCtrl.text) ?? 95;
    if (intensity < 1) intensity = 1;
    if (intensity > 100) intensity = 100;
    _intensityCtrl.text = intensity.toString();

    setState(() => _isLoading = true);

    try {
      await _saveConfig();

      _addLog('🌐 Fetching pool from server...');
      final resp = await http.get(
        Uri.parse('https://server.duinocoin.com/getPool'),
      ).timeout(const Duration(seconds: 10));
      
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      final data = jsonDecode(resp.body);
      final ip = data['ip'] as String;
      final port = data['port'] as int;
      final poolName = data['name'] as String? ?? 'Duino-Coin Pool';
      _addLog('✅ Pool: $poolName ($ip:$port)');

      final username = _usernameCtrl.text.trim();
      final key = _keyCtrl.text.trim();
      final difficulty = _difficultyCtrl.text.trim();
      final rig = _rigCtrl.text.trim();
      final threads = int.tryParse(_threadsCtrl.text) ?? 1;
      final nice = int.tryParse(_niceCtrl.text) ?? 0;

      _addLog('⛏️ Starting mining with $threads thread(s), intensity $intensity%...');

      // ====== BƯỚC 1: START MINING TRỰC TIẾP (GIỐNG TUNNEL START PROCESS) ======
      miner.startMining(
        username, key, difficulty, rig, threads, nice, ip, port, intensity, poolName
      );

      // ====== BƯỚC 2: KHỞI ĐỘNG FOREGROUND SERVICE (ĐỂ GIỮ APP NỀN) ======
      final isRunning = await FlutterForegroundTask.isRunningService;
      if (!isRunning) {
        await FlutterForegroundTask.startService(
          notificationTitle: '⛏️ Duino Miner',
          notificationText: 'Mining in background...',
          callback: startMinerService,
        );
      }

      setState(() {
        _isMining = true;
        _startTime = DateTime.now();
        _hashrate = 0.0;
        _uptime = '00:00:00';
        _isUserScrolling = false;
      });

      // ====== BƯỚC 3: TIMER POLL LOG VÀ UPDATE NOTIFICATION (UI TỰ LÀM) ======
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(milliseconds: 500), (t) {
        final logs = miner.getNewLogsNative();
        if (logs.isNotEmpty) {
          _parseLogs(logs);
        }
        
        // Update notification từ UI (giống tunnel update URL)
        FlutterForegroundTask.updateService(
          notificationTitle: '⛏️ Duino Miner',
          notificationText: '⚡ ${_formatHashrate(_hashrate)} | ⏱️ $_uptime',
        );
      });

      _showSnackBar('⛏️ Mining started in background!', Colors.green);
      
    } catch (e) {
      _addLog('❌ Error: $e');
      _showSnackBar('❌ Failed to start mining: $e', Colors.red);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _parseLogs(String logs) {
    if (logs.trim().isEmpty) return;

    setState(() {
      _logText = _logText + logs + '\n';
      final lines = _logText.split('\n');
      if (lines.length > 500) {
        _logText = lines.sublist(lines.length - 500).join('\n');
      }
    });
    
    _autoScrollIfNeeded();

    final lines = logs.split('\n');
    double lastHashrate = 0.0;

    for (final line in lines) {
      if (line.contains('Accepted') || line.contains('Block found')) {
        final match = RegExp(r'(\d+\.?\d*)\s+(H/s|kH/s|MH/s|GH/s)').firstMatch(line);
        if (match != null) {
          final value = double.tryParse(match.group(1) ?? '0') ?? 0;
          final unit = match.group(2) ?? 'H/s';
          if (unit == 'kH/s') lastHashrate = value * 1000;
          else if (unit == 'MH/s') lastHashrate = value * 1000000;
          else if (unit == 'GH/s') lastHashrate = value * 1000000000;
          else lastHashrate = value;
        }
      }
    }

    setState(() {
      if (lastHashrate > 0) _hashrate = lastHashrate;
    });
  }

  // ========== STOP MINING (GIỐNG TUNNEL STOP PROCESS) ==========
  void _stopMining() {
    _addLog('🛑 Stopping mining...');
    
    // Dừng mining trực tiếp
    miner.stopMining();
    
    _timer?.cancel();
    
    // Dừng service sau 2 giây
    Future.delayed(const Duration(seconds: 2), () {
      FlutterForegroundTask.stopService();
    });
    
    setState(() {
      _isMining = false;
    });
    _showSnackBar('🛑 Mining stopped', Colors.orange);
  }

  void _clearLog() async {
    setState(() {
      _logText = '';
      _hashrate = 0.0;
      _uptime = '00:00:00';
      _isUserScrolling = false;
    });
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('miner_log');
    _showSnackBar('🗑️ Log cleared', Colors.grey);
  }

  void _copyLog() async {
    if (_logText.isEmpty) {
      _showSnackBar('📋 Log is empty', Colors.grey);
      return;
    }
    await Clipboard.setData(ClipboardData(text: _logText));
    _showSnackBar('✅ Log copied!', Colors.green);
  }

  void _showSnackBar(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Widget _ansiToRichText(String text, {TextStyle? baseStyle}) {
    final defaultStyle = baseStyle ?? const TextStyle(
      fontFamily: 'monospace',
      fontSize: 12,
      height: 1.4,
      color: Colors.white,
    );

    final List<TextSpan> spans = [];
    final StringBuffer buffer = StringBuffer();
    TextStyle currentStyle = defaultStyle;

    int i = 0;
    while (i < text.length) {
      if (text[i] == '\x1B' && i + 1 < text.length && text[i + 1] == '[') {
        if (buffer.isNotEmpty) {
          spans.add(TextSpan(text: buffer.toString(), style: currentStyle));
          buffer.clear();
        }

        int j = i + 2;
        String code = '';
        while (j < text.length && text[j] != 'm') {
          code += text[j];
          j++;
        }
        if (j < text.length && text[j] == 'm') {
          final codes = code.split(';');
          for (final c in codes) {
            if (c == '0' || c.isEmpty) {
              currentStyle = defaultStyle;
            } else if (c == '1') {
              currentStyle = currentStyle.copyWith(fontWeight: FontWeight.bold);
            } else if (c == '2') {
              currentStyle = currentStyle.copyWith(fontWeight: FontWeight.w300);
            } else if (c == '3') {
              currentStyle = currentStyle.copyWith(fontStyle: FontStyle.italic);
            } else if (c == '4') {
              currentStyle = currentStyle.copyWith(decoration: TextDecoration.underline);
            } else if (c == '30') {
              currentStyle = currentStyle.copyWith(color: Colors.black);
            } else if (c == '31') {
              currentStyle = currentStyle.copyWith(color: Colors.red);
            } else if (c == '32') {
              currentStyle = currentStyle.copyWith(color: Colors.green);
            } else if (c == '33') {
              currentStyle = currentStyle.copyWith(color: Colors.orange);
            } else if (c == '34') {
              currentStyle = currentStyle.copyWith(color: Colors.blue);
            } else if (c == '35') {
              currentStyle = currentStyle.copyWith(color: Colors.purple);
            } else if (c == '36') {
              currentStyle = currentStyle.copyWith(color: Colors.cyan);
            } else if (c == '37') {
              currentStyle = currentStyle.copyWith(color: Colors.white);
            } else if (c == '90') {
              currentStyle = currentStyle.copyWith(color: Colors.grey.shade600);
            } else if (c == '91') {
              currentStyle = currentStyle.copyWith(color: Colors.red.shade300);
            } else if (c == '92') {
              currentStyle = currentStyle.copyWith(color: Colors.green.shade300);
            } else if (c == '93') {
              currentStyle = currentStyle.copyWith(color: Colors.yellow.shade300);
            } else if (c == '94') {
              currentStyle = currentStyle.copyWith(color: Colors.blue.shade300);
            } else if (c == '95') {
              currentStyle = currentStyle.copyWith(color: Colors.purple.shade300);
            } else if (c == '96') {
              currentStyle = currentStyle.copyWith(color: Colors.cyan.shade300);
            }
          }
          i = j + 1;
          continue;
        }
      }
      buffer.write(text[i]);
      i++;
    }

    if (buffer.isNotEmpty) {
      spans.add(TextSpan(text: buffer.toString(), style: currentStyle));
    }

    return RichText(
      text: TextSpan(style: defaultStyle, children: spans),
    );
  }

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
            icon: const Icon(Icons.copy, size: 20),
            onPressed: _copyLog,
            tooltip: 'Copy log',
          ),
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
                  _buildStatsSection(),
                  
                  const SizedBox(height: 16),
                  const Divider(),
                  
                  const Text(
                    '⚙️ Configuration',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  
                  TextField(
                    controller: _usernameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Username *',
                      hintText: 'Enter your username',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.person),
                    ),
                    enabled: !_isMining,
                  ),
                  const SizedBox(height: 10),
                  
                  TextField(
                    controller: _keyCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Mining Key *',
                      hintText: 'Enter your mining key',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.key),
                    ),
                    obscureText: true,
                    enabled: !_isMining,
                  ),
                  const SizedBox(height: 10),
                  
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
                  
                  TextField(
                    controller: _rigCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Rig Identifier',
                      hintText: 'Your rig name',
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
                            prefixIcon: Icon(Icons.memory),
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
                  const SizedBox(height: 10),
                  
                  TextField(
                    controller: _intensityCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Intensity (%)',
                      hintText: '1-100',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.tune),
                    ),
                    enabled: !_isMining,
                  ),
                  
                  const SizedBox(height: 16),
                  
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
                          label: Text(_isLoading ? 'STARTING...' : 'START'),
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
                  
                  Row(
                    children: [
                      const Icon(Icons.article, size: 20, color: Colors.blue),
                      const SizedBox(width: 8),
                      const Text(
                        'Logs',
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
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey.shade700),
                    ),
                    child: SingleChildScrollView(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(8),
                      child: _logText.isEmpty
                          ? const Text(
                              'No logs yet...',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                            )
                          : _ansiToRichText(
                              _logText,
                              baseStyle: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                height: 1.4,
                                color: Colors.white,
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
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildStatItem(
            'Hashrate',
            _hashrate > 0 ? _formatHashrate(_hashrate) : '0 H/s',
            Icons.speed,
            Colors.yellow.shade200,
          ),
          _buildStatItem(
            'Uptime',
            _uptime,
            Icons.timer,
            Colors.cyan.shade200,
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, String value, IconData icon, Color iconColor) {
    return Column(
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: iconColor),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 14,
                fontWeight: FontWeight.w500,
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