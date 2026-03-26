// lib/screens/home_screen.dart
// 開發者主畫面：雙頁 PageView（與視障者介面相同結構）
//
// 頁面 0：主功能
//   • 全寬色塊按鈕：盲道導航 / 過馬路 / 紅綠燈 / 找物品 / 停止
//   • 底部訊息記錄
//
// 頁面 1：設定
//   • 文件閱讀 / 伺服器設定 / 緊急連絡人 / 切換視障者模式

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../widgets/debug_panel.dart';
import 'ar_screen.dart';
import 'settings_screen.dart';
import 'contacts_screen.dart';
import 'read_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _pageController = PageController(initialPage: 0);
  final _scrollCtrl     = ScrollController();
  int   _currentPage    = 0;
  bool? _prevConnected;

  OverlayEntry? _debugEntry;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppProvider>();
    _prevConnected = app.connected;
    app.addListener(_onAppChanged);
    // DEBUG 浮動面板：插入至 Overlay，跨所有子頁面持續顯示
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _debugEntry = OverlayEntry(
        builder: (_) => const DebugFloatingPanel(),
      );
      Overlay.of(context).insert(_debugEntry!);
    });
  }

  @override
  void dispose() {
    _debugEntry?.remove();
    _debugEntry = null;
    context.read<AppProvider>().removeListener(_onAppChanged);
    _pageController.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onAppChanged() {
    if (!mounted) return;
    // 訊息自動捲到底
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
    // 連線狀態變化提示
    final nowConnected = context.read<AppProvider>().connected;
    if (_prevConnected != nowConnected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(
            content: Row(children: [
              Icon(nowConnected ? Icons.wifi : Icons.wifi_off,
                  color: Colors.white, size: 18),
              const SizedBox(width: 10),
              Text(nowConnected ? '✓ 已重新連線' : '⚠ 伺服器連線中斷，正在重連…',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
            ]),
            backgroundColor:
                nowConnected ? const Color(0xFF2E7D32) : const Color(0xFFC62828),
            behavior:  SnackBarBehavior.floating,
            margin:    const EdgeInsets.fromLTRB(12, 0, 12, 16),
            shape:     RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            duration:  Duration(seconds: nowConnected ? 2 : 4),
          ));
      });
      _prevConnected = nowConnected;
    }
  }

  // ── 導航動作 ────────────────────────────────────────────────────────────
  Future<void> _startAndShowAr(
      Future<void> Function() startFn, String title) async {
    HapticFeedback.heavyImpact();
    await startFn();
    if (!mounted) return;
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => ArScreen(title: title)));
  }

  Future<void> _showItemSearchDialog() async {
    HapticFeedback.selectionClick();
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('找什麼物品？',
            style: TextStyle(fontSize: 20, color: Colors.white)),
        content: TextField(
          controller:      ctrl,
          autofocus:       true,
          textInputAction: TextInputAction.done,
          onSubmitted:     (v) => Navigator.pop(ctx, v),
          style:           const TextStyle(color: Colors.white, fontSize: 18),
          decoration:      const InputDecoration(
              hintText:    '例如：手機、眼鏡、鑰匙',
              hintStyle:   TextStyle(color: Colors.white38)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('開始尋找')),
        ],
      ),
    );
    if (result != null && result.isNotEmpty && mounted) {
      final app = context.read<AppProvider>();
      await app.startItemSearch(result);
      if (mounted) {
        Navigator.push(context,
            MaterialPageRoute(
                builder: (_) => ArScreen(title: '找物品：$result')));
      }
    }
  }

  // ── 頁面切換 ────────────────────────────────────────────────────────────
  void _goToSettings() {
    _pageController.animateToPage(1,
        duration: const Duration(milliseconds: 350), curve: Curves.easeInOut);
  }

  // ── Build ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppProvider>();
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            PageView(
              controller:    _pageController,
              onPageChanged: (i) {
                HapticFeedback.selectionClick();
                setState(() => _currentPage = i);
              },
              children: [
                // ── 頁面 0：主功能 ─────────────────────────────────────
                _MainPage(
                  app:         app,
                  scrollCtrl:  _scrollCtrl,
                  onStartAr:   _startAndShowAr,
                  onItemSearch: _showItemSearchDialog,
                  onGoSettings: _goToSettings,
                ),
                // ── 頁面 1：設定 ───────────────────────────────────────
                _SettingsPage(app: app),
              ],
            ),

            // ── 頁面指示點 ─────────────────────────────────────────────
            Positioned(
              bottom: 10, left: 0, right: 0,
              child: _PageDots(current: _currentPage, total: 2),
            ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// 頁面 0：主功能
// ════════════════════════════════════════════════════════════════════════════
class _MainPage extends StatelessWidget {
  final AppProvider app;
  final ScrollController scrollCtrl;
  final Future<void> Function(Future<void> Function(), String) onStartAr;
  final VoidCallback onItemSearch;
  final VoidCallback onGoSettings;

  const _MainPage({
    required this.app,
    required this.scrollCtrl,
    required this.onStartAr,
    required this.onItemSearch,
    required this.onGoSettings,
  });

  bool get _navigating => !['IDLE', 'CHAT', ''].contains(app.navState);

  @override
  Widget build(BuildContext context) {
    final nav = app.navState;
    final ok  = app.connected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 頂部狀態色條
        _StatusBar(connected: ok, navState: nav),

        // 標題列
        Container(
          color: const Color(0xFF0D0D0D),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 20),
          child: Row(
            children: [
              const Text('首頁',
                  style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
              const Spacer(),
              // 連線狀態徽章
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: ok
                      ? Colors.green.withAlpha(30)
                      : Colors.red.withAlpha(30),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      ok ? Icons.wifi : Icons.wifi_off,
                      size: 14,
                      color: ok ? Colors.greenAccent : Colors.redAccent,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      ok ? '已連線' : '未連線',
                      style: TextStyle(
                          fontSize: 12,
                          color: ok ? Colors.greenAccent : Colors.redAccent),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text('向左滑動進入設定',
                  style: const TextStyle(
                      fontSize: 12, color: Colors.white38)),
            ],
          ),
        ),

        // ── 盲道導航（最大色塊）───────────────────────────────────────
        Expanded(
          flex: 38,
          child: _NavBlock(
            label:    '盲道導航',
            sublabel: _navigating && nav == 'BLINDPATH_NAV'
                ? '導航中 — 點擊停止'
                : ok ? '點擊啟動' : '未連線',
            icon:     _navigating && nav == 'BLINDPATH_NAV'
                ? Icons.stop_circle_outlined
                : Icons.navigation,
            color: !ok
                ? const Color(0xFF212121)
                : nav == 'BLINDPATH_NAV'
                    ? const Color(0xFFB71C1C)
                    : const Color(0xFF0D47A1),
            isActive: nav == 'BLINDPATH_NAV',
            onTap: ok
                ? () => nav == 'BLINDPATH_NAV'
                    ? app.stopNavigation()
                    : onStartAr(app.startBlindpath, '盲道導航')
                : null,
          ),
        ),

        // ── 過馬路 ───────────────────────────────────────────────────
        Expanded(
          flex: 18,
          child: _NavBlock(
            label:    '過馬路',
            sublabel: ['CROSSING', 'SEEKING_CROSSWALK',
                'WAIT_TRAFFIC_LIGHT', 'SEEKING_NEXT_BLINDPATH']
                .contains(nav)
                ? '執行中'
                : ok ? '偵測斑馬線與紅綠燈' : '未連線',
            icon:     Icons.directions_walk,
            color: !ok
                ? const Color(0xFF1B1B1B)
                : ['CROSSING', 'SEEKING_CROSSWALK',
                    'WAIT_TRAFFIC_LIGHT', 'SEEKING_NEXT_BLINDPATH']
                    .contains(nav)
                    ? const Color(0xFFB71C1C)
                    : const Color(0xFF1B5E20),
            isActive: ['CROSSING', 'SEEKING_CROSSWALK',
                'WAIT_TRAFFIC_LIGHT', 'SEEKING_NEXT_BLINDPATH']
                .contains(nav),
            onTap: ok
                ? () => onStartAr(app.startCrossing, '過馬路')
                : null,
          ),
        ),

        // ── 紅綠燈偵測 ──────────────────────────────────────────────
        Expanded(
          flex: 15,
          child: _NavBlock(
            label:    '紅綠燈偵測',
            sublabel: nav == 'TRAFFIC_LIGHT_DETECTION'
                ? '偵測中'
                : ok ? '語音告知燈號' : '未連線',
            icon:     Icons.traffic,
            color: !ok
                ? const Color(0xFF1B1B1B)
                : nav == 'TRAFFIC_LIGHT_DETECTION'
                    ? const Color(0xFFB71C1C)
                    : const Color(0xFFE65100),
            isActive: nav == 'TRAFFIC_LIGHT_DETECTION',
            onTap: ok
                ? () => onStartAr(app.startTrafficLight, '紅綠燈偵測')
                : null,
          ),
        ),

        // ── 找物品 / 停止（橫排各佔一半）──────────────────────────
        Expanded(
          flex: 14,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 找物品
              Expanded(
                child: _NavBlock(
                  label:    '找物品',
                  sublabel: nav == 'ITEM_SEARCH' ? '搜尋中' : ok ? '語音指定物品' : '未連線',
                  icon:     Icons.search,
                  color: !ok
                      ? const Color(0xFF1B1B1B)
                      : nav == 'ITEM_SEARCH'
                          ? const Color(0xFFB71C1C)
                          : const Color(0xFF4A148C),
                  isActive: nav == 'ITEM_SEARCH',
                  onTap:    ok ? onItemSearch : null,
                ),
              ),
              const SizedBox(width: 2),
              // 停止
              Expanded(
                child: _NavBlock(
                  label:    '停止',
                  sublabel: ok ? '停止所有功能' : '未連線',
                  icon:     Icons.stop_circle,
                  color:    ok
                      ? const Color(0xFF37474F)
                      : const Color(0xFF1B1B1B),
                  isActive: false,
                  onTap:    ok ? () => app.stopNavigation() : null,
                ),
              ),
            ],
          ),
        ),

        // ── 訊息記錄 ─────────────────────────────────────────────────
        Expanded(
          flex: 18,
          child: Container(
            color: const Color(0xFF0A0A0A),
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('訊息記錄',
                    style: TextStyle(
                        fontSize: 11,
                        color: Colors.white24,
                        letterSpacing: 1)),
                const SizedBox(height: 4),
                Expanded(
                  child: app.messages.isEmpty
                      ? const Center(
                          child: Text('等待伺服器訊息…',
                              style: TextStyle(
                                  color: Colors.white12, fontSize: 13)),
                        )
                      : ListView.builder(
                          controller:  scrollCtrl,
                          itemCount:   app.messages.length,
                          itemBuilder: (_, i) => Text(
                            app.messages[i],
                            style: TextStyle(
                              fontSize: 12,
                              color: _msgColor(app.messages[i]),
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 30), // 頁碼點空間
      ],
    );
  }

  Color _msgColor(String msg) {
    if (msg.contains('[錯誤]')) return Colors.redAccent.withAlpha(200);
    if (msg.contains('[ASR]') || msg.contains('[USER]')) return Colors.cyanAccent.withAlpha(180);
    if (msg.contains('[狀態]')) return Colors.greenAccent.withAlpha(160);
    return Colors.white30;
  }
}

// ════════════════════════════════════════════════════════════════════════════
// 頁面 1：設定
// ════════════════════════════════════════════════════════════════════════════
class _SettingsPage extends StatelessWidget {
  final AppProvider app;
  const _SettingsPage({required this.app});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 標題
          Container(
            color: const Color(0xFF0D0D0D),
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 20),
            child: const Row(
              children: [
                Text('設定',
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Colors.white)),
                Spacer(),
                Text('向右滑動返回首頁',
                    style: TextStyle(fontSize: 12, color: Colors.white38)),
              ],
            ),
          ),

          // 色塊清單
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [

                // ── 文件閱讀 ─────────────────────────────────────────
                _SettingBlock(
                  icon:     Icons.document_scanner,
                  label:    '文件閱讀',
                  sublabel: '拍照辨識文件，語音朗讀',
                  color:    const Color(0xFF004D40),
                  onTap:    () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const ReadScreen())),
                ),

                const SizedBox(height: 3),

                // ── 伺服器設定 ────────────────────────────────────────
                _SettingBlock(
                  icon:     Icons.settings_ethernet,
                  label:    '伺服器設定',
                  sublabel: app.baseUrl.isNotEmpty
                      ? app.baseUrl
                      : '${app.host}:${app.port}',
                  color:    const Color(0xFF0D2A4A),
                  onTap:    () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const SettingsScreen())),
                ),

                const SizedBox(height: 3),

                // ── 緊急連絡人 ────────────────────────────────────────
                _SettingBlock(
                  icon:     Icons.contacts,
                  label:    '緊急連絡人',
                  sublabel: '管理緊急求救聯絡清單',
                  color:    const Color(0xFF1A237E),
                  onTap:    () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const ContactsScreen())),
                ),

                const SizedBox(height: 3),

                // ── AR 畫面（目前導航模式）────────────────────────────
                _SettingBlock(
                  icon:     Icons.visibility,
                  label:    'AR 偵測畫面',
                  sublabel: app.connected
                      ? '查看 YOLO 即時影像串流'
                      : '需要先連線伺服器',
                  color:    app.connected
                      ? const Color(0xFF1B3A1B)
                      : const Color(0xFF1B1B1B),
                  onTap:    app.connected
                      ? () => Navigator.push(context,
                          MaterialPageRoute(
                              builder: (_) => const ArScreen(title: 'AR 畫面')))
                      : null,
                ),

                const SizedBox(height: 3),

                // ── 音訊測試 ──────────────────────────────────────────
                _SettingBlock(
                  icon:     Icons.headphones,
                  label:    '音訊測試',
                  sublabel: app.isRecordingMic
                      ? 'TTS 語音 / 串流播放 / 麥克風錄音中'
                      : 'TTS 語音 / 串流播放 / 麥克風未啟動',
                  color:    const Color(0xFF1A2744),
                  onTap:    () => showAudioTestSheet(context, app),
                ),

                const SizedBox(height: 3),

                // ── 切換視障者模式 ────────────────────────────────────
                _SettingBlock(
                  icon:     Icons.accessibility_new,
                  label:    '切換視障者模式',
                  sublabel: '進入全語音導引介面',
                  color:    const Color(0xFF311B92),
                  onTap:    () async {
                    HapticFeedback.heavyImpact();
                    await app.stopNavigation();
                    if (context.mounted) {
                      Navigator.pushReplacementNamed(context, '/blind');
                    }
                  },
                ),

              ],
            ),
          ),

          const SizedBox(height: 30), // 頁碼點空間
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// 共用 UI 元件
// ════════════════════════════════════════════════════════════════════════════

