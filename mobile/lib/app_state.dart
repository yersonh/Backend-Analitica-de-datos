// Estado global de la app: servidor, usuario autenticado, permisos,
// configuración (umbrales) y sesión de monitoreo seleccionada.

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// Valores por defecto (los mismos de vision.py / pulse.py) por si /api/config falla.
const kDefaultThresholds = <String, dynamic>{
  'ear': 0.21,
  'mar': 0.6,
  'head_tilt_deg': 15.0,
  'relative_drop': 0.08,
  'low_variability_std': 1.5,
};

class AppState extends ChangeNotifier {
  final ApiClient api = ApiClient();
  final _secure = const FlutterSecureStorage();
  late SharedPreferences _prefs;

  bool ready = false;
  String baseUrl = '';
  Map<String, dynamic>? user;
  Map<String, dynamic>? config;
  bool mustChangePassword = false;
  String? sessionId;
  bool soundOn = false;

  /// Mensaje para la pantalla de login (sesión expirada, sin red al arrancar...).
  String? notice;

  bool get loggedIn => user != null;

  Set<String> get permisos => {...((user?['permisos'] as List?) ?? const []).cast<String>()};
  bool can(String permiso) => permisos.contains(permiso);

  Map<String, dynamic> get thresholds =>
      ((config?['thresholds'] as Map?)?.cast<String, dynamic>()) ?? kDefaultThresholds;
  double thr(String key) => (thresholds[key] as num? ?? kDefaultThresholds[key] as num).toDouble();

  int get minPassword => (config?['min_password'] as num?)?.toInt() ?? 8;

  Map<String, dynamic> get roles => ((config?['roles'] as Map?)?.cast<String, dynamic>()) ?? const {};

  String get displayName => (user?['full_name'] as String?) ?? (user?['username'] as String? ?? '');

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    baseUrl = _prefs.getString('base_url') ?? '';
    soundOn = _prefs.getBool('sound') ?? false;
    sessionId = _prefs.getString('session_id');
    api.baseUrl = baseUrl;
    api.onUnauthorized = _expire;

    final token = await _secure.read(key: 'token');
    if (token != null && baseUrl.isNotEmpty) {
      api.token = token;
      try {
        await _loadProfile();
      } on UnauthorizedException {
        await _clearAuth();
      } on ApiException catch (e) {
        user = null;
        notice = e.message;
      }
    }
    ready = true;
    notifyListeners();
  }

  static String normalizeUrl(String url) {
    var u = url.trim();
    if (u.isEmpty) return u;
    if (!u.startsWith('http://') && !u.startsWith('https://')) u = 'http://$u';
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  Future<void> login(String server, String username, String password) async {
    baseUrl = normalizeUrl(server);
    api.baseUrl = baseUrl;
    api.token = null;
    await _prefs.setString('base_url', baseUrl);

    final r = await api.postJson('/api/login', {'username': username, 'password': password});
    await _storeToken(r);
    sessionId = null; // cada login vuelve a elegir la sesión por defecto
    await _loadProfile();
    notice = null;
    notifyListeners();
  }

  Future<void> changePassword(String actual, String nueva, String confirmar) async {
    final r = await api.postJson('/api/cuenta/clave', {'actual': actual, 'nueva': nueva, 'confirmar': confirmar});
    await _storeToken(r);
    await _loadProfile();
    notifyListeners();
  }

  Future<void> logout() async {
    await _clearAuth();
    notifyListeners();
  }

  void selectSession(String id) {
    if (id == sessionId) return;
    sessionId = id;
    _prefs.setString('session_id', id);
    notifyListeners();
  }

  void toggleSound() {
    soundOn = !soundOn;
    _prefs.setBool('sound', soundOn);
    notifyListeners();
  }

  Future<void> _storeToken(Map<String, dynamic> r) async {
    api.token = r['token'] as String;
    await _secure.write(key: 'token', value: api.token);
    user = (r['user'] as Map).cast<String, dynamic>();
    mustChangePassword = r['must_change_password'] == true;
  }

  Future<void> _loadProfile() async {
    user = await api.getJson('/api/yo');
    mustChangePassword = user!['must_change_password'] == true;
    config = await api.getJson('/api/config');
    if (!mustChangePassword) await _resolveSession();
  }

  /// Igual que el panel web: un conductor ve siempre su sesión; un supervisor
  /// o administrador, la elegida o, si no hay, la que recibió lecturas más
  /// recientemente.
  Future<void> _resolveSession() async {
    if (!can('todas_sesiones')) {
      sessionId = user!['session_id'] as String?;
      return;
    }
    if (sessionId != null && sessionId != 'todas') return;
    try {
      final r = await api.getJson('/sesiones');
      final list = (r['sesiones'] as List?) ?? const [];
      sessionId = list.isNotEmpty ? (list.first as Map)['session_id'] as String : 'default';
    } catch (_) {
      sessionId = 'default';
    }
  }

  void _expire() {
    if (user == null) return;
    notice = 'Tu sesión expiró o fue cerrada. Inicia sesión de nuevo.';
    _clearAuth().then((_) => notifyListeners());
  }

  Future<void> _clearAuth() async {
    api.token = null;
    user = null;
    config = null;
    mustChangePassword = false;
    sessionId = null;
    await _prefs.remove('session_id');
    await _secure.delete(key: 'token');
  }
}

/// Da acceso al AppState desde cualquier widget y lo reconstruye al cambiar.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  static AppState read(BuildContext context) =>
      (context.getElementForInheritedWidgetOfExactType<AppScope>()!.widget as AppScope).notifier!;
}
