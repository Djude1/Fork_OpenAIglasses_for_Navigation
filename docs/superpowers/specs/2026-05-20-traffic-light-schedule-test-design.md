# 紅綠燈時刻表測試功能 設計文件

> 日期：2026-05-20
> 狀態：設計已通過，待寫實作計畫
> 性質：**臨時測試功能**，高度隔離、易拆除

---

## 1. 目的（Why）

驗證「不靠攝影機 YOLO 辨識，純靠寫死的號誌時刻表 + 系統時間推算」能否讓視障使用者一到台北商業大學附近路口，就立刻聽到目前是紅燈還綠燈、以及大約幾秒後轉換。概念與爭議中的高德地圖紅綠燈倒數相同。

這是臨時測試：實測週期資料尚未取得，本功能先建立「好填寫資料的結構」與完整推算/播報鏈，待實測後填入數值即可驗證。

## 2. 範圍與架構決策

| 決策 | 結論 | 理由 |
|------|------|------|
| 觸發方式 | GPS 定位自動觸發 | 最接近高德體驗，App 已有 `geolocator ^13.0.2` |
| 播報精度 | 目前顏色 + 倒數秒數 | 使用者指定 |
| 執行位置 | **Android 端全自包** | 隔離最徹底、最易拆除、不污染敏感 server 狀態機 |
| 架構 | **方案 A：獨立分頁** | 臨時/不確定功能應高度隔離；資料錯不污染正式導航 |

**完全不碰**：Python server、`navigation_master.py` 狀態機、`LocalVoiceService`（預錄語音）、全域摔倒偵測。

## 3. 模組切分

| 檔案 | 職責 | 依賴 |
|------|------|------|
| `Android/lib/services/traffic_light_oracle.dart` | **純邏輯**：寫死路口資料表 + 兩個純函式（依座標找最近路口、依時間算目前相位）。無 IO，可單元測試。 | 無 |
| `Android/lib/screens/traffic_light_test_screen.dart` | **畫面**：請求定位權限、訂閱 `Geolocator.getPositionStream`、進半徑播報、顯示視障友善大字狀態；離開頁即取消訂閱 + 停 TTS。 | oracle、geolocator、flutter_tts |
| `Android/lib/app.dart` | 註冊路由（改 1 行） | — |
| settings 測試區入口按鈕 | 進入測試分頁 | — |

拆除 = 刪 2 個新檔 + 還原 `app.dart` 路由那行 + 移除 settings 入口按鈕。

## 4. 寫死資料結構（時段排程表）

> 真實資料證實號誌為**多時段變週期**（一天約 12 段、週期 75~150 秒、平日／六／日不同），單一固定週期無法準確推算。資料結構改為「每路口一張時段時制排程表」。完整實測數據見 `2026-05-20-traffic-light-data-台北商大.md`。

```dart
enum LightColor { green, red }
enum DayType { weekday, sat, sun }   // 一~五 / 六 / 日

// 一個時段時制：自 startMinOfDay 起生效，直到下一筆
class SignalPlan {
  final int startMinOfDay;  // 生效起始（當日分鐘數，如 14:00 → 840）
  final int greenSec;       // 該時段沿播報方向的綠燈秒數（取自時相秒數）
  final int redSec;         // 該時段紅燈秒數（= 週期 − greenSec）
  final int anchorEpochSec; // 此時段現場實測錨點：看到剛轉綠的 Unix 秒（待現場填）
  const SignalPlan({...});
}

class TrafficLightSpot {
  final String deviceId;    // 官方設備編號（資料溯源用，如 'SJGIK10'）
  final String name;
  final double lat;
  final double lng;
  final int triggerRadiusM; // 觸發半徑（公尺），預設 30
  final String note;        // 播報對應哪個方向行人穿越
  final Map<DayType, List<SignalPlan>> schedule; // 依日型的時段排程
  const TrafficLightSpot({...});
}

// 已抓到真實週期值，anchorEpochSec 待現場實測
const trafficLightSpots = <TrafficLightSpot>[
  TrafficLightSpot(
    deviceId: 'SJGIK10',
    name: '台北商業大學正門（濟南路一段×杭州南一段）',
    lat: 25.041555, lng: 121.526155,
    triggerRadiusM: 30,
    note: '沿濟南路東西向行人穿越；時相一/時相二之和＝週期',
    schedule: {
      DayType.weekday: [
        // startMin, green(時相一), red(時相二)  — 真實值，anchor 待測
        SignalPlan(startMinOfDay: 0,    greenSec: 80, redSec: 40, anchorEpochSec: 0), // 00:00 週期120
        SignalPlan(startMinOfDay: 60,   greenSec: 62, redSec: 28, anchorEpochSec: 0), // 01:00 週期90
        SignalPlan(startMinOfDay: 300,  greenSec: 80, redSec: 40, anchorEpochSec: 0), // 05:00 週期120
        SignalPlan(startMinOfDay: 420,  greenSec: 90, redSec: 60, anchorEpochSec: 0), // 07:00 週期150
        SignalPlan(startMinOfDay: 540,  greenSec: 85, redSec: 65, anchorEpochSec: 0), // 09:00 週期150
        SignalPlan(startMinOfDay: 840,  greenSec: 85, redSec: 65, anchorEpochSec: 0), // 14:00 週期150
        SignalPlan(startMinOfDay: 990,  greenSec: 85, redSec: 65, anchorEpochSec: 0), // 16:30 週期150
        SignalPlan(startMinOfDay: 1140, greenSec: 95, redSec: 55, anchorEpochSec: 0), // 19:00 週期150
        SignalPlan(startMinOfDay: 1380, greenSec: 80, redSec: 40, anchorEpochSec: 0), // 23:00 週期120
      ],
      // sat/sun 待補；先做平日驗證
    },
  ),
  // 其餘 SJJIA10/SJPIM10/SJSIC10 座標與數據已備齊，視驗證結果再加
];
```

