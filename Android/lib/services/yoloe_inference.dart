// lib/services/yoloe_inference.dart
// 手機端 yoloe-26m-seg ONNX 推論管線（避障偵測模式）
// 對應計畫：MD/plan_mobile_yolo_deployment.md Phase 3.1
//
// 定位：只做「避開障礙」— 偵測白名單類別 → 回傳 box +
//       area_ratio + bottom_y_ratio，交給 painter 依「近紅遠黃、只描邊」畫。
//       不做室內/室外區分（以後若要再加，另開切換）。
//
// 模型：yoloe-26m-seg.onnx（seg 模型，output0=[1,4+nc+32,8400]，output1 mask proto）
//       偵測模式：只讀 output0，output1 完全忽略（省略 proto flatten ~150ms）。
//
// 流程：CameraImage(YUV420) → 主 isolate copy plane bytes
//      → compute(_preprocessIsolate) → background isolate 跑 YUV→RGB→letterbox→CHW
//      → 主 isolate 拿 Float32List → OrtSession.runAsync (native worker thread)
//      → 主 isolate 只攤平 outputs[0]（OrtEnv 是 FFI singleton 不能跨 isolate；
//        僅讀 output0 約 689K floats，省略 output1 的 mask proto ~819K floats）
//      → compute(_decodeIsolate) → background isolate 跑 NMS + bbox 面積比
//        → 旋轉 90° CW → List<Detection>，並計算 area_ratio / bottom_y_ratio
//      → 主 isolate 拿 List<Detection>，CustomPainter 依近/遠上色描邊

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Rect;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:onnxruntime_v2/onnxruntime_v2.dart';

import '../screens/yoloe_ar_test_screen.dart' show Detection, InferResult;

// 與伺服器 obstacle_detector_client.WHITELIST_CLASSES 保持同步
const Set<String> _kObstacleWhitelist = {
  'person', 'bicycle', 'car', 'motorcycle', 'bus', 'truck',
  'animal', 'scooter', 'stroller', 'dog',
  'pole', 'post', 'bollard', 'utility pole', 'light pole', 'signpost',
  'bench', 'chair', 'potted plant', 'hydrant', 'cone', 'stone', 'box',
  'trash can', 'barrel', 'cart',
  'fence', 'barrier', 'wall', 'gate', 'door',
  'rock', 'tree', 'branch', 'curb',
  'stairs', 'step', 'ramp', 'hole',
  'bag', 'suitcase', 'backpack',
  'table', 'ladder',
  'object', 'obstacle',
};

class YoloeInference {
  static const int imgsz = 640;
  static const double _defaultConfTh = 0.25;
  static const double _iouTh = 0.50;
  // yoloe-seg output0 固定含 32 個 mask 係數；偵測模式下忽略但仍需用於計算 numAnchors
  static const int _numMaskCoef = 32;

  OrtSession? _session;
  List<String> _labels = const [];
  String _inputName = 'images';
  bool _busy = false;
  bool _disposed = false;
  int _debugCnt = 0;
  double confTh = _defaultConfTh;

  bool get isReady => _session != null && !_disposed;
  List<String> get labels => _labels;
  bool get isBusy => _busy;

  Future<void> init() async {
    OrtEnv.instance.init();
    const modelAsset = 'assets/models/yoloe_26m_seg_outdoor.onnx';
    const labelAsset = 'assets/models/outdoor_labels.json';

    final modelBytes =
        (await rootBundle.load(modelAsset)).buffer.asUint8List();
    _session?.release();
    final opts = OrtSessionOptions()
      ..setIntraOpNumThreads(4)    // SD855 有 8 核心，4 執行緒推論；XNNPACK 會繼承此設定
      ..appendXnnpackProvider();   // XNNPACK：Google 優化 FP32 conv，ARM NEON 加速
    _session = OrtSession.fromBuffer(modelBytes, opts);
    opts.release();
    final names = _session!.inputNames;
    _inputName = names.isNotEmpty ? names.first : 'images';

    final labelStr = await rootBundle.loadString(labelAsset);
    _labels = (jsonDecode(labelStr) as List).cast<String>();
    debugPrint('[YoloeInference] 模型輸入名稱: $_inputName, 標籤數: ${_labels.length}');
  }