// 頂部狀態色條（與 blind_screen 相同）
class _StatusBar extends StatelessWidget {
  final bool connected;
  final String navState;
  const _StatusBar({required this.connected, required this.navState});

  @override
  Widget build(BuildContext context) {
    final navigating = !['IDLE', 'CHAT', ''].contains(navState);
    final c = !connected
        ? Colors.grey.shade800
        : navigating
            ? Colors.green.shade700
            : Colors.blue.shade900;
    return AnimatedContainer(
        duration: const Duration(milliseconds: 400), height: 6, color: c);
  }
}

// 頁面指示點（與 blind_screen 相同）
class _PageDots extends StatelessWidget {
  final int current;
  final int total;
  const _PageDots({required this.current, required this.total});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(total, (i) {
        final active = i == current;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          margin: const EdgeInsets.symmetric(horizontal: 5),
          width:  active ? 18 : 8,
          height: 8,
          decoration: BoxDecoration(
            color: active ? Colors.white70 : Colors.white24,
            borderRadius: BorderRadius.circular(4),
          ),
        );
      }),
    );
  }
}

// 主功能色塊按鈕
class _NavBlock extends StatelessWidget {
  final String    label;
  final String    sublabel;
  final IconData  icon;
  final Color     color;
  final bool      isActive;
  final VoidCallback? onTap;