### 相位推算（純函式）

```
1. 依現在日型(weekday/sat/sun)取 schedule，找出 startMinOfDay <= 現在時刻 的最後一筆 plan
2. cycle = plan.greenSec + plan.redSec
3. plan.anchorEpochSec == 0 → 回傳「此時段尚未現場校準」狀態，不播誤導語音
4. elapsed = ((now - anchorEpochSec) % cycle + cycle) % cycle
   elapsed < greenSec → color=green, remain = greenSec - elapsed
   否則              → color=red,   remain = cycle - elapsed
```

任何 plan 的 `anchorEpochSec` 未填（=0）時畫面顯示「此路口此時段尚無實測校準」，**僅在已校準時段才播報**。

## 5. 觸發與播報邏輯

- 每次定位更新 → 用 `Geolocator.distanceBetween` 算到各 spot 距離，取「最近且 < `triggerRadiusM`」為目前路口。
- **進入**路口：播一次完整播報。
- **持續在路口內**：僅在「顏色變化」或「距上次播報 ≥ 10 秒」時更新播報，避免每秒洗版。
- **離開**半徑：播「已離開路口範圍」，停止後續播報。
- 防抖：持續在同一路口半徑內不重複「進入」播報；換到另一路口視為新進入。
- 播報詞：
  - `現在綠燈，剩約 {N} 秒`
  - `現在紅燈，剩約 {N} 秒轉綠`
- TTS：`flutter_tts ^4.2.1`，語言設 `zh-TW`，**獨立實例**，不走 `LocalVoiceService` 預錄通道。離開畫面 `stop()` + `dispose()`。

## 6. 測試

### 自動（Flutter 單元測試）
- 時段選取：依日型（平日/六/日）與當下時刻，取 `startMinOfDay <= now` 的最後一筆 plan；跨午夜回繞到前一日最後時段。
- 相位推算邊界：剛好等於錨點、跨多個週期、負時間差、綠/紅交界那一秒、`anchorEpochSec==0` 回「未校準」狀態（不播報）。
- 最近路口選擇：多 spot 假座標下取最近且在半徑內；皆超出半徑時回傳 null。

### 需使用者實機手動驗證（明確清單）
- [ ] 定位權限請求流程正常（含拒絕後行為）
- [ ] 實際走到路口半徑內會自動觸發播報
- [ ] `zh-TW` 發音正確、句子自然
- [ ] 離開分頁後 GPS 監聽與 TTS 確實停止（不背景殘留耗電）
- [ ] 填入實測資料後，播報的顏色/秒數與現場一致

## 7. 刻意排除（YAGNI）

- 不做黃燈精算：綠/紅兩相，黃燈併入綠燈尾段。
- 不做多方向相位：每個 spot 先針對使用者最常走的單一方向。
- 週期/時相秒數**離線取自 data.taipei**「臺北市路口號誌時制計畫」，蒸餾成寫死表（見 `2026-05-20-traffic-light-data-台北商大.md`）；**不做即時 API 串接**（格式過重、且無即時相位，列為未來可選）。
- 不做全域背景自動觸發（方案 B）；待資料驗證可靠後，再評估把觸發點從畫面搬到全域。

## 8. 已知限制（臨時測試功能）

- **公開資料只給週期與時相秒數，不給即時相位**：data.taipei 官方資料無「此刻燈走到第幾秒」的基準，且多數路口有連鎖時差（offset）、尖峰時段甚至為感應式（如 SJSIC10）。純靠系統時間＋公開資料**本質上無法精準推回目前紅綠**——這正是高德地圖紅綠燈倒數備受爭議的根因。
- 因此每個路口、每個時段時制，仍須**現場實測一次錨點**（填入 `anchorEpochSec`）才會播報；未校準時段只顯示不播報。
- 號誌時制會被交通局調整：本資料為 2024-03-01 版（取得時已逾一年），需定期重新核對與重測錨點。
- 長時間後系統時鐘與號誌實際相位仍可能漂移。
- 結論：本功能定位為**可行性測試**，準確性以「已現場校準的單一路口單一時段」為限，不宜對視障使用者宣稱可全天候信賴。
