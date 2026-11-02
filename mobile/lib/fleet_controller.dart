// Vista de flota para supervisores: sondea /api/flota (todos los conductores
// con su estado) y avisa de episodios nuevos de CUALQUIER conductor, no solo
// del que se está mirando en el panel.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'app_state.dart';

class FleetController extends ChangeNotifier {
  FleetController(this.app);

  final AppState app;

  static const every = Duration(seconds: 3);

  /// En segundo plano se sigue sondeando, más despacio, para notificar episodios.
  static const everyBackground = Duration(seconds: 8);

  /// La vigilancia puede ir y venir (un bostezo dura segundos): tiempo mínimo
  /// entre dos avisos de la misma sesión.
  static const watchCooldown = Duration(seconds: 60);

  List<Map<String, dynamic>> drivers = [];
  Map<String, dynamic> summary = {};
  bool loaded = false;
  String? error;

  /// Se llama con (conductor, evento) por cada episodio nuevo detectado.
  void Function(List<(Map<String, dynamic>, Map<String, dynamic>)> nuevos)? onNewEvents;

  /// Se llama con los conductores que acaban de entrar en vigilancia. La
  /// vigilancia no guarda eventos, por eso se detecta por el cambio de estado.
  void Function(List<Map<String, dynamic>> enVigilancia)? onWatch;

  Timer? _timer;
  bool _busy = false;

  /// Último id de evento visto por sesión; null hasta la primera carga (no se avisa de lo viejo).
  Map<String, int>? _lastIds;

  /// Último estado visto por sesión; null hasta la primera carga.
  Map<String, String>? _lastEstados;
  final _lastWatch = <String, DateTime>{};

  /// Datos del conductor de una sesión, si está en la flota.
  Map<String, dynamic>? driverFor(String? sessionId) {
    for (final d in drivers) {
      if (d['session_id'] == sessionId) return d;
    }
    return null;
  }

  void start({bool background = false}) {
    stop();
    refresh();
    _timer = Timer.periodic(background ? everyBackground : every, (_) => refresh());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> refresh() async {
    if (_busy || !app.loggedIn) return;
    _busy = true;
    try {
      final r = await app.api.getJson('/api/flota');
      drivers = ((r['conductores'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
      summary = ((r['resumen'] as Map?) ?? const {}).cast<String, dynamic>();
      error = null;
      _detectNew();
      detectWatch();
      loaded = true;
    } on ApiException catch (e) {
      error = e.status == 0 ? 'Sin conexión con el servidor' : e.message;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  void _detectNew() {
    final ids = <String, int>{};
    final nuevos = <(Map<String, dynamic>, Map<String, dynamic>)>[];
    for (final d in drivers) {
      final ev = d['ultimo_evento'];
      if (ev is! Map) continue;
      final sid = d['session_id'] as String;
      final id = (ev['id'] as num).toInt();
      ids[sid] = id;
      final prev = _lastIds?[sid];
      if (_lastIds != null && (prev == null || id > prev)) nuevos.add((d, ev.cast<String, dynamic>()));
    }
    _lastIds = ids;
    if (nuevos.isNotEmpty) onNewEvents?.call(nuevos);
  }

  /// Al PASAR a vigilancia desde un estado tranquilo. Si viene de una alerta ya
  /// se avisó: bajar a vigilancia no es un aviso nuevo.
  @visibleForTesting
  void detectWatch() {
    final prev = _lastEstados;
    _lastEstados = {for (final d in drivers) d['session_id'] as String: '${d['estado']}'};
    if (prev == null) return;
    final now = DateTime.now();
    final nuevos = <Map<String, dynamic>>[];
    for (final d in drivers) {
      final sid = d['session_id'] as String;
      final antes = prev[sid] ?? '';
      if (d['estado'] != 'vigilancia' || antes == 'vigilancia' || antes.startsWith('alerta')) continue;
      final ultimo = _lastWatch[sid];
      if (ultimo != null && now.difference(ultimo) < watchCooldown) continue;
      _lastWatch[sid] = now;
      nuevos.add(d);
    }
    if (nuevos.isNotEmpty) onWatch?.call(nuevos);
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
