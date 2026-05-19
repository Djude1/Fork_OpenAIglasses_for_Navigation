# 紅綠燈時刻表臨時測試功能 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Android App 新增一個獨立測試分頁，GPS 靠近台北商大周邊路口時，依寫死的時段時制表＋系統時間推算並用 flutter_tts 播報「現在紅/綠燈，剩約 N 秒」。

**Architecture:** 方案 A（獨立分頁，完全隔離）。純邏輯集中在 `traffic_light_oracle.dart`（無 IO、可單元測試）；畫面 `traffic_light_test_screen.dart` 負責 GPS 訂閱、TTS、UI，離開頁即停。不碰 server、`navigation_master`、`LocalVoiceService`、全域摔倒偵測。拆除＝刪 2 新檔＋還原 app.dart 一行＋移除 home_screen 一個入口區塊。

**Tech Stack:** Flutter / Dart、geolocator ^13.0.2（已在 pubspec）、flutter_tts ^4.2.1（已在 pubspec）、flutter_test。

**參考文件：**
- 設計 spec：`docs/superpowers/specs/2026-05-20-traffic-light-schedule-test-design.md`
- 真實號誌資料：`docs/superpowers/specs/2026-05-20-traffic-light-data-台北商大.md`

**入口位置決策（與 spec 微調，理由）：** spec 原寫「settings 測試區」，但 `settings_screen.dart` 實為伺服器選擇介面，無測試區；既有測試畫面 `yoloe_ar_test` 的慣例入口是 `home_screen.dart` 的「開發者工具」`_NavBlock`。依「遵循既有模式」原則，本功能入口比照放在 home_screen 開發者工具區塊，視障使用者主流程不會誤入。

---

## File Structure

- **Create** `Android/lib/services/traffic_light_oracle.dart` — 純邏輯：型別定義、寫死資料表、時段選取、相位推算、最近路口、播報字串。零 IO、零 Flutter 相依（僅 dart core），可純單元測試。
- **Create** `Android/test/traffic_light_oracle_test.dart` — oracle 全部純函式的單元測試。
- **Create** `Android/lib/screens/traffic_light_test_screen.dart` — 測試畫面：定位權限、Geolocator 串流、觸發節流、flutter_tts、視障友善大字 UI、dispose 清理。
- **Modify** `Android/lib/app.dart` — 新增 import 與路由 `'/traffic_light_test'`。
- **Modify** `Android/lib/screens/home_screen.dart` — 在 yoloe_ar_test `_NavBlock` 之後新增一個入口 `_NavBlock`。

型別契約（跨任務一致，後續任務均沿用此命名）：

```dart
enum LightColor { green, red }
enum DayType { weekday, sat, sun }

class SignalPlan {
  final int startMinOfDay; // 生效起始（當日分鐘數）
  final int greenSec;
  final int redSec;
  final int anchorEpochSec; // 0 = 未現場校準
  const SignalPlan({
    required this.startMinOfDay,
    required this.greenSec,
    required this.redSec,
    required this.anchorEpochSec,
  });
  int get cycleSec => greenSec + redSec;
  bool get calibrated => anchorEpochSec != 0;
}

class TrafficLightSpot {
  final String deviceId;
  final String name;
  final double lat;
  final double lng;
  final int triggerRadiusM;
  final String note;
  final Map<DayType, List<SignalPlan>> schedule;
  const TrafficLightSpot({
    required this.deviceId,
    required this.name,
    required this.lat,
    required this.lng,
    required this.triggerRadiusM,
    required this.note,
    required this.schedule,
  });
}

class PhaseResult {
  final bool calibrated; // false → 不播報
  final LightColor color;
  final int remainSec;
  const PhaseResult(this.color, this.remainSec) : calibrated = true;
  const PhaseResult.uncalibrated()
      : calibrated = false,
        color = LightColor.red,
        remainSec = 0;
}
```

