// Sondeo del estado en vivo y del historial, con los mismos intervalos que el
// panel web: /estado cada 1,5 s y /eventos cada 4 s.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'app_state.dart';
import 'util.dart';

class TrendPoint {
  const TrendPoint(this.t, this.v);
  final DateTime t;
  final double v;
}

class LiveController extends ChangeNotifier {
  LiveController(this.app);

  final AppState app;

  static const histMax = 120;
  static const statusEvery = Duration(milliseconds: 1500);
  static const eventsEvery = Duration(seconds: 4);

  Map<String, dynamic>? status;
  bool connected = false;
  String? error;

  List<Map<String, dynamic>> events = [];

  /// Minutos recientes sin alerta, ya resumidos por el servidor (máx. 20).
  List<Map<String, dynamic>> normales = [];
  Map<String, dynamic> counts = {};
  Set<int> freshIds = {};
  int? _maxId;

  final List<TrendPoint> earHist = [];
  final List<TrendPoint> bpmHist = [];

  /// Se llama con los eventos nuevos (más antiguo primero) para avisar al usuario.
  void Function(List<Map<String, dynamic>> nuevos)? onNewEvents;

  Timer? _statusTimer, _eventsTimer;
  bool _statusBusy = false, _eventsBusy = false;
  String? _session;

  String? get session => _session;

  /// [background]: con la app minimizada se consulta más despacio, lo justo
  /// para avisar de somnolencia sin gastar batería.
  void start({bool background = false}) {
    stop();
    _session = app.sessionId;
    _pollStatus();
    _pollEvents();
    _statusTimer = Timer.periodic(background ? const Duration(seconds: 4) : statusEvery, (_) => _pollStatus());
    _eventsTimer = Timer.periodic(background ? const Duration(seconds: 10) : eventsEvery, (_) => _pollEvents());
  }

  void stop() {
    _statusTimer?.cancel();
    _eventsTimer?.cancel();
    _statusTimer = _eventsTimer = null;
  }

  /// Cambió la sesión seleccionada: empieza de cero.
  void reset() {
    status = null;
    events = [];
    normales = [];
    counts = {};
    freshIds = {};
    _maxId = null;
    earHist.clear();
    bpmHist.clear();
    error = null;
    notifyListeners();
    start();
  }

  Map<String, String> get _query => {'session_id': ?_session};

  Future<void> _pollStatus() async {
    if (_statusBusy || !app.loggedIn) return;
    _statusBusy = true;
    final session = _session;
    try {
      // tras un reinicio del servidor se muestra lo último guardado hasta que llegue algo en vivo
      final s = withSaved(await app.api.getJson('/estado', _query))!;
      if (session != _session) return;
      status = s;
      connected = true;
      error = null;
      if (s['data_is_fresh'] == true) {
        _push(earHist, s['ear']);
        _push(bpmHist, s['bpm']);
      }
    } on ApiException catch (e) {
      connected = false;
      error = e.status == 0 ? null : e.message;
    } finally {
      _statusBusy = false;
      notifyListeners();
    }
  }

  Future<void> _pollEvents() async {
    if (_eventsBusy || !app.loggedIn) return;
    _eventsBusy = true;
    final session = _session;
    try {
      final data = await app.api.getJson('/eventos', _query);
      if (session != _session) return;
      final next = ((data['events'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
      counts = ((data['counts_by_risk'] as Map?) ?? const {}).cast<String, dynamic>();
      normales = ((data['normales'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();

      final fresh = <int>{};
      if (_maxId != null) {
        for (final e in next) {
          final id = e['id'] as int;
          if (id > _maxId!) fresh.add(id);
        }
      }
      for (final e in next) {
        final id = e['id'] as int;
        if (_maxId == null || id > _maxId!) _maxId = id;
      }
      _maxId ??= 0;
      events = next;
      freshIds = fresh;
      if (fresh.isNotEmpty) {
        final nuevos = next.reversed.where((e) => fresh.contains(e['id'])).toList();
        onNewEvents?.call(nuevos.length > 3 ? nuevos.sublist(nuevos.length - 3) : nuevos);
      }
    } on ApiException {
      // el estado ya refleja la falta de conexión
    } finally {
      _eventsBusy = false;
      notifyListeners();
    }
  }

  void _push(List<TrendPoint> list, dynamic v) {
    if (v is! num) return;
    list.add(TrendPoint(DateTime.now(), v.toDouble()));
    if (list.length > histMax) list.removeAt(0);
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