  const _NavBlock({
    required this.label,
    required this.sublabel,
    required this.icon,
    required this.color,
    required this.isActive,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap != null
          ? () {
              HapticFeedback.heavyImpact();
              onTap!();
            }
          : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        color: color,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(
          children: [
            Icon(icon,
                size:  38,
                color: onTap != null ? Colors.white : Colors.white24),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize:   24,
                      fontWeight: FontWeight.bold,
                      color:      onTap != null ? Colors.white : Colors.white24,
                    ),
                  ),
                  Text(
                    sublabel,
                    style: TextStyle(
                      fontSize: 13,
                      color:    onTap != null
                          ? (isActive ? Colors.white : Colors.white60)
                          : Colors.white24,
                    ),
                  ),
                ],
              ),
            ),
            if (isActive)
              Container(
                width: 10, height: 10,
                decoration: const BoxDecoration(
                  color:  Colors.white,
                  shape:  BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ── 音訊測試底部彈出面板 ─────────────────────────────────────────────────────
Future<void> showAudioTestSheet(BuildContext context, AppProvider app) async {
  final ctrl = TextEditingController(text: '測試語音播報');

  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF1A1A1A),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => _AudioTestSheet(app: app, ctrl: ctrl),
  );

  ctrl.dispose();
}