頂層函式（簽名固定）：
- `DayType dayTypeOf(DateTime dt)`
- `SignalPlan? selectPlan(TrafficLightSpot spot, DateTime now)`
- `PhaseResult computePhase(SignalPlan plan, int nowEpochSec)`
- `double distanceMeters(double lat1, double lng1, double lat2, double lng2)`
- `TrafficLightSpot? nearestSpot(double lat, double lng, {List<TrafficLightSpot> spots = trafficLightSpots})`
- `String announcement(PhaseResult r)`

---

## Task 1: Oracle 純邏輯（TDD）

**Files:**
- Create: `Android/lib/services/traffic_light_oracle.dart`
- Test: `Android/test/traffic_light_oracle_test.dart`

- [ ] **Step 1: 先寫骨架（型別 + 寫死資料 + 函式簽名拋未實作），讓測試可編譯**

建立 `Android/lib/services/traffic_light_oracle.dart`：

```dart
// lib/services/traffic_light_oracle.dart
// 紅綠燈時刻表測試功能 — 純推算邏輯（零 IO、零 Flutter 相依）
// 資料來源：data.taipei「臺北市路口號誌時制計畫」
// 詳見 docs/superpowers/specs/2026-05-20-traffic-light-data-台北商大.md
import 'dart:math' as math;

enum LightColor { green, red }
enum DayType { weekday, sat, sun }

class SignalPlan {
  final int startMinOfDay;
  final int greenSec;
  final int redSec;
  final int anchorEpochSec; // 0 = 未現場校準
  const SignalPlan({
    required this.startMinOfDay,
    required this.greenSec,
    required this.redSec,
    required this.anchorEpochSec,
  });
  int get cycleSec => greenSec + redSec;
  bool get calibrated => anchorEpochSec != 0;
}

class TrafficLightSpot {
  final String deviceId;
  final String name;
  final double lat;
  final double lng;
  final int triggerRadiusM;
  final String note;
  final Map<DayType, List<SignalPlan>> schedule;
  const TrafficLightSpot({
    required this.deviceId,
    required this.name,
    required this.lat,
    required this.lng,
    required this.triggerRadiusM,
    required this.note,
    required this.schedule,
  });
}

class PhaseResult {
  final bool calibrated;
  final LightColor color;
  final int remainSec;
  const PhaseResult(this.color, this.remainSec) : calibrated = true;
  const PhaseResult.uncalibrated()
      : calibrated = false,
        color = LightColor.red,
        remainSec = 0;
}

// 台北商大正門主路口（濟南路一段×杭州南一段 SJGIK10）平日時段時制。
// 時相一=綠（沿濟南路東西向行人）、時相二=紅；和＝週期。真實值。
// anchorEpochSec 全為 0 → 需現場實測填入後才會播報（見 spec 已知限制）。
const trafficLightSpots = <TrafficLightSpot>[
  TrafficLightSpot(
    deviceId: 'SJGIK10',
    name: '台北商業大學正門（濟南路一段與杭州南一段口）',
    lat: 25.041555,
    lng: 121.526155,
    triggerRadiusM: 30,
    note: '沿濟南路東西向行人穿越',
    schedule: {
      DayType.weekday: [
        SignalPlan(startMinOfDay: 0,    greenSec: 80, redSec: 40, anchorEpochSec: 0),
        SignalPlan(startMinOfDay: 60,   greenSec: 62, redSec: 28, anchorEpochSec: 0),
        SignalPlan(startMinOfDay: 300,  greenSec: 80, redSec: 40, anchorEpochSec: 0),
        SignalPlan(startMinOfDay: 420,  greenSec: 90, redSec: 60, anchorEpochSec: 0),
        SignalPlan(startMinOfDay: 540,  greenSec: 85, redSec: 65, anchorEpochSec: 0),
        SignalPlan(startMinOfDay: 840,  greenSec: 85, redSec: 65, anchorEpochSec: 0),
        SignalPlan(startMinOfDay: 990,  greenSec: 85, redSec: 65, anchorEpochSec: 0),
        SignalPlan(startMinOfDay: 1140, greenSec: 95, redSec: 55, anchorEpochSec: 0),
        SignalPlan(startMinOfDay: 1380, greenSec: 80, redSec: 40, anchorEpochSec: 0),
      ],
    },
  ),
];

DayType dayTypeOf(DateTime dt) => throw UnimplementedError();
SignalPlan? selectPlan(TrafficLightSpot spot, DateTime now) =>
    throw UnimplementedError();
PhaseResult computePhase(SignalPlan plan, int nowEpochSec) =>
    throw UnimplementedError();
double distanceMeters(double lat1, double lng1, double lat2, double lng2) =>
    throw UnimplementedError();
TrafficLightSpot? nearestSpot(double lat, double lng,
        {List<TrafficLightSpot> spots = trafficLightSpots}) =>
    throw UnimplementedError();
String announcement(PhaseResult r) => throw UnimplementedError();
```

