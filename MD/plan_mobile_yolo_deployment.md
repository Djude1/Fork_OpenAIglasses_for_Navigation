# 手機端 YOLO 視障導航系統部署計畫

> 狀態：規劃中（2026-04-21）
> 目標：將 YOLO 推論全部移至手機端，零伺服器依賴，提升 FPS 與隱私性

---

## 架構總覽

```
手機端
├── 感知層   Camera + GPS + IMU
├── 推論層   3 個 ONNX 模型 + 場景分類器
├── 融合層   三層場景切換決策引擎
└── 輸出層   TTS 語音 + 震動
```

---

## 模型選型決策

| 功能 | 模型 | 理由 |
|------|------|------|
| 開放詞彙避障 | `yoloe-26n-seg`（11.2MB） | YOLOE nano 唯一存在的 nano，yoloe-11n-seg 不存在 |
| 紅綠燈偵測 | `yolo26n-seg` 微調（~5MB） | NMS-Free、邊緣優化、比 YOLOv8n 快 43% |
| 導航核心（curb/盲道）| `ALL.pt` → ONNX（~25MB） | 專門訓練的固定類別，YOLOE 開放詞彙無法取代 |
| 場景分類 | `MobileNetV3-Small` TFLite（~3MB） | 每秒一次、128×128 輸入、CPU < 5ms |

### 為什麼不全用 ALL.pt

ALL.pt 是固定 14 類，YOLOE-26n-seg 是開放詞彙（可帶入任意文字標籤）。
兩者互補：ALL.pt 負責導航核心（精準），YOLOE 負責通用避障（彈性）。

---

## Phase 1：PC 端準備

### 1.1 模型匯出

```python
from ultralytics import YOLO, YOLOE

# ALL.pt → ONNX（fp16）
YOLO('model/ALL.pt').export(format='onnx', half=True, simplify=True)

# yoloe-26n-seg → ONNX（Vision Encoder only，Text Encoder 不需上手機）
YOLOE('model/yoloe-26n-seg.pt').export(format='onnx', half=True, simplify=True)

# 紅綠燈微調後 → ONNX
YOLO('runs/traffic/v1/weights/best.pt').export(format='onnx', half=True, simplify=True)
```

### 1.2 預計算 Embedding（四組場景）

在 PC 上用 yoloe-26n-seg 的 Text Encoder 計算向量，存 `.npy`，手機只載向量不跑 Text Encoder。

```python
# compute_embeddings.py
import torch, numpy as np, json
from ultralytics import YOLOE

model = YOLOE('model/yoloe-26n-seg.pt')

SCENES = {
    "outdoor": [
        # 原始 37 個戶外標籤（yoloe-11l-seg 時代沿用）
        'person', 'bicycle', 'car', 'motorcycle', 'bus', 'truck',
        'animal', 'scooter', 'stroller', 'dog',
        'pole', 'post', 'bollard', 'utility pole', 'light pole', 'signpost',
        'bench', 'chair', 'potted plant', 'hydrant', 'cone', 'stone', 'box',
        'trash can', 'barrel', 'cart', 'fence', 'barrier', 'wall', 'gate', 'door',
        'rock', 'tree', 'branch', 'curb', 'stairs', 'step', 'ramp', 'hole',
        'bag', 'suitcase', 'backpack', 'table', 'ladder', 'object', 'obstacle',
    ],
    "market": [
        # 戶外核心 + 賣場專用
        'person', 'bicycle', 'car', 'motorcycle', 'bus', 'truck',
        'pole', 'cone', 'stairs', 'curb', 'door', 'gate', 'barrier',
        'shopping cart', 'shopping basket', 'checkout counter',
        'refrigerator door', 'display shelf', 'wet floor sign',
        'apple', 'banana', 'broccoli', 'carrot',
        'coke bottle', 'milk carton', 'canned food',
    ],
    "classroom": [
        # 戶外核心 + 教室專用
        'person', 'pole', 'stairs', 'door', 'bag', 'backpack',
        'whiteboard', 'projector', 'projector screen', 'lectern',
        'student desk', 'stacking chair', 'laptop', 'textbook',
        'clock', 'speaker', 'power strip',
    ],
    "crossing": [
        # 過馬路精簡 15 個（減少干擾）
        'person', 'bicycle', 'car', 'motorcycle', 'bus', 'truck',
        'traffic cone', 'barrier', 'curb', 'stairs',
        'crossing crosswalk', 'traffic light', 'pole', 'scooter', 'dog',
    ],
}

for scene_name, labels in SCENES.items():
    with torch.inference_mode():
        embeddings = model.get_text_pe(labels)
    np.save(f'embeddings/{scene_name}.npy', embeddings.cpu().numpy())
    with open(f'embeddings/{scene_name}_labels.json', 'w', encoding='utf-8') as f:
        json.dump(labels, f, ensure_ascii=False, indent=2)
    print(f'{scene_name}: {len(labels)} 個標籤，shape={embeddings.shape}')
```

