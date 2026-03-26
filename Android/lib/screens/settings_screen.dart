// lib/screens/settings_screen.dart
// 伺服器連線設定：貼上網址 → 立即連接

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../core/constants.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _urlCtrl  = TextEditingController();
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController();
  bool _secure      = false;
  bool _connecting  = false;
  bool _showIpMode  = false;   // 展開進階 IP 模式

  @override
  void initState() {
    super.initState();
    final app = context.read<AppProvider>();
    // 預填目前已儲存的連線設定
    if (app.baseUrl.isNotEmpty && AppConstants.isFullUrl(app.baseUrl)) {
      _urlCtrl.text = app.baseUrl;
    }
    _hostCtrl.text = app.host;
    _portCtrl.text = app.port.toString();
    _secure        = app.secure;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<AppProvider>().speak(
          '伺服器連線設定。輸入網址後點擊立即連接。往左滑動返回首頁。',
        );
      }
    });
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    super.dispose();
  }

  // ── 連接邏輯 ─────────────────────────────────────────────────────────────
  Future<void> _connect() async {
    FocusScope.of(context).unfocus();

    String baseUrl = '';
    String host;
    int    port;

    if (!_showIpMode) {
      // URL 模式
      baseUrl = _urlCtrl.text.trim();
      if (baseUrl.isEmpty) {
        _showSnack('請輸入伺服器網址');
        return;
      }
      if (!AppConstants.isFullUrl(baseUrl)) {
        _showSnack('網址必須以 http:// 或 https:// 開頭');
        return;
      }
      final parsed = AppConstants.parseUrl(baseUrl);
      host    = parsed.host;
      port    = parsed.port;
      _secure = parsed.secure;
    } else {
      // IP 模式
      host = _hostCtrl.text.trim();
      port = int.tryParse(_portCtrl.text.trim()) ?? AppConstants.defaultPort;
      if (host.isEmpty) {
        _showSnack('請輸入伺服器 IP');
        return;
      }
    }

    setState(() => _connecting = true);
    final app = context.read<AppProvider>();
    await app.updateServerSettings(host, port, secure: _secure, baseUrl: baseUrl);

    bool ok = false;
    try {
      ok = await app.api.healthCheck();
    } catch (_) {}

    if (!mounted) return;
    setState(() => _connecting = false);

    if (ok) {
      final nav = Navigator.of(context);
      await app.startAllServices();
      if (!mounted) return;
      nav.pushReplacementNamed('/blind');
    } else {
      final display = baseUrl.isNotEmpty ? baseUrl : '$host:$port';
      _showSnack('無法連線到 $display，請確認網址與伺服器狀態');
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── UI ───────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppProvider>();
    final currentUrl = app.baseUrl.isNotEmpty
        ? app.baseUrl
        : (app.host.isNotEmpty ? '${app.host}:${app.port}' : '尚未設定');

    return GestureDetector(
      onHorizontalDragEnd: (details) {
        if ((details.primaryVelocity ?? 0) > 300) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── 頂部標題列 ──────────────────────────────────────────────
            Container(
              color: const Color(0xFF0D0D0D),
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 20),
              child: Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '伺服器連線設定',
                          style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: Colors.white),
                        ),
                        Text(
                          '由左往右滑動返回',
                          style: TextStyle(fontSize: 12, color: Colors.white38),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // ── 主要內容 ────────────────────────────────────────────────
            Expanded(
              child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [

            // ── 目前連線 ────────────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: app.connected
                    ? Colors.green.withAlpha(25)
                    : Colors.red.withAlpha(20),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    app.connected ? Icons.wifi : Icons.wifi_off,
                    size: 18,
                    color: app.connected ? Colors.green : Colors.red,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      app.connected ? '已連線：$currentUrl' : '未連線，上次設定：$currentUrl',
                      style: TextStyle(
                        fontSize: 13,
                        color: app.connected ? Colors.green : Colors.red.shade300,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 28),

            // ── URL 輸入（主要）──────────────────────────────────────────────
            const Text('AI 伺服器網址',
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white)),
            const SizedBox(height: 10),
            TextField(
              controller:   _urlCtrl,
              keyboardType: TextInputType.url,
              style: const TextStyle(fontSize: 16),
              enabled: !_showIpMode,
              onSubmitted: (_) => _connect(),
              decoration: InputDecoration(
                hintText:    '例如：https://xxxx.trycloudflare.com',
                prefixIcon:  const Icon(Icons.link),
                suffixIcon:  _urlCtrl.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 20),
                        onPressed: () => setState(() => _urlCtrl.clear()),
                      )
                    : null,
                filled:      _showIpMode,
                fillColor:   _showIpMode ? Colors.white10 : null,
              ),
              onChanged: (_) => setState(() {}),
            ),

            const SizedBox(height: 20),

            // ── 立即連接按鈕 ─────────────────────────────────────────────────
            SizedBox(
              height: 60,
              child: ElevatedButton.icon(
                onPressed: _connecting ? null : _connect,
                icon: _connecting
                    ? const SizedBox(
                        width: 22, height: 22,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2.5))
                    : const Icon(Icons.bolt, size: 26),
                label: Text(
                  _connecting ? '連線中…' : '立即連接',
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1565C0),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),

            const SizedBox(height: 28),
            const Divider(color: Colors.white12),
            const SizedBox(height: 8),

            // ── 進階：IP 模式（可展開）──────────────────────────────────────
            InkWell(
              onTap: () => setState(() => _showIpMode = !_showIpMode),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    const Icon(Icons.computer, size: 18, color: Colors.white38),
                    const SizedBox(width: 8),
                    const Text('區網 IP 模式（進階）',
                        style: TextStyle(fontSize: 14, color: Colors.white38)),
                    const Spacer(),
                    Icon(
                      _showIpMode
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      color: Colors.white38,
                    ),
                  ],
                ),
              ),
            ),

            if (_showIpMode) ...[
              const SizedBox(height: 12),
              TextField(
                controller:   _hostCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText:  'IP 位址',
                  hintText:   '例如：192.168.1.100',
                  prefixIcon: Icon(Icons.computer),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller:   _portCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText:  'Port',
                  hintText:   '預設 8081',
                  prefixIcon: Icon(Icons.settings_ethernet),
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => setState(() {
                  _hostCtrl.text = '10.0.2.2';
                  _portCtrl.text = '8081';
                  _secure        = false;
                }),
                icon:  const Icon(Icons.phone_android, size: 16),
                label: const Text('填入模擬器預設（10.0.2.2）'),
                style: TextButton.styleFrom(foregroundColor: Colors.white38),
              ),
              SwitchListTile(
                value:           _secure,
                activeThumbColor: Colors.blueAccent,
                contentPadding:  EdgeInsets.zero,
                title: const Text('啟用 HTTPS / WSS',
                    style: TextStyle(fontSize: 14, color: Colors.white70)),
                onChanged: (v) {
                  setState(() {
                    _secure = v;
                    if (v  && _portCtrl.text == '8081') _portCtrl.text = '443';
                    if (!v && _portCtrl.text == '443')  _portCtrl.text = '8081';
                  });
                },
              ),
            ],   // if (_showIpMode) 展開列表結束

          ],   // Column children 結束
        ),     // Column 結束
              ),    // SingleChildScrollView 結束
            ),      // Expanded 結束
          ],        // 外層 Column children 結束
        ),          // 外層 Column 結束
      ),            // SafeArea 結束
    ),              // Scaffold 結束
    );              // GestureDetector 結束
  }
}

