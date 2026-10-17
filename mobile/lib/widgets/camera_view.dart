// Cámara en vivo: muestra el último frame de la ESP32-CAM con la vista del
// modelo ya dibujada por el servidor (GET /api/camara, ver app/overlay.py).
//
// Pide un frame, lo muestra y solo entonces pide el siguiente: nunca se
// acumulan peticiones aunque la red vaya lenta. Sin video baja el ritmo, y se
// detiene con la pestaña oculta o la app en segundo plano (batería).

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api.dart';
import '../app_state.dart';
import '../theme.dart';

class LiveCameraView extends StatefulWidget {
  const LiveCameraView({super.key, required this.sessionId});
  final String? sessionId;

  @override
  State<LiveCameraView> createState() => _LiveCameraViewState();
}

class _LiveCameraViewState extends State<LiveCameraView> with WidgetsBindingObserver {
  static const _withVideo = Duration(milliseconds: 300); // ~3 fps, el ritmo de la ESP32-CAM
  static const _noVideo = Duration(seconds: 3);

  Uint8List? _frame;
  DateTime? _lastFrameAt;
  bool _noSignal = false;
  Timer? _next;
  bool _visible = true, _foreground = true, _loading = false;
  int _generation = 0; // invalida respuestas viejas al cambiar de sesión

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible != _visible) {
      _visible = visible;
      _schedule(Duration.zero);
    } else if (_next == null && !_loading) {
      _schedule(Duration.zero);
    }
  }

  @override
  void didUpdateWidget(LiveCameraView old) {
    super.didUpdateWidget(old);
    if (old.sessionId != widget.sessionId) {
      _generation++;
      setState(() {
        _frame = null;
        _noSignal = false;
      });
      _schedule(Duration.zero);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _schedule(Duration.zero);
  }

  void _schedule(Duration delay) {
    _next?.cancel();
    _next = null;
    if (!_visible || !_foreground || !mounted) return;
    _next = Timer(delay, _fetch);
  }

  Future<void> _fetch() async {
    _next = null;
    if (_loading || !mounted) return;
    _loading = true;
    final gen = _generation;
    final app = AppScope.read(context);
    var delay = _noVideo;
    try {
      final bytes = await app.api.getBytes('/api/camara', {'session_id': ?widget.sessionId});
      if (!mounted || gen != _generation) return;
      if (bytes.isEmpty) {
        setState(() => _noSignal = true); // 204: la cámara no envía hace más de 10 s
      } else {
        // precarga para no mostrar un cuadro a medio decodificar
        await precacheImage(MemoryImage(bytes), context);
        if (!mounted || gen != _generation) return;
        setState(() {
          _frame = bytes;
          _lastFrameAt = DateTime.now();
          _noSignal = false;
        });
        delay = _withVideo;
      }
    } on ApiException {
      if (mounted && gen == _generation) setState(() => _noSignal = true);
    } finally {
      _loading = false;
      if (mounted) _schedule(delay);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _next?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final live = _frame != null && !_noSignal;
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: AspectRatio(
        aspectRatio: 4 / 3,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Color(0xFF050A16)),
            if (_frame != null)
              Opacity(
                opacity: live ? 1 : 0.35,
                child: Image.memory(_frame!, gaplessPlayback: true, fit: BoxFit.cover),
              ),
            if (!live)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.videocam_off_outlined, color: C.muted, size: 36),
                      const SizedBox(height: 8),
                      Text(
                        _frame == null ? 'Esperando video de la cámara…' : 'La cámara dejó de enviar',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: C.text, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Revisa que la ESP32-CAM esté encendida y conectada al WiFi.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: C.muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            Positioned(
              right: 8,
              bottom: 38,
              child: _Badge(live: live, at: _lastFrameAt),
            ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.live, required this.at});
  final bool live;
  final DateTime? at;

  @override
  Widget build(BuildContext context) {
    final color = live ? C.rojo : C.gris;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(99)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            live ? 'EN VIVO' : 'SIN SEÑAL',
            style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1),
          ),
        ],
      ),
    );
  }
}
