# 手機端 YOLO 視障導航系統部署計畫

> 狀態：規劃中（2026-04-21）
> 目標：將 YOLO 推論全部移至手機端，零伺服器依賴，提升 FPS 與隱私性

---

## ⚠️ 核心原則（不可違反）

1. **ALL.pt 完全不動**：現有避障邏輯維持原樣，yoloe-26n-seg 走獨立測試路徑
2. **先測試，再整合**：yoloe-26n-seg 效果通過人工驗收後，才進行正式替換
3. **程式碼測試責任**：伺服器端 Python 測試由 Claude 負責；Flutter APP UI 由開發者驗收
4. **平行運行**：測試期間 yoloe-26n-seg 和 ALL.pt 同時存在，不互相影響

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

---

## Phase A：APP 管理員介面 — yoloe-26n-seg AR 測試頁

> 這是第一個實作目標。ALL.pt 完全不動，獨立新增測試入口。

### A.1 入口位置

在 Flutter APP 管理員設定頁（`ServerConfig.jsx` 對應的 APP 端設定畫面）新增一個按鈕：

```
設定頁
└── [開發者工具]（需登入 admin 才顯示）
    └── [yoloe-26n-seg AR 測試]  ← 新增這個
```

### A.2 AR 測試頁功能設計

```
┌─────────────────────────────────┐
│  📷 相機即時畫面（全螢幕）         │
│                                 │
│  ┌──────────────────────────┐  │
│  │  偵測框 + 標籤 + 信心值    │  │  ← AR 疊加層
│  └──────────────────────────┘  │
│                                 │
│  [戶外模式] [室內模式]           │  ← 手動切換 embedding
│                                 │
│  FPS: 12  |  模型: yoloe-26n   │  ← 狀態列
│  場景: outdoor  conf門檻: 0.25  │
│  偵測數: 3                      │
│                                 │
│  [conf ──●────] 0.25            │  ← 即時調整信心門檻
│  [錄影] [截圖] [← 返回]         │
└─────────────────────────────────┘
```

### A.3 Flutter 頁面結構

```dart
// lib/screens/yoloe_ar_test_screen.dart

class YoloeArTestScreen extends StatefulWidget { ... }

class _YoloeArTestScreenState extends State<YoloeArTestScreen> {
  late CameraController _camera;
  late OnnxModel _yoloeModel;
  EmbeddingSet _currentScene = EmbeddingSet.outdoor;
  double _confThreshold = 0.25;
  List<Detection> _detections = [];
  int _fps = 0;

  // 載入模型（僅此頁面使用，離開後釋放）
  Future<void> _initModel() async {
    _yoloeModel = await OnnxModel.load('assets/models/yoloe_26n_seg.onnx');
    await _switchScene(EmbeddingSet.outdoor);
  }

  // 切換場景 embedding
  Future<void> _switchScene(EmbeddingSet scene) async {
    final emb = await EmbeddingLoader.load(scene);
    _yoloeModel.setEmbedding(emb);
    setState(() => _currentScene = scene);
  }

  // 每幀推論
  void _onCameraFrame(CameraImage image) async {
    final result = await _yoloeModel.infer(image, conf: _confThreshold);
    setState(() => _detections = result.detections);
  }

  @override
  void dispose() {
    _yoloeModel.release();  // ← 離開頁面立即釋放，不影響主系統
    super.dispose();
  }
}
```

### A.4 AR 疊加層（CustomPainter）

```dart
class DetectionPainter extends CustomPainter {
  final List<Detection> detections;
  final Size imageSize;

  @override
  void paint(Canvas canvas, Size size) {
    for (var det in detections) {
      // 畫偵測框
      final rect = _scaleBox(det.box, imageSize, size);
      canvas.drawRect(rect, Paint()..color = Colors.green..style = PaintingStyle.stroke..strokeWidth = 2);
      // 畫標籤
      _drawLabel(canvas, '${det.label} ${(det.conf * 100).toInt()}%', rect.topLeft);
      // 畫 mask 半透明疊加（分割模型）
      if (det.mask != null) _drawMask(canvas, det.mask!, rect, Colors.green.withOpacity(0.3));
    }
  }
}
```