class _AudioTestSheet extends StatefulWidget {
  final AppProvider app;
  final TextEditingController ctrl;
  const _AudioTestSheet({required this.app, required this.ctrl});

  @override
  State<_AudioTestSheet> createState() => _AudioTestSheetState();
}

class _AudioTestSheetState extends State<_AudioTestSheet> {
  static const _rates = [0.35, 0.5, 0.7, 1.0];

  String _rateLabel(double r) {
    if (r <= 0.35) return '慢速';
    if (r <= 0.5)  return '正常';
    if (r <= 0.7)  return '快速';
    return '超快速';
  }

  double _nextRate(double r) {
    final idx = _rates.indexWhere((v) => (v - r).abs() < 0.01);
    return _rates[(idx + 1) % _rates.length];
  }

  bool _playingServer = false;

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [

              // 拖曳把手
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // 標題 + 麥克風狀態
              Row(
                children: [
                  const Text('音訊測試',
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.white)),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: app.isRecordingMic
                          ? Colors.green.withAlpha(40)
                          : Colors.grey.withAlpha(30),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.mic,
                            size: 14,
                            color: app.isRecordingMic
                                ? Colors.greenAccent
                                : Colors.white38),
                        const SizedBox(width: 5),
                        Text(
                          app.isRecordingMic ? '麥克風錄音中' : '麥克風未啟動',
                          style: TextStyle(
                            fontSize: 12,
                            color: app.isRecordingMic
                                ? Colors.greenAccent
                                : Colors.white38,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // ── APP 語音開關 ───────────────────────────────────────────
              _AudioRow(
                label: 'APP 語音播報',
                sublabel: app.ttsEnabled ? '已開啟' : '已關閉',
                trailing: Switch(
                  value:            app.ttsEnabled,
                  activeThumbColor: Colors.blueAccent,
                  onChanged: (v) {
                    app.setTtsEnabled(v);
                    setState(() {});
                  },
                ),
              ),
              const Divider(color: Colors.white12, height: 1),

              // ── 語音速度 ───────────────────────────────────────────────
              _AudioRow(
                label:    '語音速度',
                sublabel: _rateLabel(app.ttsSpeechRate),
                trailing: TextButton(
                  onPressed: () {
                    app.setTtsSpeechRate(_nextRate(app.ttsSpeechRate));
                    setState(() {});
                  },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_rateLabel(app.ttsSpeechRate),
                          style: const TextStyle(
                              fontSize: 15, color: Colors.blueAccent)),
                      const Icon(Icons.swap_horiz,
                          color: Colors.blueAccent, size: 18),
                    ],
                  ),
                ),
              ),
              const Divider(color: Colors.white12, height: 1),
              const SizedBox(height: 16),

