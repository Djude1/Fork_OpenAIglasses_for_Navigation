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

## 4. 寫死資料結構

```dart
enum LightColor { green, red }

class TrafficLightSpot {
  final String name;        // 路口名稱（播報用）
  final double lat;
  final double lng;
  final int triggerRadiusM; // 觸發半徑（公尺），預設 30
  final int greenSec;       // 綠燈秒數（待實測）
  final int redSec;         // 紅燈秒數（待實測，黃燈併綠尾）
  final int anchorEpochSec; // 錨點 Unix 秒：該時刻為 anchorColor 的「起點」
  final LightColor anchorColor; // 錨點當下開始的顏色
  final String note;        // 此週期對應哪個方向行人穿越
  const TrafficLightSpot({...});
}

const trafficLightSpots = <TrafficLightSpot>[
  TrafficLightSpot(
    name: '台北商業大學正門（濟南路口）',
    lat: 25.0413, lng: 121.5365,   // 占位，待實測
    triggerRadiusM: 30,
    greenSec: 0, redSec: 0,        // 占位，待實測
    anchorEpochSec: 0,             // 占位：「實測時看到剛轉綠」的 Unix 秒
    anchorColor: LightColor.green,
    note: '沿濟南路東西向行人穿越',
  ),
  // 先放 1~3 個占位，做最常走的方向
];
```

### 相位推算（純函式）

```
cycle   = greenSec + redSec
elapsed = ((now - anchorEpochSec) % cycle + cycle) % cycle   // 處理跨週期與負時間差
若 anchorColor == green:
    elapsed < greenSec → color=green, remain = greenSec - elapsed
    否則               → color=red,   remain = cycle - elapsed
若 anchorColor == red：對稱推算
```

`cycle <= 0`（占位未填）時回傳特殊「資料未填」狀態，畫面顯示「此路口尚無實測資料」，不播誤導語音。

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
- 相位推算邊界：剛好等於錨點、跨多個週期、負時間差、綠/紅交界那一秒、`cycle<=0` 未填資料。
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
- 不做後端整合、不串接 data.taipei 開放號誌時制資料（格式過重；列為未來可選）。
- 不做全域背景自動觸發（方案 B）；待資料驗證可靠後，再評估把觸發點從畫面搬到全域。

## 8. 已知限制（臨時測試功能）

- 固定週期推算僅適用**定時號誌**；感應式/可變週期路口會不準。
- 長時間後系統時鐘與號誌實際相位可能漂移，需重新校錨點。
- 占位座標/週期未填前，功能僅顯示「尚無實測資料」，不播誤導語音。
