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
  final _usernameCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _diffCtrl = TextEditingController(text: 'LOW');
  final _rigCtrl = TextEditingController(text: 'FlutterRig');
  final _threadsCtrl = TextEditingController(text: '1');
  final _niceCtrl = TextEditingController(text: '0');

  String _logText = '';
  bool _isMining = false;
  Timer? _timer;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _timer?.cancel();
    miner.stopMining();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _usernameCtrl.text = prefs.getString('username') ?? '';
      _keyCtrl.text = prefs.getString('key') ?? '';
      _diffCtrl.text = prefs.getString('difficulty') ?? 'LOW';
      _rigCtrl.text = prefs.getString('rig') ?? 'FlutterRig';
      _threadsCtrl.text = prefs.getInt('threads')?.toString() ?? '1';
      _niceCtrl.text = prefs.getInt('nice')?.toString() ?? '0';
    });
  }

  Future<void> _saveConfig() async {
    final prefs = await SharedPreferences.getInstance();
    prefs.setString('username', _usernameCtrl.text);
    prefs.setString('key', _keyCtrl.text);
    prefs.setString('difficulty', _diffCtrl.text);
    prefs.setString('rig', _rigCtrl.text);
    prefs.setInt('threads', int.tryParse(_threadsCtrl.text) ?? 1);
    prefs.setInt('nice', int.tryParse(_niceCtrl.text) ?? 0);
  }

  Future<void> _startMining() async {
    try {
      final resp = await http.get(
        Uri.parse('https://server.duinocoin.com/getPool'),
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      final data = jsonDecode(resp.body);
      final ip = data['ip'] as String;
      final port = data['port'] as int;

      await _saveConfig();

      final username = _usernameCtrl.text.trim();
      final key = _keyCtrl.text.trim();
      final diff = _diffCtrl.text.trim();
      final rig = _rigCtrl.text.trim();
      final threads = int.tryParse(_threadsCtrl.text) ?? 1;
      final nice = int.tryParse(_niceCtrl.text) ?? 0;

      if (username.isEmpty || key.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Vui lòng nhập username và key')),
        );
        return;
      }

      miner.startMining(username, key, diff, rig, threads, nice, ip, port);

      setState(() => _isMining = true);

      _timer?.cancel();
      _timer = Timer.periodic(const Duration(milliseconds: 500), (t) {
        final logs = miner.getLogsNative();
        if (logs.isNotEmpty) {
          setState(() => _logText = logs);
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
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('⛏️ Mining started!')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Lỗi lấy pool: $e')),
      );
    }
  }

  void _stopMining() {
    miner.stopMining();
    _timer?.cancel();
    setState(() => _isMining = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('🛑 Mining stopped')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('⛏️ Duino Miner', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.clear_all),
            onPressed: () => setState(() => _logText = ''),
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
                  const Text('⚙️ Cấu hình', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  TextField(controller: _usernameCtrl, decoration: const InputDecoration(labelText: 'Username', border: OutlineInputBorder())),
                  const SizedBox(height: 10),
                  TextField(controller: _keyCtrl, decoration: const InputDecoration(labelText: 'Mining Key', border: OutlineInputBorder()), obscureText: true),
                  const SizedBox(height: 10),
                  TextField(controller: _diffCtrl, decoration: const InputDecoration(labelText: 'Difficulty (LOW/MEDIUM/HIGH)', border: OutlineInputBorder())),
                  const SizedBox(height: 10),
                  TextField(controller: _rigCtrl, decoration: const InputDecoration(labelText: 'Rig ID', border: OutlineInputBorder())),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(child: TextField(controller: _threadsCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Threads', border: OutlineInputBorder()))),
                      const SizedBox(width: 10),
                      Expanded(child: TextField(controller: _niceCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Nice', border: OutlineInputBorder()))),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _isMining ? null : _startMining,
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('START'),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _isMining ? _stopMining : null,
                          icon: const Icon(Icons.stop),
                          label: const Text('STOP'),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
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
                      const Text('📊 Logs', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      const Spacer(),
                      if (_isMining)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(color: Colors.green, borderRadius: BorderRadius.circular(12)),
                          child: const Text('● RUNNING', style: TextStyle(color: Colors.white, fontSize: 12)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 220,
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
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.4),
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
}