  Future<void> dispose() async {
    _disposed = true;
    for (int i = 0; i < 200; i++) {
      if (!_busy) break;
      await Future.delayed(const Duration(milliseconds: 10));
    }
    try {
      _session?.release();
      _session = null;
      OrtEnv.instance.release();
    } catch (e) {
      debugPrint('[YoloeInference] dispose release error: $e');
    }
  }

  Future<InferResult?> infer(CameraImage frame) async {
    if (_disposed || _session == null || _busy) return null;
    final srcW = frame.width;
    final srcH = frame.height;
    _busy = true;
    try {
      final req = _PreReq(
        y: Uint8List.fromList(frame.planes[0].bytes),
        u: Uint8List.fromList(frame.planes[1].bytes),
        v: Uint8List.fromList(frame.planes[2].bytes),
        yStride: frame.planes[0].bytesPerRow,
        uvStride: frame.planes[1].bytesPerRow,
        uvPixelStride: frame.planes[1].bytesPerPixel ?? 1,
        width: frame.width,
        height: frame.height,
      );

      final pre = await compute(_preprocessIsolate, req);

      final input = OrtValueTensor.createTensorWithDataList(
        pre.data,
        [1, 3, imgsz, imgsz],
      );
      final runOpts = OrtRunOptions();
      final List<OrtValue?>? rawOutputs =
          await _session!.runAsync(runOpts, {_inputName: input});
      input.release();
      runOpts.release();

      if (rawOutputs == null || rawOutputs.isEmpty) {
        debugPrint('[YoloeInference] runAsync() 回傳空 outputs');
        return InferResult(detections: const [], srcW: srcW, srcH: srcH);
      }

      // 只讀 output0；output1（mask proto）完全略過，省約 150ms flatten
      final raw0 = rawOutputs[0]?.value;
      for (final o in rawOutputs) {
        o?.release();
      }
      if (raw0 is! List) {
        debugPrint('[YoloeInference] output0.value 非 List，型別=${raw0.runtimeType}');
        return InferResult(detections: const [], srcW: srcW, srcH: srcH);
      }

      final flat0 = _flatten3D(raw0);
      final nc = _labels.length;
      // output0 shape: (4+nc+_numMaskCoef, 8400)；含 mask coef 欄但不解碼
      final numAnchors = flat0.length ~/ (4 + nc + _numMaskCoef);

      final decoded = await compute(_decodeIsolate, _DecodeReq(
        output0: flat0,
        nc: nc,
        numAnchors: numAnchors,
        scale: pre.scale,
        padX: pre.padX,
        padY: pre.padY,
        effW: pre.effW,
        effH: pre.effH,
        confTh: confTh,
        iouTh: _iouTh,
        labels: _labels,
      ));

      _debugCnt++;
      if (_debugCnt % 10 == 0) {
        final first = decoded.detections.isNotEmpty ? decoded.detections.first : null;
        debugPrint(
          '[YoloeInference] frame=${srcW}x$srcH '
          'scale=${pre.scale.toStringAsFixed(3)} '
          'pad=(${pre.padX},${pre.padY}) '
          'globalMax=${decoded.globalMaxConf.toStringAsFixed(3)} '
          'top3=[${decoded.dbgTop3}] '
          'confPass=${decoded.dbgConfPass} nmsKeep=${decoded.dbgNmsKeep} '
          'box=${decoded.dbgBox} area=${decoded.dbgArea} wl=${decoded.dbgWl} '
          'dets=${decoded.detections.length} '
          'first=${first == null ? "none" : "${first.label} ${(first.confidence * 100).toInt()}%"}',
        );
      }

      return InferResult(
        detections: decoded.detections,
        srcW: srcW,
        srcH: srcH,
        globalMaxConf: decoded.globalMaxConf,
      );
    } catch (e, st) {
      debugPrint('[YoloeInference] infer error: $e\n$st');
      return InferResult(detections: const [], srcW: srcW, srcH: srcH);
    } finally {
      _busy = false;
    }
  }

