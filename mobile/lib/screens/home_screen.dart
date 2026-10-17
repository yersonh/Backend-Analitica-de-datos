// Contenedor principal: barra superior (sesión, estado de conexión, sonido,
// menú de usuario), navegación inferior según permisos y alertas de eventos
// nuevos (equivalen a los toasts + pitido del panel web).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../app_state.dart';
import '../live_controller.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/brand.dart';
import 'analytics_screen.dart';
import 'change_password_screen.dart';
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

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late final AppState _app = AppScope.read(context);
  late final LiveController _live = LiveController(_app)..onNewEvents = _alert;
  String? _session;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session = _app.sessionId;
    _app.addListener(_onApp);
    _live.start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _app.removeListener(_onApp);
    _live.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // sin sondeo en segundo plano; al volver se reanuda de inmediato
    if (state == AppLifecycleState.resumed) {
      _live.start();
    } else if (state == AppLifecycleState.paused) {
      _live.stop();
    }
  }

  void _onApp() {
    if (_app.sessionId != _session) {
      _session = _app.sessionId;
      _live.reset();
    }
  }

  void _alert(List<Map<String, dynamic>> nuevos) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    for (final e in nuevos) {
      final r = riskStyle(e['risk_level'] as String?);
      final title = e['risk_level'] == 'advertencia_sensor' ? 'Advertencia de sensor' : 'Nuevo episodio · ${r.label}';
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
      ('Panel', Icons.speed, LiveScreen(live: _live)),
      ('Historial', Icons.history, HistoryScreen(live: _live)),
      // Quien ve todas las sesiones: panel de todos los usuarios + detalle.
      // El conductor (analitica_propia): la analítica de sus propios datos.
      if (app.can('analitica') && app.can('todas_sesiones'))
        ('Analítica', Icons.insights, const AnalyticsHub())
      else if (app.can('analitica') || app.can('analitica_propia'))
        ('Mi analítica', Icons.insights, const AnalyticsScreen()),
      if (app.can('autoreporte')) ('KSS', Icons.bedtime_outlined, const KssScreen()),
      if (app.can('usuarios')) ('Usuarios', Icons.manage_accounts_outlined, const UsersScreen(embedded: true)),
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
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, letterSpacing: 2),
                  ),
                  InkWell(
                    onTap: app.can('todas_sesiones') ? _pickSession : null,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Sesión ${app.sessionId ?? '—'}', style: const TextStyle(color: C.muted, fontSize: 12)),
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
      // como un IndexedStack (cada pestaña conserva su estado) pero con fundido;
      // las pestañas ocultas no animan, así sus tarjetas entran al mostrarse
      body: Stack(
        children: [
          for (var i = 0; i < tabs.length; i++)
            Positioned.fill(
              child: IgnorePointer(
                ignoring: i != _tab,
                child: ExcludeSemantics(
                  excluding: i != _tab,
                  child: TickerMode(
                    enabled: i == _tab,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOut,
                      opacity: i == _tab ? 1 : 0,
                      child: AnimatedSlide(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeOutCubic,
                        offset: i == _tab ? Offset.zero : const Offset(0, 0.015),
                        child: tabs[i].$3,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [for (final t in tabs) NavigationDestination(icon: Icon(t.$2), label: t.$1)],
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