### 1.3 紅綠燈模型微調

```python
# finetune_traffic.py
from ultralytics import YOLO

model = YOLO('yolo26n-seg.pt')
model.train(
    data='datasets/taiwan_traffic/data.yaml',
    epochs=100,
    imgsz=640,
    batch=16,
    project='runs/traffic',   # 純 ASCII！Windows 中文路徑地雷
    name='v1',
    patience=20,
    freeze=10,
)
```

**資料集 yaml：**
```yaml
path: datasets/taiwan_traffic
train: images/train
val: images/val
nc: 8
names:
  0: 行人紅燈
  1: 行人綠燈
  2: 行人黃燈
  3: 遠端紅燈
  4: 遠端綠燈
  5: 遠端黃燈
  6: 斑馬線
  7: 遠端斑馬線
```

**資料集來源建議：**
| 來源 | 用途 |
|------|------|
| S2TLD（中國） | 基礎大量資料 |
| 自拍台灣路口影片 | 最關鍵，50-100 張就有效 |
| Roboflow 公開集 | 補充多樣性 |

### 1.4 場景分類器

- 架構：MobileNetV3-Small
- 輸入：128×128
- 類別：`outdoor / market / classroom / indoor / crossing`
- 資料：每類 200 張（手機自拍 + 網路爬圖）
- 匯出：TFLite INT8 量化（~2MB）

---

## Phase 2：三層場景切換融合引擎

```
優先級：Layer 3（物品觸發）> Layer 2（AI 分類）> Layer 1（GPS）
```

### Layer 1：GPS（粗粒度，室外輔助）

每 30 秒查一次。預建地標資料庫（JSON 存 APP 內）：

```json
{
  "landmarks": [
    {"name": "全聯福利中心", "lat": 25.048, "lng": 121.517, "radius": 80, "scene": "market"},
    {"name": "台北火車站",   "lat": 25.047, "lng": 121.517, "radius": 200, "scene": "indoor"}
  ]
}
```

- 觸發條件：進入地標半徑 → **建議**切換（不立即，等 Layer 2 確認）
- 限制：室內 GPS 失效，完全依靠 Layer 2 + 3

### Layer 2：AI 場景分類器（每秒）

滑動視窗投票，防止場景抖動：

```dart
class SceneVoter {
  final _window = List<Scene>.filled(5, Scene.outdoor);
  int _ptr = 0;

  Scene vote(Scene newScene) {
    _window[_ptr++ % 5] = newScene;
    final counts = <Scene, int>{};
    for (var s in _window) counts[s] = (counts[s] ?? 0) + 1;
    return counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }
}
```

- 觸發條件：連續 3 秒同場景 → 正式切換

### Layer 3：模型偵測觸發（最高優先，即時）

YOLOE 偵測到場景特有物品 → 立即切換標籤集：

```dart
const TRIGGER_MAP = {
  'shopping cart':      Scene.market,
  'shopping basket':    Scene.market,
  'display shelf':      Scene.market,
  'wet floor sign':     Scene.market,
  'whiteboard':         Scene.classroom,
  'projector':          Scene.classroom,
  'student desk':       Scene.classroom,
  'crossing crosswalk': Scene.crossing,
};

void checkTriggers(List<Detection> detections) {
  for (var det in detections) {
    if (det.confidence < 0.6) continue;
    final triggered = TRIGGER_MAP[det.className];
    if (triggered != null && triggered != _currentScene) {
      _switchScene(triggered, reason: 'object_trigger:${det.className}');
      break;
    }
  }
}
```

### 融合決策完整流程