### A.5 程式碼測試責任（Claude 負責）

```python
# test_yoloe26n_server.py（PC 端驗證，確保模型行為正確再送 Flutter）

import numpy as np, json, torch
from ultralytics import YOLOE

def test_embedding_load():
    """驗證 embedding 可正確載入並 set_classes"""
    model = YOLOE('model/yoloe-26n-seg.pt')
    for scene in ['outdoor', 'indoor']:
        emb = torch.from_numpy(np.load(f'embeddings/{scene}.npy'))
        labels = json.load(open(f'embeddings/{scene}_labels.json', encoding='utf-8'))
        model.set_classes(labels, emb)
        assert len(model.names) == len(labels), f'{scene} 標籤數不符'
    print('embedding 載入測試 ✓')

def test_inference_shape(img_path: str):
    """驗證推論輸出有 boxes 和 masks"""
    import cv2
    model = YOLOE('model/yoloe-26n-seg.pt')
    emb = torch.from_numpy(np.load('embeddings/outdoor.npy'))
    labels = json.load(open('embeddings/outdoor_labels.json', encoding='utf-8'))
    model.set_classes(labels, emb)

    img = cv2.imread(img_path)
    r = model.predict(img, conf=0.25, verbose=False)[0]
    assert r.boxes is not None, '無 boxes 輸出'
    assert r.masks is not None, '無 masks 輸出（應為 seg 模型）'
    print(f'推論測試 ✓  偵測 {len(r.boxes)} 個物件')

def test_scene_switch_latency():
    """量測 embedding 切換延遲"""
    import time
    model = YOLOE('model/yoloe-26n-seg.pt')
    scenes = ['outdoor', 'indoor']
    for scene in scenes:
        emb = torch.from_numpy(np.load(f'embeddings/{scene}.npy'))
        labels = json.load(open(f'embeddings/{scene}_labels.json', encoding='utf-8'))
        t0 = time.perf_counter()
        model.set_classes(labels, emb)
        ms = (time.perf_counter() - t0) * 1000
        print(f'{scene} 切換延遲：{ms:.1f}ms')

if __name__ == '__main__':
    test_embedding_load()
    test_inference_shape('YOLO測試場/test_image.jpg')  # 準備一張測試圖
    test_scene_switch_latency()
```

**驗收標準（全部通過才送 Flutter）：**

| 測試項目 | 通過條件 |
|---------|---------|
| embedding 載入正確 | 標籤數完全一致 |
| 推論有 masks 輸出 | 非 None |
| 戶外偵測到人 | conf > 0.35 |
| 室內偵測到椅子/桌子 | conf > 0.30 |
| embedding 切換延遲 | < 50ms |
| ALL.pt 行為未受影響 | 獨立測試確認 |

---

## Phase B：伺服器演進計畫

> 手機端有 YOLO 之後，伺服器的角色和架構需要對應調整。

### B.1 現在的架構（伺服器負擔重）

```
ESP32 眼鏡
    │ WebSocket（影像 + 音訊）
    ▼
FastAPI 伺服器（port 8081-8084）
    ├── YOLO 推論（ALL.pt 避障/盲道/紅綠燈）  ← CPU/GPU 大戶
    ├── ASR（Google Speech-to-Text）
    ├── LLM（場景描述、語音對話）
    ├── TTS（Gemini TTS / WaveNet）
    └── NavigationMaster 狀態機
    │
    ▼
語音 + 指令回傳 ESP32
```

### B.2 手機 YOLO 後的架構（伺服器變輕）

```
手機（Flutter APP）
    ├── yoloe-26n-seg ONNX  ← 避障推論（本地）
    ├── yolo26n-seg ONNX    ← 紅綠燈（本地）
    ├── ALL.pt ONNX         ← 盲道/curb（本地）
    ├── 場景分類器 TFLite   ← 場景切換（本地）
    └── TTS WAV 預錄音檔    ← 基本語音（本地）
         │
         │ 只在需要時才上傳（省頻寬）
         ▼
FastAPI 伺服器（精簡版）
    ├── ASR（語音對話觸發時）
    ├── LLM（場景描述、複雜問答）   ← 保留，手機算力不夠
    ├── 高品質 TTS（WaveNet/Gemini）← 保留，複雜語音
    ├── NavigationMaster 狀態機     ← 保留，邏輯複雜
    └── 用戶資料/聯絡人/設定同步    ← 保留
```

