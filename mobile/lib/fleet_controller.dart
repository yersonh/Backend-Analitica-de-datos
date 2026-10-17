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

  List<Map<String, dynamic>> drivers = [];
  Map<String, dynamic> summary = {};
  bool loaded = false;
  String? error;

  /// Se llama con (conductor, evento) por cada episodio nuevo detectado.
  void Function(List<(Map<String, dynamic>, Map<String, dynamic>)> nuevos)? onNewEvents;

  Timer? _timer;
  bool _busy = false;

  /// Último id de evento visto por sesión; null hasta la primera carga (no se avisa de lo viejo).
  Map<String, int>? _lastIds;

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

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