  // 攤平 (1, A, B) → Float32List length A*B（row-major）
  static Float32List _flatten3D(List raw) {
    final outer = raw[0] as List;
    final a = outer.length;
    final b = (outer[0] as List).length;
    final out = Float32List(a * b);
    for (int i = 0; i < a; i++) {
      final row = (outer[i] as List).cast<num>();
      final base = i * b;
      for (int j = 0; j < b; j++) {
        out[base + j] = row[j].toDouble();
      }
    }
    return out;
  }
}

// ────────────────────────────────────────────────────────────────────
// 跨 isolate 前處理
// ────────────────────────────────────────────────────────────────────

class _PreReq {
  final Uint8List y, u, v;
  final int yStride, uvStride, uvPixelStride;
  final int width, height;
  const _PreReq({
    required this.y,
    required this.u,
    required this.v,
    required this.yStride,
    required this.uvStride,
    required this.uvPixelStride,
    required this.width,
    required this.height,
  });
}

class _PreRes {
  final Float32List data;
  final double scale;
  final int padX, padY;
  final int effW, effH;
  const _PreRes({
    required this.data,
    required this.scale,
    required this.padX,
    required this.padY,
    required this.effW,
    required this.effH,
  });
}

const int _kImgsz = 640;

/// background isolate：YUV420 → RGB → letterbox 640×640 → CHW Float32 0-1
_PreRes _preprocessIsolate(_PreReq req) {
  final w = req.width, h = req.height;

  // 1. YUV→RGB（BT.601 limited，純整數運算）
  final rgb = Uint8List(w * h * 3);
  int idx = 0;
  for (int y = 0; y < h; y++) {
    final yRow = y * req.yStride;
    final uvRow = (y >> 1) * req.uvStride;
    for (int x = 0; x < w; x++) {
      final yp = req.y[yRow + x];
      final uvCol = (x >> 1) * req.uvPixelStride;
      final up = req.u[uvRow + uvCol];
      final vp = req.v[uvRow + uvCol];
      final u = up - 128;
      final v = vp - 128;
      int r = yp + ((1436 * v) >> 10);
      int g = yp - ((352 * u + 731 * v) >> 10);
      int b = yp + ((1814 * u) >> 10);
      if (r < 0) {
        r = 0;
      } else if (r > 255) {
        r = 255;
      }
      if (g < 0) {
        g = 0;
      } else if (g > 255) {
        g = 255;
      }
      if (b < 0) {
        b = 0;
      } else if (b > 255) {
        b = 255;
      }
      rgb[idx++] = r;
      rgb[idx++] = g;
      rgb[idx++] = b;
    }
  }

  // 2. 旋轉 90° CW：Android 後鏡頭 sensor 橫向傳送，直立持機時 YOLO 收到側倒影像
  final src = img.Image.fromBytes(
    width: w,
    height: h,
    bytes: rgb.buffer,
    order: img.ChannelOrder.rgb,
  );
  final rotated = img.copyRotate(src, angle: -90);
  final rW = rotated.width;
  final rH = rotated.height;

  // 3. Letterbox：等比 resize 貼到 114 背景
  final r = (_kImgsz / rW) < (_kImgsz / rH) ? _kImgsz / rW : _kImgsz / rH;
  final newW = (rW * r).round();
  final newH = (rH * r).round();
  final padX = (_kImgsz - newW) ~/ 2;
  final padY = (_kImgsz - newH) ~/ 2;

  final resized = img.copyResize(rotated,
      width: newW, height: newH, interpolation: img.Interpolation.linear);
  final canvas = img.Image(width: _kImgsz, height: _kImgsz);
  img.fill(canvas, color: img.ColorRgb8(114, 114, 114));
  img.compositeImage(canvas, resized, dstX: padX, dstY: padY);

  // 4. HWC u8 → CHW f32 0-1
  final bytes = canvas.getBytes(order: img.ChannelOrder.rgb);
  final n = _kImgsz * _kImgsz;
  final out = Float32List(3 * n);
  for (int i = 0; i < n; i++) {
    out[i] = bytes[i * 3] / 255.0;
    out[n + i] = bytes[i * 3 + 1] / 255.0;
    out[2 * n + i] = bytes[i * 3 + 2] / 255.0;
  }
  return _PreRes(data: out, scale: r, padX: padX, padY: padY, effW: rW, effH: rH);
}