              // ── TTS 語音測試輸入 ───────────────────────────────────────
              const Text('TTS 語音測試',
                  style: TextStyle(fontSize: 13, color: Colors.white54)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: widget.ctrl,
                      style:      const TextStyle(
                          color: Colors.white, fontSize: 16),
                      decoration: InputDecoration(
                        hintText:  '輸入要朗讀的文字…',
                        hintStyle: const TextStyle(color: Colors.white24),
                        filled:    true,
                        fillColor: const Color(0xFF2A2A2A),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton(
                    onPressed: () {
                      final text = widget.ctrl.text.trim();
                      if (text.isNotEmpty) app.speak(text);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1565C0),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: const Icon(Icons.play_arrow, color: Colors.white),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // ── 伺服器音訊串流測試 ─────────────────────────────────────
              GestureDetector(
                onTap: !_playingServer
                    ? () async {
                        setState(() => _playingServer = true);
                        await app.playServerAudioTest();
                        if (mounted) setState(() => _playingServer = false);
                      }
                    : null,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      vertical: 16, horizontal: 20),
                  decoration: BoxDecoration(
                    color: _playingServer
                        ? const Color(0xFF004D40)
                        : const Color(0xFF1B3A2A),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _playingServer
                            ? Icons.volume_up
                            : Icons.play_circle_outline,
                        color: Colors.greenAccent,
                        size: 28,
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('播放伺服器音訊串流',
                              style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white)),
                          Text(
                            _playingServer
                                ? '正在播放 /stream.wav…'
                                : '測試 /stream.wav 下行串流',
                            style: const TextStyle(
                                fontSize: 12, color: Colors.white54),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// 音訊測試列項目
class _AudioRow extends StatelessWidget {
  final String label;
  final String sublabel;
  final Widget trailing;

  const _AudioRow({
    required this.label,
    required this.sublabel,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        fontSize: 16, color: Colors.white)),
                Text(sublabel,
                    style: const TextStyle(
                        fontSize: 13, color: Colors.white38)),
              ],
            ),
          ),
          trailing,
        ],
      ),
    );
  }
}

// 設定頁色塊按鈕
class _SettingBlock extends StatelessWidget {
  final IconData  icon;
  final String    label;
  final String    sublabel;
  final Color     color;
  final VoidCallback? onTap;

  const _SettingBlock({
    required this.icon,
    required this.label,
    required this.sublabel,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap != null
          ? () {
              HapticFeedback.selectionClick();
              onTap!();
            }
          : null,
      child: Container(
        color:       color,
        constraints: const BoxConstraints(minHeight: 90),
        padding:     const EdgeInsets.symmetric(vertical: 22, horizontal: 24),
        child: Row(
          children: [
            Icon(icon,
                size: 36,
                color: onTap != null ? Colors.white70 : Colors.white24),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize:   26,
                      fontWeight: FontWeight.bold,
                      color:      onTap != null ? Colors.white : Colors.white38,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    sublabel,
                    style: const TextStyle(
                        fontSize: 14, color: Colors.white54),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                color: onTap != null ? Colors.white38 : Colors.white12,
                size: 24),
          ],
        ),
      ),
    );
  }
}