- [ ] **Step 2: 寫失敗測試**

建立 `Android/test/traffic_light_oracle_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:android_ai_glasses/services/traffic_light_oracle.dart';

void main() {
  group('dayTypeOf', () {
    test('週一為 weekday', () {
      expect(dayTypeOf(DateTime(2026, 5, 18)), DayType.weekday); // Mon
    });
    test('週六為 sat', () {
      expect(dayTypeOf(DateTime(2026, 5, 23)), DayType.sat);
    });
    test('週日為 sun', () {
      expect(dayTypeOf(DateTime(2026, 5, 24)), DayType.sun);
    });
  });

  final spot = trafficLightSpots.first;

  group('selectPlan', () {
    test('14:30 取 startMin=840 那筆', () {
      final p = selectPlan(spot, DateTime(2026, 5, 18, 14, 30));
      expect(p?.startMinOfDay, 840);
    });
    test('00:30（早於第一筆之後仍命中 startMin=0）', () {
      final p = selectPlan(spot, DateTime(2026, 5, 18, 0, 30));
      expect(p?.startMinOfDay, 0);
    });
    test('剛好邊界 09:00 取 startMin=540', () {
      final p = selectPlan(spot, DateTime(2026, 5, 18, 9, 0));
      expect(p?.startMinOfDay, 540);
    });
    test('週六無排程回 null', () {
      final p = selectPlan(spot, DateTime(2026, 5, 23, 14, 30));
      expect(p, isNull);
    });
  });

  group('computePhase', () {
    test('未校準回 uncalibrated', () {
      const plan = SignalPlan(
          startMinOfDay: 0, greenSec: 80, redSec: 40, anchorEpochSec: 0);
      expect(computePhase(plan, 1000).calibrated, false);
    });
    test('剛好錨點 → 綠燈滿秒', () {
      const plan = SignalPlan(
          startMinOfDay: 0, greenSec: 80, redSec: 40, anchorEpochSec: 1000);
      final r = computePhase(plan, 1000);
      expect(r.color, LightColor.green);
      expect(r.remainSec, 80);
    });
    test('綠燈中段', () {
      const plan = SignalPlan(
          startMinOfDay: 0, greenSec: 80, redSec: 40, anchorEpochSec: 1000);
      final r = computePhase(plan, 1000 + 30);
      expect(r.color, LightColor.green);
      expect(r.remainSec, 50);
    });
    test('綠轉紅交界（第 80 秒進入紅）', () {
      const plan = SignalPlan(
          startMinOfDay: 0, greenSec: 80, redSec: 40, anchorEpochSec: 1000);
      final r = computePhase(plan, 1000 + 80);
      expect(r.color, LightColor.red);
      expect(r.remainSec, 40);
    });
    test('跨多個週期', () {
      const plan = SignalPlan(
          startMinOfDay: 0, greenSec: 80, redSec: 40, anchorEpochSec: 1000);
      // cycle=120，過 5 個週期再 +30 → 等同綠燈中段
      final r = computePhase(plan, 1000 + 120 * 5 + 30);
      expect(r.color, LightColor.green);
      expect(r.remainSec, 50);
    });
    test('now 早於錨點（負時間差）仍正確環繞', () {
      const plan = SignalPlan(
          startMinOfDay: 0, greenSec: 80, redSec: 40, anchorEpochSec: 1000);
      final r = computePhase(plan, 1000 - 90); // -90 mod 120 = 30
      expect(r.color, LightColor.green);
      expect(r.remainSec, 50);
    });
  });

  group('distanceMeters / nearestSpot', () {
    test('同點距離約 0', () {
      expect(distanceMeters(25.041555, 121.526155, 25.041555, 121.526155),
          lessThan(1));
    });
    test('半徑內回該路口', () {
      // 距正門約 10m 內的點
      final s = nearestSpot(25.041560, 121.526160);
      expect(s?.deviceId, 'SJGIK10');
    });
    test('遠離（>1km）回 null', () {
      expect(nearestSpot(25.05, 121.55), isNull);
    });
  });

  group('announcement', () {
    test('綠燈詞', () {
      expect(announcement(const PhaseResult(LightColor.green, 12)),
          '現在綠燈，剩約 12 秒');
    });
    test('紅燈詞', () {
      expect(announcement(const PhaseResult(LightColor.red, 18)),
          '現在紅燈，剩約 18 秒轉綠');
    });
    test('未校準回空字串（呼叫端據此不播）', () {
      expect(announcement(const PhaseResult.uncalibrated()), '');
    });
  });
}
```

