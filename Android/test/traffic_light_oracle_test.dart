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