### B.3 伺服器需要新增的 API

手機有了本地 YOLO 後，伺服器需要新增以下端點配合：

```python
# 新增端點（app_main.py 擴充）

# 1. 手機回報偵測結果 → 伺服器做高層決策
@app.post("/api/mobile/detections")
async def receive_mobile_detections(payload: MobileDetectionPayload):
    """
    手機每秒回報偵測到的物件清單
    伺服器根據此資訊觸發：場景描述、危險警告、導航指令
    """
    detections = payload.detections   # [{label, conf, position}, ...]
    scene = payload.scene             # outdoor / indoor
    # 判斷是否需要 LLM 場景描述
    if _needs_description(detections):
        asyncio.create_task(_trigger_description(detections))
    return {"action": "none"}  # 或 {"action": "tts", "text": "前方有人"}

# 2. 手機請求場景描述
@app.post("/api/mobile/describe_scene")
async def describe_scene(image: UploadFile):
    """手機拍一張圖 → 伺服器 LLM 描述 → 回傳文字"""
    ...

# 3. Embedding 版本管理（手機定期同步）
@app.get("/api/mobile/embeddings/version")
async def get_embedding_version():
    """讓手機知道 embedding 有無更新需要下載"""
    return {"version": EMBEDDING_VERSION, "scenes": ["outdoor", "indoor", "market", "classroom"]}

@app.get("/api/mobile/embeddings/{scene}")
async def download_embedding(scene: str):
    """手機下載最新 embedding"""
    ...
```

### B.4 伺服器不再需要做的事（可逐步移除）

| 功能 | 現在 | 手機 YOLO 後 |
|------|------|-------------|
| 避障 YOLO 推論 | ✅ 伺服器 | ❌ 移至手機 |
| 盲道分割 YOLO | ✅ 伺服器 | ❌ 移至手機 |
| 紅綠燈偵測 YOLO | ✅ 伺服器 | ❌ 移至手機 |
| 基本 TTS 播報 | ✅ 伺服器 | ❌ 本地 WAV |
| ASR 語音辨識 | ✅ 伺服器 | ✅ 保留 |
| LLM 場景描述 | ✅ 伺服器 | ✅ 保留 |
| 高品質 TTS | ✅ 伺服器 | ✅ 保留 |
| NavigationMaster | ✅ 伺服器 | ✅ 保留（或部分移植）|

### B.5 過渡期策略（不硬切）

```
Stage 1（現在）：ALL.pt 在伺服器，yoloe-26n-seg 在 APP 測試
    ↓ yoloe-26n-seg 驗收通過
Stage 2：APP 主用 yoloe-26n-seg 避障，伺服器 ALL.pt 仍保留作備援
    ↓ 穩定運行 2 週
Stage 3：伺服器移除 YOLO 推論，改為輕量化；APP 完全本地 YOLO
```

---

## 更新後的 Phase 執行順序

```
【立即可做】
Phase A：
  [ ] A1. 計算 outdoor.npy / indoor.npy（compute_walk_embeddings.py）
  [ ] A2. 執行 test_yoloe26n_server.py → 全部測試通過
  [ ] A3. Flutter APP 新增管理員入口按鈕
  [ ] A4. 實作 YoloeArTestScreen（相機 + AR 疊加 + 場景切換）
  [ ] A5. 開發者手動驗收（戶外/室內實地測試）

【A 驗收通過後】
Phase 1-4（原計畫）：
  完整手機端部署 + 場景切換引擎

【平行進行】
Phase B：
  [ ] B1. 新增 /api/mobile/detections 端點
  [ ] B2. 新增 embedding 版本管理端點
  [ ] B3. 設計手機→伺服器的決策協議
  [ ] B4. Stage 2 過渡測試（雙軌並行）
```
