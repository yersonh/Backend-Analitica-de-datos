// Contenedor principal: barra superior (sesión, estado de conexión, sonido,
// menú de usuario), navegación inferior según permisos y alertas de eventos
// nuevos (equivalen a los toasts + pitido del panel web).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../app_state.dart';
import '../fleet_controller.dart';
import '../live_controller.dart';
import '../notifications.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/brand.dart';
import 'analytics_screen.dart';
import 'change_password_screen.dart';
import 'fleet_screen.dart';
import 'history_screen.dart';
import 'kss_screen.dart';
import 'live_screen.dart';
import 'users_analytics_screen.dart';
import 'users_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
    value: 1,
  );
  late final AppState _app = AppScope.read(context);
  late final LiveController _live = LiveController(_app)..onNewEvents = _alert;

  /// Solo para quien ve todas las sesiones (supervisor, administrador).
  late final FleetController? _fleet = _app.can('todas_sesiones')
      ? (FleetController(_app)
          ..onNewEvents = _fleetAlert
          ..onWatch = _fleetWatch)
      : null;
  String? _session;
  int _tab = 0;
  bool _foreground = true;

  // Alerta de somnolencia: se dispara al PASAR a "alerta" (no en cada sondeo).
  String? _lastStatus;
  bool _alarmVisible = false;
  String _alarmTitle = '';
  String _alarmDetail = '';
  String _alarmAction = '';
  Timer? _buzz;

  // Vigilancia del conductor: un solo canal con indicios, aviso ámbar.
  bool _alarmWatch = false;
  DateTime? _lastWatch;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session = _app.sessionId;
    _app.addListener(_onApp);
    _live.addListener(_onLive);
    _live.start();
    _fleet?.start();
    // todos los roles: permiso de notificaciones y vigilancia en segundo plano
    Notifier.requestPermission().then(
      (_) => _fleet != null
          ? Notifier.startWatching()
          : Notifier.startWatching(
              title: 'SIDFAM · monitoreando tu sesión',
              text: 'Te avisará si detecta somnolencia',
            ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _app.removeListener(_onApp);
    _live.removeListener(_onLive);
    _live.dispose();
    _fleet?.dispose();
    _buzz?.cancel();
    Notifier.stopWatching(); // al cerrar sesión deja de vigilar
    _fade.dispose();
    super.dispose();
  }

  void _onLive() {
    final s = _live.status;
    // solo cuenta el estado en vivo (no lo "guardado" tras un reinicio del servidor)
    final now = s != null && s['data_is_fresh'] == true && s['saved'] != true ? s['status'] as String? : null;
    if (now == 'alerta' && _lastStatus != 'alerta') _drowsyAlert(s!);
    // al supervisor la vigilancia se la avisa la flota, de cualquier conductor
    if (now == 'vigilancia' && _fleet == null && _lastStatus != 'vigilancia' && _lastStatus != 'alerta') {
      _watchAlert(s!);
    }
    if (now != 'alerta' && _alarmVisible && !_alarmWatch) _dismissAlarm();
    _lastStatus = now;
  }

  String _watchDetail(dynamic detail) =>
      (detail as String?)?.isNotEmpty == true ? detail as String : 'Un solo canal muestra indicios de fatiga';

  /// Conductor al entrar en vigilancia: notificación del sistema y aviso ámbar.
  void _watchAlert(Map<String, dynamic> s) {
    final ahora = DateTime.now();
    if (_lastWatch != null && ahora.difference(_lastWatch!) < FleetController.watchCooldown) return;
    _lastWatch = ahora;
    const title = 'Posible somnolencia · En vigilancia';
    final detail = _watchDetail(s['detail']);
    const action = 'Si sientes sueño, detente en un lugar seguro.';
    Notifier.show(title, '$detail. $action');
    if (!mounted) return;
    setState(() {
      _alarmVisible = true;
      _alarmWatch = true;
      _alarmTitle = title;
      _alarmDetail = detail;
      _alarmAction = action;
    });
    HapticFeedback.heavyImpact();
    _buzz?.cancel();
    // no exige tocar la pantalla mientras conduce: se oculta solo
    _buzz = Timer(const Duration(seconds: 20), _dismissAlarm);
  }

  /// Supervisor: un conductor entró en vigilancia, aunque no sea el que está mirando.
  void _fleetWatch(List<Map<String, dynamic>> drivers) {
    for (final d in drivers) {
      final quien = d['conductor'] ?? d['session_id'];
      Notifier.show('$quien · En vigilancia', '${_watchDetail(d['detail'])}. Aún sin confirmar: revisa al conductor.');
    }
    if (!_foreground) return;
    _alert([
      for (final d in drivers)
        {'risk_level': 'vigilancia', 'detail': _watchDetail(d['detail']), '_quien': d['conductor'] ?? d['session_id']},
    ]);
  }

  void _drowsyAlert(Map<String, dynamic> s) {
    final alto = s['risk_level'] == 'alto';
    final quien = _fleet?.driverFor(_app.sessionId)?['conductor'];
    final title = '${quien != null ? '$quien · ' : ''}¡Somnolencia detectada!${alto ? ' · Riesgo alto' : ''}';
    final detail = (s['detail'] as String?)?.isNotEmpty == true
        ? s['detail'] as String
        : 'Señal visual y de pulso al mismo tiempo';
    // quien supervisa no va manejando: su acción es comunicarse con el conductor
    final action = _fleet != null ? 'Comunícate con el conductor.' : 'Detente en un lugar seguro y descansa.';
    // notificación del sistema: suena y vibra también con la app minimizada o la pantalla bloqueada
    Notifier.show(title, '$detail. $action');
    if (!mounted) return;
    setState(() {
      _alarmVisible = true;
      _alarmWatch = false;
      _alarmTitle = title;
      _alarmDetail = detail;
      _alarmAction = action;
    });
    HapticFeedback.heavyImpact();
    _buzz?.cancel();
    _buzz = Timer.periodic(const Duration(seconds: 2), (_) => HapticFeedback.heavyImpact());
  }

  void _dismissAlarm() {
    _buzz?.cancel();
    _buzz = null;
    if (mounted) setState(() => _alarmVisible = false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // sin sondeo en segundo plano; al volver se reanuda de inmediato
    _foreground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      _live.start();
      _fleet?.start();
    } else if (state == AppLifecycleState.paused) {
      if (_fleet != null) {
        _live.stop();
        // la flota sigue (más despacio) para que el supervisor reciba notificaciones
        _fleet.start(background: true);
      } else {
        // el conductor sigue vigilado (más despacio) para avisarle de somnolencia
        _live.start(background: true);
      }
    }
  }

  void _onApp() {
    if (_app.sessionId != _session) {
      _session = _app.sessionId;
      _lastStatus = null;
      _dismissAlarm();
      _live.reset();
    }
  }

  void _alert(List<Map<String, dynamic>> nuevos) {
    if (!mounted) return;
    // conductor con la app minimizada: la somnolencia ya la avisa _drowsyAlert;
    // aquí solo faltan las advertencias de sensor
    if (!_foreground && _fleet == null) {
      for (final e in nuevos.where((e) => e['risk_level'] == 'advertencia_sensor')) {
        Notifier.show('Revisa el sensor de pulso', '${e['detail'] ?? ''}');
      }
    }
    final messenger = ScaffoldMessenger.of(context);
    for (final e in nuevos) {
      final r = riskStyle(e['risk_level'] as String?);
      final what = switch (e['risk_level']) {
        'advertencia_sensor' => 'Advertencia de sensor',
        'vigilancia' => 'En vigilancia',
        _ => 'Nuevo episodio · ${r.label}',
      };
      final title = e['_quien'] != null ? '${e['_quien']} · $what' : what;
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          backgroundColor: C.cardHi,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: r.color),
          ),
          content: Row(
            children: [
              Icon(r.icon, color: r.color),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(color: r.color, fontWeight: FontWeight.w700),
                    ),
                    Text('${e['detail'] ?? ''}', style: const TextStyle(color: C.text)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (_app.soundOn && nuevos.isNotEmpty) {
      final alto = nuevos.any((e) => e['risk_level'] == 'alto');
      SystemSound.play(SystemSoundType.alert);
      HapticFeedback.heavyImpact();
      if (alto) {
        Future.delayed(const Duration(milliseconds: 350), () {
          SystemSound.play(SystemSoundType.alert);
          HapticFeedback.heavyImpact();
        });
      }
    }
  }

  /// Episodios de otros conductores (el que se está mirando ya lo avisa el panel).
  void _fleetAlert(List<(Map<String, dynamic>, Map<String, dynamic>)> nuevos) {
    // fuera de la app: notificación del sistema por cada episodio (de cualquier conductor)
    if (!_foreground) {
      for (final (d, e) in nuevos) {
        final r = riskStyle(e['risk_level'] as String?);
        final quien = d['conductor'] ?? d['session_id'];
        final what = e['risk_level'] == 'advertencia_sensor' ? 'Advertencia de sensor' : 'Fatiga · ${r.label}';
        Notifier.show('$quien · $what', '${e['detail'] ?? ''}');
      }
      return;
    }
    final otros = [
      for (final (d, e) in nuevos)
        if (d['session_id'] != _app.sessionId) {...e, '_quien': d['conductor'] ?? d['session_id']},
    ];
    if (otros.isNotEmpty) _alert(otros);
  }

  /// Desde la flota: abre el panel en vivo de ese conductor.
  void _openDriver(String sessionId) {
    _app.selectSession(sessionId);
    setState(() => _tab = 1); // Flota es la 0, Panel la 1
    _fade.forward(from: 0);
  }

  Future<void> _pickSession() async {
    List<Map<String, dynamic>> list = [];
    try {
      final r = await _app.api.getJson('/sesiones');
      list = ((r['sesiones'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    if (!mounted) return;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: C.card,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('Sesión de monitoreo', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            if (list.isEmpty) const ListTile(title: Text('Aún no hay sesiones con lecturas')),
            for (final s in list)
              ListTile(
                leading: Icon(
                  s['session_id'] == _app.sessionId ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: C.cyan,
                ),
                title: Text('${s['session_id']}'),
                subtitle: Text('${s['lecturas']} lecturas · última ${relTime(s['hasta'])}'),
                onTap: () => Navigator.pop(ctx, s['session_id'] as String),
              ),
          ],
        ),
      ),
    );
    if (chosen != null) _app.selectSession(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final tabs = <(String, IconData, Widget)>[
      if (_fleet != null) ('Flota', Icons.groups_2_outlined, FleetScreen(fleet: _fleet, onOpen: _openDriver)),
      ('Panel', Icons.speed, LiveScreen(live: _live)),
      ('Historial', Icons.history, HistoryScreen(live: _live)),
      // Quien ve todas las sesiones: panel de todos los usuarios + detalle.
      // El conductor (analitica_propia): la analítica de sus propios datos.
      if (app.can('analitica') && app.can('todas_sesiones'))
        ('Analítica', Icons.insights, const AnalyticsHub())
      else if (app.can('analitica') || app.can('analitica_propia'))
        ('Mi analítica', Icons.insights, const AnalyticsScreen()),
      if (app.can('autoreporte')) ('KSS', Icons.bedtime_outlined, const KssScreen()),
    ];
    if (_tab >= tabs.length) _tab = 0;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 14,
        title: Row(
          children: [
            const SidfamLogo(size: 36),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const ShimmerText(
                    'SIDFAM',
                    animate: false,
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, letterSpacing: 2),
                  ),
                  InkWell(
                    onTap: app.can('todas_sesiones') ? _pickSession : null,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // con la flota se muestra el nombre del conductor que se está mirando
                        Flexible(
                          child: ListenableBuilder(
                            listenable: _fleet ?? _live,
                            builder: (context, _) {
                              final who = _fleet?.driverFor(app.sessionId)?['conductor'];
                              return Text(
                                who != null ? '$who · ${app.sessionId}' : 'Sesión ${app.sessionId ?? '—'}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: C.muted, fontSize: 12),
                              );
                            },
                          ),
                        ),
                        if (app.can('todas_sesiones')) const Icon(Icons.arrow_drop_down, size: 18, color: C.muted),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          ListenableBuilder(
            listenable: _live,
            builder: (context, _) => _LiveChip(live: _live),
          ),
          IconButton(
            tooltip: app.soundOn ? 'Sonido on' : 'Sonido off',
            icon: Icon(app.soundOn ? Icons.volume_up : Icons.volume_off_outlined),
            onPressed: () {
              app.toggleSound();
              if (app.soundOn) SystemSound.play(SystemSoundType.alert);
            },
          ),
          _UserMenu(app: app),
        ],
      ),
      // Solo se dibuja la pestaña activa (las demás conservan su estado pero no
      // animan: TickerMode). Al cambiar, la nueva entra con un fundido corto.
      body: Stack(
        children: [
          FadeTransition(
            opacity: CurvedAnimation(parent: _fade, curve: Curves.easeOut),
            child: IndexedStack(
              index: _tab,
              children: [for (var i = 0; i < tabs.length; i++) TickerMode(enabled: i == _tab, child: tabs[i].$3)],
            ),
          ),
          // aviso de somnolencia encima de cualquier pestaña
          Align(
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              transitionBuilder: (child, a) => SizeTransition(sizeFactor: a, child: child),
              child: _alarmVisible
                  ? _DrowsyBanner(
                      title: _alarmTitle,
                      detail: _alarmDetail,
                      action: _alarmAction,
                      watch: _alarmWatch,
                      onAck: _dismissAlarm,
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) {
          if (i == _tab) return;
          setState(() => _tab = i);
          _fade.forward(from: 0);
        },
        destinations: [for (final t in tabs) NavigationDestination(icon: Icon(t.$2), label: t.$1)],
      ),
    );
  }
}

/// Aviso grande de somnolencia, rojo o ámbar si es vigilancia [watch] (el sonido
/// lo da la notificación del sistema).
class _DrowsyBanner extends StatelessWidget {
  const _DrowsyBanner({
    required this.title,
    required this.detail,
    required this.action,
    required this.watch,
    required this.onAck,
  });
  final String title;
  final String detail;
  final String action;
  final bool watch;
  final VoidCallback onAck;

  @override
  Widget build(BuildContext context) {
    final color = watch ? C.ambar : C.rojo;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [color, watch ? const Color(0xFFB87A14) : const Color(0xFFC2456A)]),
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.45),
              blurRadius: 24,
              offset: const Offset(0, 10),
              spreadRadius: -6,
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 30),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(detail, style: TextStyle(color: Colors.white.withValues(alpha: 0.92))),
            const SizedBox(height: 4),
            Text(
              action,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: onAck,
                style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: color),
                child: const Text('Entendido'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveChip extends StatelessWidget {
  const _LiveChip({required this.live});
  final LiveController live;

  @override
  Widget build(BuildContext context) {
    final s = live.status;
    final has = s?['has_any_data'] == true;
    final fresh = has && s?['data_is_fresh'] == true;
    final (text, color) = !live.connected
        ? ('Sin conexión', C.rojo)
        : s?['saved'] == true
        ? ('Guardado', C.azul)
        : !has
        ? ('Sin datos', C.gris)
        : fresh
        ? ('En vivo', C.verde)
        : ('Sin señal', C.ambar);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(99)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(text, style: TextStyle(color: color, fontSize: 11)),
        ],
      ),
    );
  }
}

class _UserMenu extends StatelessWidget {
  const _UserMenu({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final u = app.user ?? const {};
    final color = C.role(u['role'] as String?);
    final name = app.displayName;
    return PopupMenuButton<String>(
      tooltip: 'Cuenta',
      color: C.cardHi,
      offset: const Offset(0, 48),
      icon: CircleAvatar(
        radius: 15,
        backgroundColor: color.withValues(alpha: 0.2),
        foregroundColor: color,
        child: Text(
          name.length >= 2 ? name.substring(0, 2).toUpperCase() : name.toUpperCase(),
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
        ),
      ),
      onSelected: (v) {
        switch (v) {
          case 'users':
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => const UsersScreen()));
          case 'password':
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ChangePasswordScreen()));
          case 'logout':
            app.logout();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          enabled: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: const TextStyle(color: C.text, fontWeight: FontWeight.w700),
              ),
              Text('@${u['username']} · ${u['role_label']}', style: TextStyle(color: color, fontSize: 12)),
              const SizedBox(height: 4),
              Text(
                app.can('todas_sesiones')
                    ? 'Acceso a todas las sesiones'
                    : 'Acceso solo a tu sesión ${u['session_id'] ?? '—'}',
                style: const TextStyle(color: C.muted, fontSize: 11),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        // la gestión de usuarios va aquí: con la Flota, la barra inferior ya no tiene sitio
        if (app.can('usuarios'))
          const PopupMenuItem(
            value: 'users',
            child: ListTile(leading: Icon(Icons.manage_accounts_outlined), title: Text('Usuarios y roles')),
          ),
        const PopupMenuItem(
          value: 'password',
          child: ListTile(leading: Icon(Icons.lock_outline), title: Text('Cambiar contraseña')),
        ),
        const PopupMenuItem(
          value: 'logout',
          child: ListTile(
            leading: Icon(Icons.logout, color: C.rojo),
            title: Text('Cerrar sesión', style: TextStyle(color: C.rojo)),
          ),
        ),
      ],
    );
  }
}
