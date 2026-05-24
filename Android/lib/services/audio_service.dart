// lib/services/audio_service.dart
// 音訊服務：
//   1. 麥克風 PCM16 錄音 → WebSocket 上行
//   2. /stream.wav HTTP 下行播放（TTS）
//   3. 前台服務背景監聽（喚醒詞偵測）

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import '../core/constants.dart';

typedef PcmChunkCallback = void Function(Uint8List pcm16);
typedef WakeWordCallback  = void Function();

class AudioService {
  // ── 麥克風錄音 ──────────────────────────────────────────────────────────
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription? _recordSub;
  bool _recording = false;
  PcmChunkCallback? _onChunkCb;        // 保存 callback 供自動重啟使用
  DateTime _lastChunkAt = DateTime.now();
  Timer? _micWatchdog;
  bool _restarting = false;            // 防止 onError + watchdog 同時重啟

  // DEBUG：mic 幀率追蹤（每秒印一次）— 診斷「WAKE 後 mic 不送幀」
  int _micChunkCountWindow = 0;
  int _micBytesWindow = 0;
  DateTime _micRateWindowStart = DateTime.now();

  // DEBUG：mic 全域累計（給 app_provider 在 cycle 結束時印 summary）
  int _micTotalChunks = 0;
  int _micTotalSamples = 0;
  int get micTotalChunks => _micTotalChunks;
  int get micTotalSamples => _micTotalSamples;
  void resetMicCounter() {
    _micTotalChunks = 0;
    _micTotalSamples = 0;
  }

  // ── TTS 串流重連狀態 ─────────────────────────────────────────────────────
  bool _shouldPlayStream = false;   // 是否應維持串流播放
  bool _isReconnecting   = false;   // 防止多個重連同時觸發
  String? _streamUrl;               // 串流 URL（用於重連）
  StreamSubscription<PlayerState>? _playerStateSub; // 播放狀態監聽

  /// 開始錄音並以 PCM16 Chunk 回呼
  Future<void> startMicrophone({required PcmChunkCallback onChunk}) async {
    if (_recording) return;
    _recording = true;
    _onChunkCb = onChunk;

    await _startInternal();
    _startMicWatchdog();
  }

  /// 內部啟動 stream（首次啟動 + 自動重啟共用）
  Future<void> _startInternal() async {
    // 音源用 voiceRecognition：Android 專為 ASR 設計的音源，內建合理的
    // noise suppression，但不會像 voiceCommunication 過度抑制把人聲也消掉
    // （voiceCommunication 是「雙工通話」音源，AEC 過強會讓 RMS 降到 0~2，
    //   實測在 server 端整段對話完全收不到人聲）。
    // 不設 audioManagerMode：避免改變系統音訊路由造成裝置間行為差異。
    final stream = await _recorder.startStream(const RecordConfig(
      encoder:    AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
      androidConfig: AndroidRecordConfig(
        audioSource: AndroidAudioSource.voiceRecognition,
      ),
    ));

    _lastChunkAt = DateTime.now();
    _micRateWindowStart = DateTime.now();
    _micChunkCountWindow = 0;
    _micBytesWindow = 0;
    debugPrint('[MIC-DEBUG] startStream OK @ ${DateTime.now().toIso8601String()}');
    _recordSub = stream.listen(
      (data) {
        _lastChunkAt = DateTime.now();
        _micChunkCountWindow++;
        _micBytesWindow += data.length;
        _micTotalChunks++;
        _micTotalSamples += data.length ~/ 2;  // PCM16
        final elapsedMs = DateTime.now().difference(_micRateWindowStart).inMilliseconds;
        if (elapsedMs >= 1000) {
          final samples = _micBytesWindow ~/ 2;  // PCM16
          final audioMs = samples * 1000 ~/ 16000;
          debugPrint('[MIC-RATE] last ${elapsedMs}ms: $_micChunkCountWindow chunks, '
              '$samples samples (=${audioMs}ms audio) @ ${DateTime.now().toIso8601String()}');
          _micChunkCountWindow = 0;
          _micBytesWindow = 0;
          _micRateWindowStart = DateTime.now();
        }
        _onChunkCb?.call(Uint8List.fromList(data));
      },
      onError: (e) {
        debugPrint('[AudioService] 錄音 stream onError: $e → 嘗試重啟麥克風');
        _restartMic('stream onError');
      },
      onDone: () {
        debugPrint('[AudioService] 錄音 stream onDone → 嘗試重啟麥克風');
        _restartMic('stream onDone');
      },
      cancelOnError: true,
    );
  }

