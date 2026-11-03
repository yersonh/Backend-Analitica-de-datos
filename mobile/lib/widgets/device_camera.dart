// Elegir la cámara que alimenta la sesión: la ESP32-CAM o la del celular.
//
// Con la del celular toma una foto, la envía a POST /api/camara/dispositivo y
// solo entonces toma la siguiente: nunca se acumulan envíos si la red va lenta.
// Android no deja usar la cámara con la app minimizada, así que se pausa en
// segundo plano; a los 5 s sin fotos el servidor vuelve solo a la ESP32-CAM.

import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../api.dart';
import '../app_state.dart';
import '../theme.dart';
import 'common.dart';

class CameraSourceCard extends StatefulWidget {
  const CameraSourceCard({super.key, required this.app, this.esp32View, this.allowDevice = true});
  final AppState app;

  /// La cámara del celular solo alimenta la sesión propia del usuario.
  final bool allowDevice;

  /// Lo que se muestra mientras la fuente sea la ESP32-CAM.
  final Widget? esp32View;

  @override
  State<CameraSourceCard> createState() => _CameraSourceCardState();
}

class _CameraSourceCardState extends State<CameraSourceCard> with WidgetsBindingObserver {
  static const _minInterval = Duration(milliseconds: 200);

  bool _device = false;
  bool _starting = false;
  bool _running = false;
  String? _error;
  CameraController? _camera;
  Future<void>? _loop;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_device) return;
    if (state == AppLifecycleState.resumed) {
      _start();
    } else if (state == AppLifecycleState.paused) {
      _stop();
    }
  }

  Future<void> _select(bool device) async {
    setState(() {
      _device = device;
      _error = null;
    });
    if (device) {
      await _start();
    } else {
      await _stop();
    }
  }

  Future<void> _start() async {
    if (_camera != null || _starting) return;
    setState(() => _starting = true);
    CameraController? camera;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw CameraException('sin_camara', 'Este celular no tiene cámara disponible');
      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      camera = CameraController(
        front,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await camera.initialize();
      await camera.lockCaptureOrientation(DeviceOrientation.portraitUp);
      await camera.setFlashMode(FlashMode.off);
      if (!mounted || !_device) {
        await camera.dispose();
        return;
      }
      // sin esto la pantalla se apaga y la captura se detiene
      unawaited(WakelockPlus.enable());
      _camera = camera;
      _running = true;
      _loop = _sendLoop(camera);
    } on CameraException catch (e) {
      await camera?.dispose();
      if (mounted) {
        setState(() {
          _device = false;
          _error = e.code.contains('AccessDenied') || e.code.contains('Permission')
              ? 'Sin permiso de cámara. Actívalo en los ajustes del celular. Sigues con la ESP32-CAM.'
              : 'No se pudo abrir la cámara. Sigues con la ESP32-CAM.';
        });
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _sendLoop(CameraController camera) async {
    while (_running) {
      final started = DateTime.now();
      try {
        final shot = await camera.takePicture();
        final bytes = await shot.readAsBytes();
        unawaited(File(shot.path).delete().then((_) {}, onError: (_) {}));
        if (_running) await widget.app.api.postFrame(bytes, widget.app.sessionId);
        if (_error != null && mounted) setState(() => _error = null);
      } on ApiException catch (e) {
        if (mounted) setState(() => _error = e.status == 0 ? 'Sin conexión: reintentando…' : e.message);
      } on CameraException {
        if (mounted) setState(() => _error = 'La cámara no respondió: reintentando…');
      }
      final left = _minInterval - DateTime.now().difference(started);
      await Future.delayed(left.isNegative ? Duration.zero : left);
    }
  }

  Future<void> _stop() async {
    _running = false;
    final camera = _camera;
    _camera = null;
    await _loop; // que termine la foto en curso antes de cerrar la cámara
    _loop = null;
    await camera?.dispose();
    unawaited(WakelockPlus.disable());
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stop();
    super.dispose();
  }

  Widget _preview() {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: AspectRatio(aspectRatio: 1 / camera.value.aspectRatio, child: CameraPreview(camera)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      title: 'Cámara',
      icon: Icons.videocam_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.allowDevice)
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, icon: Icon(Icons.memory), label: Text('ESP32-CAM')),
                ButtonSegment(value: true, icon: Icon(Icons.smartphone), label: Text('Este celular')),
              ],
              selected: {_device},
              onSelectionChanged: _starting ? null : (s) => _select(s.first),
            ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: C.rojo, fontSize: 12.5)),
          ],
          if (_device) ...[
            const SizedBox(height: 10),
            _preview(),
            const SizedBox(height: 10),
            const Note(
              'Mantén la app abierta: Android no deja usar la cámara en segundo plano. '
              'Si dejas de enviar, el sistema vuelve solo a la ESP32-CAM.',
            ),
          ] else if (widget.esp32View != null) ...[
            const SizedBox(height: 10),
            widget.esp32View!,
          ],
        ],
      ),
    );
  }
}