- [ ] **Step 3: 執行測試確認失敗**

Run: `cd Android ; flutter test test/traffic_light_oracle_test.dart`
Expected: FAIL（`UnimplementedError`）

- [ ] **Step 4: 實作六個函式（取代 Step 1 的 throw）**

```dart
DayType dayTypeOf(DateTime dt) {
  switch (dt.weekday) {
    case DateTime.saturday:
      return DayType.sat;
    case DateTime.sunday:
      return DayType.sun;
    default:
      return DayType.weekday;
  }
}

// 取 startMinOfDay <= 現在分鐘數 的最後一筆；皆大於則用當日清單最後一筆
// （視為前一時段延續至跨日，臨時測試可接受的近似）。
SignalPlan? selectPlan(TrafficLightSpot spot, DateTime now) {
  final plans = spot.schedule[dayTypeOf(now)];
  if (plans == null || plans.isEmpty) return null;
  final nowMin = now.hour * 60 + now.minute;
  SignalPlan? picked;
  for (final p in plans) {
    if (p.startMinOfDay <= nowMin) {
      if (picked == null || p.startMinOfDay > picked.startMinOfDay) picked = p;
    }
  }
  return picked ?? plans.last;
}

PhaseResult computePhase(SignalPlan plan, int nowEpochSec) {
  if (!plan.calibrated) return const PhaseResult.uncalibrated();
  final cycle = plan.cycleSec;
  if (cycle <= 0) return const PhaseResult.uncalibrated();
  final raw = (nowEpochSec - plan.anchorEpochSec) % cycle;
  final elapsed = (raw + cycle) % cycle; // 處理負時間差
  if (elapsed < plan.greenSec) {
    return PhaseResult(LightColor.green, plan.greenSec - elapsed);
  }
  return PhaseResult(LightColor.red, cycle - elapsed);
}

double distanceMeters(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0; // 地球半徑（公尺）
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLng = (lng2 - lng1) * math.pi / 180;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

TrafficLightSpot? nearestSpot(double lat, double lng,
    {List<TrafficLightSpot> spots = trafficLightSpots}) {
  TrafficLightSpot? best;
  double bestD = double.infinity;
  for (final s in spots) {
    final d = distanceMeters(lat, lng, s.lat, s.lng);
    if (d < bestD) {
      bestD = d;
      best = s;
    }
  }
  if (best == null) return null;
  return bestD <= best.triggerRadiusM ? best : null;
}

String announcement(PhaseResult r) {
  if (!r.calibrated) return '';
  return r.color == LightColor.green
      ? '現在綠燈，剩約 ${r.remainSec} 秒'
      : '現在紅燈，剩約 ${r.remainSec} 秒轉綠';
}
```