  /// Watchdog：2 秒沒新 chunk → 強制重啟麥克風
  /// （即使 stream 沒拋 onError/onDone，半關閉狀態也能恢復）
  /// 從 5 秒縮到 2 秒：chime 播放後 Android 暫停 AudioRecord callback，
  /// LocalVoiceService.onChimeComplete 會主動觸發 restart，watchdog 為保底
  void _startMicWatchdog() {
    _micWatchdog?.cancel();
    _micWatchdog = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_recording) return;
      final since = DateTime.now().difference(_lastChunkAt).inMilliseconds;
      if (since >= 2000) {
        debugPrint('[AudioService] watchdog: ${since}ms 無新 audio chunk → 重啟麥克風');
        _restartMic('watchdog ${since}ms no chunk');
      }
    });
  }

  /// 外部主動觸發 mic 重啟（chime 播完後立刻呼叫，不等 watchdog）
  /// audioplayers 播 chime 時 Android AudioFlinger 暫停 voiceRecognition
  /// AudioRecord callback，chime 結束不會自動恢復，需主動 restart。
  Future<void> restartMicNow(String reason) async {
    if (!_recording || _restarting) return;
    debugPrint('[AudioService] restartMicNow: $reason');
    await _restartMic(reason);
  }

  Future<void> _restartMic(String reason) async {
    if (_restarting || !_recording || _onChunkCb == null) return;
    _restarting = true;
    try {
      try { await _recordSub?.cancel(); } catch (_) {}
      _recordSub = null;
      try { await _recorder.stop(); } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 200));
      await _startInternal();
      debugPrint('[AudioService] 麥克風重啟成功（原因: $reason）');
    } catch (e) {
      debugPrint('[AudioService] 麥克風重啟失敗: $e（原因: $reason）→ 1 秒後重試');
      Future.delayed(const Duration(seconds: 1), () {
        if (_recording) _restartMic('retry after fail: $reason');
      });
    } finally {
      _restarting = false;
    }
  }

  Future<void> stopMicrophone() async {
    _recording = false;
    _onChunkCb = null;
    _micWatchdog?.cancel();
    _micWatchdog = null;
    await _recordSub?.cancel();
    _recordSub = null;
    await _recorder.stop();
  }

  bool get isRecording => _recording;

  // ── TTS 下行播放 ─────────────────────────────────────────────────────────
  final AudioPlayer _player = AudioPlayer();

  Future<void> playStreamWav(String host, int port,
      {bool secure = false, String? baseUrl}) async {
    final url = AppConstants.streamWav(host, port,
        secure: secure, baseUrl: baseUrl);
    _streamUrl = url;
    _shouldPlayStream = true;

    // 設定音量為最大
    await _player.setVolume(1.0);

    // 取消舊的狀態監聽，重新設置
    await _playerStateSub?.cancel();
    _playerStateSub = _player.onPlayerStateChanged.listen((state) {
      debugPrint('[AudioService] 播放狀態變更: $state');
      // 只在 completed 時重連（stopped 是 play() 內部切換時觸發，不重連以避免循環）
      if (_shouldPlayStream && state == PlayerState.completed) {
        debugPrint('[AudioService] 串流中斷，準備重連...');
        _scheduleReconnect();
      }
    });

    // 監聽播放器錯誤
    _player.onLog.listen((msg) {
      debugPrint('[AudioService] 播放器日誌: $msg');
    });

    debugPrint('[AudioService] 連線 /stream.wav: $url');
    try {
      await _player.play(UrlSource(url));
      debugPrint('[AudioService] 播放已啟動');
    } catch (e) {
      debugPrint('[AudioService] 播放失敗: $e');
      _scheduleReconnect();
    }
  }

  /// 延遲後重新連線 /stream.wav（伺服器可能因重置而切斷連線）
  void _scheduleReconnect() {
    // 防止多個重連同時觸發（racing condition 保護）
    if (!_shouldPlayStream || _streamUrl == null || _isReconnecting) return;
    _isReconnecting = true;
    Future.delayed(const Duration(milliseconds: 800), () async {
      if (!_shouldPlayStream || _streamUrl == null) {
        _isReconnecting = false;
        return;
      }
      debugPrint('[AudioService] 重連 /stream.wav...');
      try {
        // 先確保播放器處於乾淨狀態再設定新來源
        await _player.stop();
        await Future.delayed(const Duration(milliseconds: 100));
        await _player.play(UrlSource(_streamUrl!));
        debugPrint('[AudioService] 重連成功');
      } catch (e) {
        debugPrint('[AudioService] 重連失敗: $e');
        _isReconnecting = false;
        // 連線失敗，2 秒後再試（加長間隔避免短時間狂打 server）
        Future.delayed(const Duration(seconds: 2), _scheduleReconnect);
        return;
      }
      _isReconnecting = false;
    });
  }

  Future<void> stopPlayback() async {
    _shouldPlayStream = false;
    _isReconnecting   = false;
    _streamUrl = null;
    await _playerStateSub?.cancel();
    _playerStateSub = null;
    await _player.stop();
  }

  /// 本地語音播放時，將 /stream.wav 靜音 [durationMs] 毫秒以避免重疊
  /// 本地播完後自動恢復音量
  Future<void> suppressStreamFor(int durationMs) async {
    await _player.setVolume(0.0);
    await Future.delayed(Duration(milliseconds: durationMs + 200)); // 多200ms緩衝
    if (_shouldPlayStream) {
      await _player.setVolume(1.0);
    }
  }

  // ── 前台服務（背景監聽）─────────────────────────────────────────────────
  bool _foregroundRunning = false;

  Future<void> startForegroundService() async {
    if (_foregroundRunning) return;
    _foregroundRunning = true;

    await FlutterForegroundTask.startService(
      notificationTitle: 'AI智慧眼鏡',
      notificationText:  '背景監聽中，隨時可呼叫語音指令',
      callback: _foregroundTaskCallback,
    );
  }

  Future<void> stopForegroundService() async {
    _foregroundRunning = false;
    await FlutterForegroundTask.stopService();
  }

  bool get isForegroundRunning => _foregroundRunning;

  Future<void> dispose() async {
    _shouldPlayStream = false;
    _isReconnecting   = false;
    _streamUrl = null;
    await _playerStateSub?.cancel();
    _playerStateSub = null;
    await stopMicrophone();
    await _player.dispose();
  }
}

/// 前台服務回呼函式（必須是頂層函式）
@pragma('vm:entry-point')
void _foregroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_AudioTaskHandler());
}

class _AudioTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // 前台服務啟動，可在此初始化背景錄音邏輯
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // 每 5 秒觸發一次，可用於保活心跳
    FlutterForegroundTask.updateService(
      notificationTitle: 'AI智慧眼鏡',
      notificationText:  '背景監聽中 ${_timeStr(timestamp)}',
    );
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {}

  String _timeStr(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
