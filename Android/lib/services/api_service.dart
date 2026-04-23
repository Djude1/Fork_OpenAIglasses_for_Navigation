// lib/services/api_service.dart
// HTTP API 呼叫（使用 dio）

import 'package:dio/dio.dart';
import '../core/constants.dart';

class ApiService {
  late final Dio _dio;
  final String host;
  final int    port;
  final bool   secure;
  final String? baseUrl;

  // Dio 已知行為：baseUrl 含路徑前綴（如 /device/1）時，
  // 帶 / 的相對路徑會被截回根路徑。
  // 此前綴用於手動補齊，確保 /api/xxx 打到正確的 /device/N/api/xxx。
  late final String _pathPrefix;

  ApiService({required this.host, required this.port, this.secure = false, this.baseUrl}) {
    _pathPrefix = _extractPathPrefix(baseUrl);
    _dio = Dio(BaseOptions(
      baseUrl:        AppConstants.httpBase(host, port, secure: secure, baseUrl: baseUrl),
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ));
  }

  static String _extractPathPrefix(String? url) {
    if (url == null || url.isEmpty || !AppConstants.isFullUrl(url)) return '';
    final path = Uri.parse(url).path.replaceAll(RegExp(r'/+$'), '');
    return (path == '' || path == '/') ? '' : path;
  }

  // 補上路徑前綴，防止 Dio 截斷 baseUrl 中的路徑
  String _api(String path) => '$_pathPrefix$path';

  // ── 健康檢查（用於測試連線）──────────────────────────────────────────────
  Future<bool> healthCheck() async {
    final resp = await _dio.get(_api('/api/health'));
    return resp.statusCode == 200;
  }

  // ── 文件閱讀 ─────────────────────────────────────────────────────────────
  /// 傳入 base64 圖片，回傳 { text, char_count }
  Future<Map<String, dynamic>> readDocument(String imageBase64) async {
    final resp = await _dio.post(
      _api('/api/read_document'),
      data: {'image_b64': imageBase64},
      options: Options(receiveTimeout: const Duration(seconds: 90)),
    );
    final data = resp.data;
    return data is Map<String, dynamic> ? data : {};
  }

  /// 傳入文件全文 + 問題，回傳 { answer }
  Future<Map<String, dynamic>> explainDocument(String text, String question) async {
    final resp = await _dio.post(
      _api('/api/explain_document'),
      data: {'text': text, 'question': question},
      options: Options(receiveTimeout: const Duration(seconds: 60)),
    );
    final data = resp.data;
    return data is Map<String, dynamic> ? data : {};
  }

  // ── 導航控制 ─────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> navState() async {
    final resp = await _dio.get(_api('/api/nav/state'));
    final data = resp.data;
    return data is Map<String, dynamic> ? data : {};
  }

  Future<void> navBlindpath()    => _dio.post(_api('/api/nav/blindpath'));
  Future<void> navCrossing()     => _dio.post(_api('/api/nav/crossing'));
  Future<void> navTrafficLight() => _dio.post(_api('/api/nav/traffic_light'));
  Future<void> navStop()         => _dio.post(_api('/api/nav/stop'));

  Future<void> navItemSearch(String itemName, {String positionMode = 'clock'}) async {
    await _dio.post(_api('/api/nav/item_search'),
        data: {'item_name': itemName, 'position_mode': positionMode});
  }

  Future<void> setPositionMode(String mode) async {
    await _dio.post(_api('/api/settings/position_mode'), data: {'mode': mode});
  }

  // ── 伺服器 Debug 狀態 ─────────────────────────────────────────────────────
  Future<Map<String, dynamic>> debugStatus() async {
    final resp = await _dio.get(_api('/api/debug_status'));
    final data = resp.data;
    return data is Map<String, dynamic> ? data : {};
  }

}