- [ ] **Step 5: 執行測試確認通過**

Run: `cd Android ; flutter test test/traffic_light_oracle_test.dart`
Expected: PASS（全部 group 綠）

- [ ] **Step 6: 靜態檢查**

Run: `cd Android ; flutter analyze lib/services/traffic_light_oracle.dart test/traffic_light_oracle_test.dart`
Expected: No issues found

- [ ] **Step 7: Commit**

```bash
git add Android/lib/services/traffic_light_oracle.dart Android/test/traffic_light_oracle_test.dart
git commit -m "feat(android): 紅綠燈時刻表測試 — oracle 純推算邏輯 + 單元測試"
```

---

## Task 2: 測試畫面（GPS + TTS + UI）

**Files:**
- Create: `Android/lib/screens/traffic_light_test_screen.dart`

> 畫面含實機 IO（GPS/TTS），無法純單元測試；以 `flutter analyze` 把關，實機由使用者驗證（Task 4 清單）。

- [ ] **Step 1: 建立畫面檔**

建立 `Android/lib/screens/traffic_light_test_screen.dart`：

```dart
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
```

- [ ] **Step 2: 靜態檢查**

Run: `cd Android ; flutter analyze lib/screens/traffic_light_test_screen.dart`
Expected: No issues found（若報 permission_handler / flutter_tts 未解析，確認 pubspec 已有並 `flutter pub get`）

- [ ] **Step 3: Commit**

```bash
git add Android/lib/screens/traffic_light_test_screen.dart
git commit -m "feat(android): 紅綠燈時刻表測試畫面（GPS + flutter_tts + 隔離清理）"
```

---

## Task 3: 接線（路由 + 入口）

**Files:**
- Modify: `Android/lib/app.dart`（import 區、`routes:` map 內 ~第 46-47 行）
- Modify: `Android/lib/screens/home_screen.dart`（yoloe_ar_test `_NavBlock` 之後 ~第 372 行）

- [ ] **Step 1: app.dart 加 import**

在 `Android/lib/app.dart` 既有 `import 'screens/yoloe_ar_test_screen.dart';`（約第 16 行）之後新增一行：

```dart
import 'screens/traffic_light_test_screen.dart';
```

- [ ] **Step 2: app.dart 加路由**

在 `routes:` map 內 `'/yoloe_ar_test': (_) => const YoloeArTestScreen(),` 之後新增一行：

```dart
          '/traffic_light_test': (_) => const TrafficLightTestScreen(),
```

- [ ] **Step 3: home_screen.dart 加入口區塊**

在 `home_screen.dart` 的 yoloe_ar_test `_NavBlock` 對應的 `Expanded(...)` 區塊（結尾約第 372 行 `),`）之後，新增同款區塊：

```dart
        // ── 紅綠燈時刻表測試（開發者工具，臨時功能）──────────────────
        // 對應計畫：docs/superpowers/plans/2026-05-20-traffic-light-schedule-test.md
        Expanded(
          flex: 14,
          child: _NavBlock(
            label:    '紅綠燈時刻表測試',
            sublabel: '開發者工具 · 台北商大路口 GPS 推算',
            icon:     Icons.traffic_rounded,
            color:    const Color(0xFF263238),
            isActive: false,
            onTap:    () => Navigator.pushNamed(context, '/traffic_light_test'),
          ),
        ),
```

- [ ] **Step 4: 靜態檢查（全專案）**

Run: `cd Android ; flutter analyze`
Expected: No issues found（至少不得有新增錯誤）

