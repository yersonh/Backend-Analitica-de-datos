// SIDFAM móvil: cliente Flutter del backend FastAPI.
//
// La detección (MediaPipe, pulso, fusión) y la base de datos siguen en el
// servidor; los ESP32 continúan enviando a /frame y /pulso. Esta app replica
// el panel web: login con roles, estado en vivo, historial, analítica KDD,
// autoreporte KSS y gestión de usuarios.

import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app_state.dart';
import 'screens/change_password_screen.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'theme.dart';
import 'widgets/brand.dart';

final _navigator = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('es');
  final state = AppState();
  runApp(AppScope(state: state, child: const SidfamApp()));
  await state.init();
}

class SidfamApp extends StatelessWidget {
  const SidfamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SIDFAM',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigator,
      theme: buildTheme(),
      // fondo aurora común a todas las pantallas (los Scaffold son transparentes)
      builder: (context, child) => Stack(children: [const AuroraBackground(), ?child]),
      home: const _Gate(),
    );
  }
}

/// Elige la pantalla según el estado de autenticación.
class _Gate extends StatelessWidget {
  const _Gate();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final (String key, Widget screen) = _screen(app);
    // fundido entre splash, login, cambio de clave y panel
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 550),
      switchInCurve: Curves.easeOutCubic,
      child: KeyedSubtree(key: ValueKey(key), child: screen),
    );
  }

  (String, Widget) _screen(AppState app) {
    if (!app.ready) {
      return ('splash', const Scaffold(body: Center(child: SidfamLogo(size: 120, intro: true))));
    }
    if (!app.loggedIn) {
      // si expiró la sesión con una pantalla abierta encima (usuarios, clave...), se cierra
      WidgetsBinding.instance.addPostFrameCallback((_) => _navigator.currentState?.popUntil((r) => r.isFirst));
      return ('login', const LoginScreen());
    }
    if (app.mustChangePassword) return ('clave', const ChangePasswordScreen(forced: true));
    // la clave cambia con el usuario: al reentrar se crea un panel nuevo
    final id = app.user!['id'];
    return ('home-$id', HomeScreen(key: ValueKey('home-$id')));
  }
}