```
每秒執行：
┌─ Layer 3 有觸發物件（conf > 0.6）？
│  └─ YES → 立即切換，冷卻 15 秒
│
└─ NO → Layer 2 滑動視窗結果與當前不同？
   └─ YES → GPS 也支持？
      ├─ GPS 支持 → 立即切換
      └─ GPS 不支持或室內 → 連續 3 秒後切換
```

---

## Phase 3：Flutter 推論架構

### 3.1 套件

```yaml
dependencies:
  onnxruntime: ^1.x
  camera: ^0.10.x
  geolocator: ^10.x
  tflite_flutter: ^0.10.x
```

### 3.2 三 Isolate 並行管線

```dart
class InferencePipeline {
  late SendPort _obstaclePort;    // Isolate A：避障（每幀）
  late SendPort _trafficPort;     // Isolate B：紅綠燈（過馬路模式才啟動）
  late SendPort _classifierPort;  // Isolate C：場景分類（每秒）

  Future<void> init() async {
    _obstaclePort   = await _spawnIsolate('obstacle',    'assets/models/yoloe_26n_seg.onnx');
    _classifierPort = await _spawnIsolate('classifier',  'assets/models/scene_classifier.tflite');
    // 紅綠燈 Isolate 延遲啟動，省記憶體
  }

  void switchEmbedding(Scene scene) {
    // 不中斷推論，下一幀生效
    _obstaclePort.send({'action': 'switch_embedding', 'path': 'assets/embeddings/${scene.name}.npy'});
  }
}
```

### 3.3 記憶體預算（中階 Android 3GB RAM）

| 模型 | 記憶體 |
|------|--------|
| yoloe-26n-seg ONNX | ~80MB |
| ALL.pt ONNX（導航核心）| ~120MB |
| 場景分類器 TFLite | ~10MB |
| 紅綠燈（按需載入）| ~20MB |
| 4 組 Embedding | ~5MB |
| **合計** | **~235MB** |

> 紅綠燈模型只在「過馬路模式」啟動時載入，結束後立即釋放。

---

## Phase 4：執行順序

```
Week 1：PC 端準備
  [ ] 匯出 ALL.pt → ONNX，確認精度無損
  [ ] 執行 compute_embeddings.py，產出 4 組 .npy
  [ ] 紅綠燈資料集整理（台灣路口拍攝 100 張）
  [ ] 1-epoch 測試存檔（確認中文路徑地雷沒踩）

Week 2：紅綠燈微調
  [ ] yolo26n-seg 微調訓練
  [ ] 匯出 ONNX，驗證 8 類別正確
  [ ] 測試場 Gradio 介面驗收

Week 3：Flutter 整合
  [ ] ONNX Runtime 套件整合，跑通 ALL.pt 推論
  [ ] yoloe-26n-seg + embedding.npy 推論測試
  [ ] FPS 基準測試（目標：中階手機 10+ FPS）

Week 4：場景切換
  [ ] 場景分類器訓練並匯出 TFLite
  [ ] 三層融合邏輯實作
  [ ] GPS 地標資料庫建置
  [ ] 端對端測試

Week 5：調整優化
  [ ] Embedding 切換延遲測試
  [ ] 低端手機（2GB RAM）壓力測試
  [ ] TTS 語音播報整合驗收
```

---

## 技術風險

| 風險 | 可能性 | 應對 |
|------|--------|------|
| ONNX Runtime 不支援 yoloe-26n-seg 某層 | 中 | 先用 Python onnxruntime 驗證再轉 Flutter |
| 中階手機 FPS 不達標（< 5 FPS）| 中 | 降輸入解析度至 320×320，或每 2 幀推一次 |
| Embedding 切換時閃爍誤報 | 低 | 切換期間暫停語音播報 0.5 秒 |
| GPS 室內失效 | 高（已知）| 室內完全靠 Layer 2+3，GPS 僅戶外輔助 |

---

## 相關檔案

| 檔案 | 說明 |
|------|------|
| `model/yoloe-26n-seg.pt` | 已下載，待匯出 ONNX |
| `model/ALL.pt` | 待匯出 ONNX |
| `YOLO測試場/taiwan_trafficlight-v1.pt` | 紅綠燈微調參考基準 |
| `yolo_標籤.txt` | 教室/賣場/室內標籤來源 |
| `obstacle_detector_client.py` | 伺服器端避障邏輯（手機化後可廢棄）|
