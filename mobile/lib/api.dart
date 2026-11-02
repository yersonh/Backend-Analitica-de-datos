// Cliente HTTP del backend SIDFAM (FastAPI).
//
// La app usa los mismos endpoints JSON que el panel web. La única diferencia
// es la autenticación: en vez de la cookie, envía el token firmado en
// `Authorization: Bearer <token>` (lo entrega POST /api/login).

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class ApiException implements Exception {
  ApiException(this.status, this.message);
  final int status;
  final String message;

  @override
  String toString() => message;
}

/// El token caducó o fue revocado (cambio de clave, rol, desactivación...).
class UnauthorizedException extends ApiException {
  UnauthorizedException([String message = 'Tu sesión expiró. Inicia sesión de nuevo.']) : super(401, message);
}

class ApiClient {
  String baseUrl = '';
  String? token;

  /// Se llama cuando el servidor responde 401 a una petición con token.
  void Function()? onUnauthorized;

  final http.Client _http = http.Client();
  static const _timeout = Duration(seconds: 20);

  Uri _uri(String path, [Map<String, String>? query]) {
    final uri = Uri.parse(baseUrl + path);
    return (query == null || query.isEmpty) ? uri : uri.replace(queryParameters: query);
  }

  Map<String, String> _headers([Map<String, String>? extra]) => {
    'Accept': 'application/json',
    if (token != null) 'Authorization': 'Bearer $token',
    ...?extra,
  };

  Future<http.Response> _send(Future<http.Response> Function() call, String path) async {
    http.Response r;
    try {
      r = await call().timeout(_timeout);
    } catch (e) {
      throw ApiException(0, 'Sin conexión con el servidor ($baseUrl)');
    }
    if (r.statusCode >= 200 && r.statusCode < 300) return r;

    final message = _errorMessage(r);
    if (r.statusCode == 401 && path != '/api/login') {
      onUnauthorized?.call();
      throw UnauthorizedException();
    }
    throw ApiException(r.statusCode, message);
  }

  static String _errorMessage(http.Response r) {
    try {
      final data = jsonDecode(utf8.decode(r.bodyBytes));
      final d = data is Map ? data['detail'] : null;
      if (d is String) return d;
      if (d is List) return d.map((x) => x is Map ? x['msg'] : x).join(', ');
    } catch (_) {}
    return 'Error ${r.statusCode}';
  }

  static dynamic _json(http.Response r) => jsonDecode(utf8.decode(r.bodyBytes));

  Future<Map<String, dynamic>> getJson(String path, [Map<String, String>? query]) async {
    final r = await _send(() => _http.get(_uri(path, query), headers: _headers()), path);
    return (_json(r) as Map).cast<String, dynamic>();
  }

  Future<Uint8List> getBytes(String path, [Map<String, String>? query]) async {
    final r = await _send(() => _http.get(_uri(path, query), headers: _headers({'Accept': '*/*'})), path);
    return r.bodyBytes;
  }

  Future<Map<String, dynamic>> postJson(String path, Map<String, dynamic> body) async {
    final r = await _send(
      () => _http.post(_uri(path), headers: _headers({'Content-Type': 'application/json'}), body: jsonEncode(body)),
      path,
    );
    return (_json(r) as Map).cast<String, dynamic>();
  }

  Future<Map<String, dynamic>> patchJson(String path, Map<String, dynamic> body) async {
    final r = await _send(
      () => _http.patch(_uri(path), headers: _headers({'Content-Type': 'application/json'}), body: jsonEncode(body)),
      path,
    );
    return (_json(r) as Map).cast<String, dynamic>();
  }

  /// application/x-www-form-urlencoded, para los endpoints que usan Form(...).
  Future<Map<String, dynamic>> postForm(String path, Map<String, String> fields) async {
    final r = await _send(() => _http.post(_uri(path), headers: _headers(), body: fields), path);
    return (_json(r) as Map).cast<String, dynamic>();
  }

  /// Envía una foto de la cámara del celular (multipart, como la ESP32-CAM).
  Future<void> postFrame(Uint8List jpeg, String? sessionId) async {
    const path = '/api/camara/dispositivo';
    await _send(() async {
      final request = http.MultipartRequest('POST', _uri(path))
        ..headers.addAll(_headers())
        ..files.add(http.MultipartFile.fromBytes('file', jpeg, filename: 'frame.jpg'));
      if (sessionId != null) request.fields['session_id'] = sessionId;
      return http.Response.fromStream(await _http.send(request));
    }, path);
  }
}
