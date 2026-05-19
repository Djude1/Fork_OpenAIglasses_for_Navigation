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