- [ ] **Step 5: 全測試回歸**

Run: `cd Android ; flutter test`
Expected: 既有 `widget_test.dart` 與新 `traffic_light_oracle_test.dart` 全 PASS

- [ ] **Step 6: Commit**

```bash
git add Android/lib/app.dart Android/lib/screens/home_screen.dart
git commit -m "feat(android): 接線紅綠燈時刻表測試（路由 + home 開發者工具入口）"
```

---

## Task 4: 交接與實機驗證清單（無法自動化）

**Files:**
- Modify: `MD/現況快照.md`（「進行中：紅綠燈時刻表測試功能」段落）

- [ ] **Step 1: 更新現況快照狀態**

把 `MD/現況快照.md` 內「進行中：紅綠燈時刻表測試功能（2026-05-20…）」段的「狀態」由「尚未實作」改為「程式已實作，待現場校錨與實機驗證」，並補上下方待辦清單連結。

- [ ] **Step 2: Commit**

```bash
git add MD/現況快照.md
git commit -m "docs: 紅綠燈測試功能狀態更新 — 已實作待現場校錨"
```

- [ ] **Step 3: 明確告知使用者「需你手動驗證」清單**

向使用者輸出（不可宣稱已完成）：

1. **現場校錨（必做，否則不播報）**：到濟南路一段×杭州南一段（台北商大正門），對應目前時段，看到燈「剛轉綠」瞬間記下手機系統時間，轉成 Unix 秒，填入 `traffic_light_oracle.dart` 對應 `SignalPlan(... anchorEpochSec: <值>)`，重編 App。
2. **定位權限**：首次進頁的權限請求；拒絕後顯示提示而非崩潰。
3. **觸發**：實際走進正門路口 30m 內會自動播報；走出範圍播「已離開路口範圍」。
4. **TTS**：zh-TW 發音正確、句子自然；節流（每 10 秒或變色才播）不洗版。
5. **隔離**：離開分頁後 GPS 與 TTS 確實停止（不背景殘留耗電）；回到其他分頁功能正常、摔倒偵測未受影響。
6. **準確性**：校錨後播報的紅/綠與秒數與現場一致（同一時段內驗證）。

---

## Self-Review

**Spec coverage：**
- 模組切分（spec §3）→ Task 1（oracle）、Task 2（screen）、Task 3（app.dart/home_screen）✓
- 時段排程表資料結構（spec §4）→ Task 1 Step 1 型別與寫死資料，含真實 SJGIK10 值 ✓
- 相位推算純函式（spec §4）→ Task 1 `computePhase`，含負時間差/跨週期/未校準 ✓
- 觸發與播報節流（spec §5：進入播一次、變色或 ≥10s 更新、離開停、防抖）→ Task 2 `_onPosition` ✓
- TTS 地雷（spec §5：不走 LocalVoiceService、獨立 flutter_tts、離頁 stop）→ Task 2 `_tts`/`dispose` ✓
- 測試（spec §6 自動：時段選取、相位邊界、最近路口、anchor==0）→ Task 1 測試 group ✓
- 實機手動清單（spec §6）→ Task 4 Step 3 ✓
- YAGNI（spec §7：不做黃燈精算/多方向/即時 API）→ 計畫未含，符合 ✓
- 已知限制／交接（spec §8 + 交接提醒）→ Task 4 現況快照更新 + 校錨待辦 ✓

**Placeholder scan：** 無 TBD/TODO；每個 code step 均含完整程式碼；測試含實際斷言 ✓

**Type consistency：** `SignalPlan/TrafficLightSpot/PhaseResult/LightColor/DayType` 與 `dayTypeOf/selectPlan/computePhase/distanceMeters/nearestSpot/announcement` 在 Task 1 定義，Task 2 一致引用（`nearestSpot`/`selectPlan`/`computePhase`/`announcement`/`PhaseResult.uncalibrated`/`LightColor.green`）✓

無缺漏。