// ────────────────────────────────────────────────────────────────────
// 跨 isolate 後處理：NMS + bbox → area_ratio / bottom_y_ratio
// ────────────────────────────────────────────────────────────────────

class _DecodeReq {
  final Float32List output0;     // (4+nc+32) × numAnchors，row-major
  final int nc;
  final int numAnchors;
  final double scale;
  final int padX, padY;
  final int effW, effH;
  final double confTh, iouTh;
  final List<String> labels;
  const _DecodeReq({
    required this.output0,
    required this.nc,
    required this.numAnchors,
    required this.scale,
    required this.padX,
    required this.padY,
    required this.effW,
    required this.effH,
    required this.confTh,
    required this.iouTh,
    required this.labels,
  });
}

class _DecodeResult {
  final List<Detection> detections;
  final double globalMaxConf;
  final int dbgConfPass;
  final int dbgNmsKeep;
  final int dbgBox;
  final int dbgArea;
  final int dbgWl;
  final String dbgTop3;
  const _DecodeResult(this.detections, this.globalMaxConf,
      {this.dbgConfPass = 0, this.dbgNmsKeep = 0,
       this.dbgBox = 0, this.dbgArea = 0, this.dbgWl = 0,
       this.dbgTop3 = ''});
}

_DecodeResult _decodeIsolate(_DecodeReq req) {
  final na = req.numAnchors;
  final nc = req.nc;
  if (na <= 0 || nc <= 0 || req.output0.length < (4 + nc) * na) {
    return _DecodeResult(const [], 0.0);
  }

  // ── 1. 候選收集 ──
  final boxes  = <List<double>>[];
  final scores = <double>[];
  final ids    = <int>[];

  double globalMax = 0.0;
  double t0 = 0.0, t1 = 0.0, t2 = 0.0;
  int ti0 = -1, ti1 = -1, ti2 = -1;
  for (int a = 0; a < na; a++) {
    for (int c = 0; c < nc; c++) {
      final s = req.output0[(4 + c) * na + a];
      if (s > globalMax) globalMax = s;
      if (s > t2) {
        if (s > t0) {
          t2 = t1; ti2 = ti1; t1 = t0; ti1 = ti0; t0 = s; ti0 = c;
        } else if (s > t1) {
          t2 = t1; ti2 = ti1; t1 = s; ti1 = c;
        } else {
          t2 = s; ti2 = c;
        }
      }
    }
  }
  final top3buf = StringBuffer();
  for (int k = 0; k < 3; k++) {
    final id = k == 0 ? ti0 : (k == 1 ? ti1 : ti2);
    final sc = k == 0 ? t0 : (k == 1 ? t1 : t2);
    if (id < 0) break;
    if (top3buf.isNotEmpty) top3buf.write(',');
    top3buf.write('${req.labels[id]}:${sc.toStringAsFixed(3)}');
  }
  final top3str = top3buf.toString();

  for (int a = 0; a < na; a++) {
    double maxConf = 0.0;
    int maxId = -1;
    for (int c = 0; c < nc; c++) {
      final s = req.output0[(4 + c) * na + a];
      if (s > maxConf) { maxConf = s; maxId = c; }
    }
    if (maxConf < req.confTh || maxId < 0) continue;
    final cx = req.output0[a];
    final cy = req.output0[na + a];
    final bw = req.output0[2 * na + a];
    final bh = req.output0[3 * na + a];
    boxes.add([cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2]);
    scores.add(maxConf);
    ids.add(maxId);
  }

  if (boxes.isEmpty) return _DecodeResult(const [], globalMax);

  final keep = _isoNms(boxes, scores, req.iouTh);

  // ── 2. 還原 bbox 至 portrait 座標，計算 area_ratio ──
  final dets = <Detection>[];
  final srcWf = req.effW.toDouble();
  final srcHf = req.effH.toDouble();
  int dbgBox = 0, dbgArea = 0, dbgWl = 0;

  for (final i in keep) {
    double bx1 = (boxes[i][0] - req.padX) / req.scale;
    double by1 = (boxes[i][1] - req.padY) / req.scale;
    double bx2 = (boxes[i][2] - req.padX) / req.scale;
    double by2 = (boxes[i][3] - req.padY) / req.scale;
    if (bx1 < 0) bx1 = 0;
    if (by1 < 0) by1 = 0;
    if (bx2 > srcWf) bx2 = srcWf;
    if (by2 > srcHf) by2 = srcHf;
    if (bx2 <= bx1 || by2 <= by1) { dbgBox++; continue; }

    final areaRatio = (bx2 - bx1) * (by2 - by1) / (srcWf * srcHf);
    if (areaRatio > 0.9) { dbgArea++; continue; }

    final bottomYRatio = by2 / srcHf;
    final label = req.labels[ids[i]];
    if (!_kObstacleWhitelist.contains(label)) { dbgWl++; continue; }

    dets.add(Detection(
      label: label,
      confidence: scores[i],
      box: Rect.fromLTWH(bx1, by1, bx2 - bx1, by2 - by1),
      areaRatio: areaRatio,
      bottomYRatio: bottomYRatio,
    ));
  }

  return _DecodeResult(dets, globalMax,
      dbgConfPass: boxes.length, dbgNmsKeep: keep.length,
      dbgBox: dbgBox, dbgArea: dbgArea, dbgWl: dbgWl,
      dbgTop3: top3str);
}

