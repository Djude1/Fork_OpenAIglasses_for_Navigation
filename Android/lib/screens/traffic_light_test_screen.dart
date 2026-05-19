// lib/screens/traffic_light_test_screen.dart
// 紅綠燈時刻表「臨時測試」分頁（方案 A，完全隔離）。
// 進頁才啟動 GPS 與 TTS，離頁立即全停。不碰 server / navigation_master。
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/traffic_light_oracle.dart';

class TrafficLightTestScreen extends StatefulWidget {
  const TrafficLightTestScreen({super.key});
  @override
  State<TrafficLightTestScreen> createState() => _TrafficLightTestScreenState();
}

class _TrafficLightTestScreenState extends State<TrafficLightTestScreen> {
  final FlutterTts _tts = FlutterTts();
  StreamSubscription<Position>? _posSub;

  String _statusLine = '正在取得定位權限…';
  String _spotName = '—';
  Color _bg = Colors.black;

  String? _currentDeviceId;       // 目前所在路口（防重複進入播報）
  int _lastSpokenEpoch = 0;       // 上次播報時間（秒）
  LightColor? _lastColor;         // 上次播報顏色

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _tts.setLanguage('zh-TW');
    await _tts.setSpeechRate(0.5);
    final status = await Permission.locationWhenInUse.request();
    if (!status.isGranted) {
      setState(() => _statusLine = '未授權定位，無法測試。請至系統設定開啟定位權限。');
      return;
    }
    if (!mounted) return;
    setState(() => _statusLine = '定位中，請走到台北商大正門路口…');
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 3,
      ),
    ).listen(_onPosition, onError: (e) {
      if (mounted) setState(() => _statusLine = '定位錯誤：$e');
    });
  }

  void _onPosition(Position pos) {
    final spot = nearestSpot(pos.latitude, pos.longitude);
    if (spot == null) {
      if (_currentDeviceId != null) {
        _currentDeviceId = null;
        _lastColor = null;
        _speak('已離開路口範圍');
        setState(() {
          _spotName = '—';
          _statusLine = '已離開路口範圍';
          _bg = Colors.black;
        });
      }
      return;
    }

    final now = DateTime.now();
    final plan = selectPlan(spot, now);
    final nowEpoch = now.millisecondsSinceEpoch ~/ 1000;
    final result = plan == null
        ? const PhaseResult.uncalibrated()
        : computePhase(plan, nowEpoch);

    final entered = _currentDeviceId != spot.deviceId;
    _currentDeviceId = spot.deviceId;

    if (!result.calibrated) {
      setState(() {
        _spotName = spot.name;
        _statusLine = '此路口此時段尚無實測校準，不播報';
        _bg = Colors.black;
      });
      return;
    }

    final colorChanged = _lastColor != result.color;
    final throttled = (nowEpoch - _lastSpokenEpoch) < 10;
    if (entered || colorChanged || !throttled) {
      _lastSpokenEpoch = nowEpoch;
      _lastColor = result.color;
      _speak(announcement(result));
    }

    setState(() {
      _spotName = spot.name;
      _statusLine = result.color == LightColor.green
          ? '綠燈　剩約 ${result.remainSec} 秒'
          : '紅燈　剩約 ${result.remainSec} 秒轉綠';
      _bg = result.color == LightColor.green
          ? const Color(0xFF1B5E20)
          : const Color(0xFFB71C1C);
    });
  }

  Future<void> _speak(String text) async {
    if (text.isEmpty) return;
    await _tts.stop();
    await _tts.speak(text);
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        title: const Text('紅綠燈時刻表測試（開發者工具）'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(_spotName,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 22)),
              const SizedBox(height: 32),
              Text(_statusLine,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 40,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 40),
              const Text('臨時測試功能 · 僅供可行性驗證',
                  style: TextStyle(color: Colors.white38, fontSize: 14)),
            ],
          ),
        ),
      ),
    );
  }
}