List<int> _isoNms(
    List<List<double>> boxes, List<double> scores, double iouTh) {
  final n = boxes.length;
  if (n == 0) return const [];
  final order = List<int>.generate(n, (i) => i)
    ..sort((a, b) => scores[b].compareTo(scores[a]));
  final keep = <int>[];
  final sup = List<bool>.filled(n, false);
  for (int oi = 0; oi < n; oi++) {
    final i = order[oi];
    if (sup[i]) continue;
    keep.add(i);
    for (int oj = oi + 1; oj < n; oj++) {
      final j = order[oj];
      if (sup[j]) continue;
      if (_isoIou(boxes[i], boxes[j]) > iouTh) sup[j] = true;
    }
  }
  return keep;
}

double _isoIou(List<double> a, List<double> b) {
  final x1 = a[0] > b[0] ? a[0] : b[0];
  final y1 = a[1] > b[1] ? a[1] : b[1];
  final x2 = a[2] < b[2] ? a[2] : b[2];
  final y2 = a[3] < b[3] ? a[3] : b[3];
  final w = x2 - x1, h = y2 - y1;
  if (w <= 0 || h <= 0) return 0.0;
  final inter = w * h;
  final areaA = (a[2] - a[0]) * (a[3] - a[1]);
  final areaB = (b[2] - b[0]) * (b[3] - b[1]);
  return inter / (areaA + areaB - inter + 1e-9);
}
