// Verificación facial del conductor (POST /api/identidad/registro y /verificar).
//
// - mode 'registro': la primera vez. Pide el consentimiento (Ley 1581: datos
//   biométricos) y toma 3 fotos guiadas con la cámara frontal. El servidor solo
//   guarda vectores numéricos del rostro, nunca las fotos.
// - mode 'verificacion': al entrar. Una foto que se compara con el registro.
//
// No bloquea la app ("Ahora no"), pero mientras la sesión no esté verificada
// el servidor descarta los datos de la cámara y del pulso de esa sesión.

import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

class IdentityScreen extends StatefulWidget {
  const IdentityScreen({super.key, required this.mode, this.standalone = false});

  /// 'registro' o 'verificacion'.
  final String mode;

  /// Abierta desde el menú (rehacer el registro): se cierra con pop al terminar.
  final bool standalone;

  @override
  State<IdentityScreen> createState() => _IdentityScreenState();
}

class _IdentityScreenState extends State<IdentityScreen> {
  static const _poses = [
    'Mira de frente a la cámara',
    'Gira la cara un poco a tu izquierda',
    'Gira la cara un poco a tu derecha',
    'Inclina la cara un poco hacia abajo',
    'Vuelve a mirar de frente',
  ];

  CameraController? _camera;
  String? _cameraError;
  bool _consent = false;
  bool _busy = false;
  String? _error;
  final List<Uint8List> _shots = [];

  bool get _enroll => widget.mode == 'registro';

  @override
  void initState() {
    super.initState();
    _openCamera();
  }

  @override
  void dispose() {
    _camera?.dispose();
    super.dispose();
  }

  Future<void> _openCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw CameraException('sin_camara', 'Este celular no tiene cámara disponible');
      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      final camera = CameraController(
        front,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await camera.initialize();
      await camera.lockCaptureOrientation(DeviceOrientation.portraitUp);
      await camera.setFlashMode(FlashMode.off);
      if (!mounted) {
        await camera.dispose();
        return;
      }
      setState(() => _camera = camera);
    } on CameraException catch (e) {
      if (mounted) {
        setState(() {
          _cameraError = e.code.contains('AccessDenied') || e.code.contains('Permission')
              ? 'Sin permiso de cámara. Actívalo en los ajustes del celular.'
              : 'No se pudo abrir la cámara.';
        });
      }
    }
  }

  Future<Uint8List> _take() async {
    final shot = await _camera!.takePicture();
    final bytes = await shot.readAsBytes();
    File(shot.path).delete().then((_) {}, onError: (_) {});
    return bytes;
  }

  int _photosNeeded(AppState app) => (app.identity?['fotos_min'] as num?)?.toInt() ?? 3;

  Future<void> _capture(AppState app) async {
    if (_camera == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = await _take();
      if (!_enroll) {
        await _verify(app, bytes);
        return;
      }
      _shots.add(bytes);
      if (_shots.length >= _photosNeeded(app)) await _submitEnrollment(app);
    } on CameraException {
      setState(() => _error = 'La cámara no respondió. Intenta de nuevo.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitEnrollment(AppState app) async {
    try {
      final r = await app.api.postPhotos('/api/identidad/registro', 'files', _shots, {'consentimiento': 'true'});
      if (!mounted) return;
      showSnack(context, 'Rostro registrado. Tu sesión quedó verificada.');
      _finish(app, {'registrado': true, 'estado': r['estado']});
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _shots.clear(); // se repite el registro completo
          _error = e.message;
        });
      }
    }
  }

  Future<void> _verify(AppState app, Uint8List bytes) async {
    try {
      final r = await app.api.postPhotos('/api/identidad/verificar', 'file', [bytes]);
      if (!mounted) return;
      if (r['coincide'] == true) {
        showSnack(context, 'Identidad verificada');
        _finish(app, {'estado': r});
      } else {
        setState(() => _error = 'No coincide con el rostro registrado de esta cuenta. '
            'Si eres el conductor, intenta con buena luz y mirando de frente.');
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  void _finish(AppState app, Map<String, dynamic> info) {
    app.identityDone(info);
    if (widget.standalone && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  Widget _preview() {
    final camera = _camera;
    if (_cameraError != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(_cameraError!, style: const TextStyle(color: C.rojo), textAlign: TextAlign.center),
      );
    }
    if (camera == null || !camera.value.isInitialized) {
      return const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator()));
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: AspectRatio(
        aspectRatio: 1 / camera.value.aspectRatio,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CameraPreview(camera),
            // guía ovalada para centrar el rostro
            IgnorePointer(
              child: Center(
                child: FractionallySizedBox(
                  widthFactor: 0.62,
                  heightFactor: 0.6,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: const BorderRadius.all(Radius.elliptical(200, 260)),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.85), width: 3),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final needed = _photosNeeded(app);
    final consentText = (app.identity?['consentimiento'] as String?) ??
        'Autorizo el tratamiento de mis rasgos faciales para verificar que los datos de mi sesión son míos.';
    final canShoot = _camera != null && !_busy && (!_enroll || _consent);
    final pose = _poses[_shots.length.clamp(0, _poses.length - 1)];

    return Scaffold(
      appBar: AppBar(
        title: Text(_enroll ? 'Registra tu rostro' : 'Verifica tu identidad'),
        automaticallyImplyLeading: widget.standalone,
        actions: [if (!widget.standalone) TextButton(onPressed: app.logout, child: const Text('Salir'))],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _enroll
                  ? 'Hola, ${app.displayName}. Para que tus datos no se mezclen con los de otra persona, '
                        'SIDFAM comprueba que quien está frente a la cámara eres tú. Registra tu rostro una sola vez.'
                  : 'Hola, ${app.displayName}. Toma una foto para confirmar que eres el conductor de esta cuenta.',
              style: const TextStyle(color: C.muted),
            ),
            const SizedBox(height: 14),
            if (_enroll)
              GlassCard(
                accent: C.violeta,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Datos biométricos', style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Note(consentText),
                    CheckboxListTile(
                      value: _consent,
                      onChanged: _busy || _shots.isNotEmpty ? null : (v) => setState(() => _consent = v ?? false),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('Acepto', style: TextStyle(fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ),
            _preview(),
            const SizedBox(height: 12),
            if (_enroll)
              Text(
                _consent ? 'Foto ${_shots.length + 1} de $needed: $pose' : 'Acepta el tratamiento de datos para continuar.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: const TextStyle(color: C.rojo), textAlign: TextAlign.center),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: canShoot ? () => _capture(app) : null,
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(_enroll ? Icons.photo_camera_front_outlined : Icons.verified_user_outlined),
              label: Text(_enroll ? 'Tomar foto' : 'Verificar'),
            ),
            const SizedBox(height: 8),
            if (!widget.standalone)
              TextButton(
                onPressed: _busy ? null : app.postponeIdentity,
                child: const Text('Ahora no'),
              ),
            const SizedBox(height: 4),
            Note(
              _enroll
                  ? 'Mientras no registres tu rostro, tus datos se guardan sin verificar quién está frente a la cámara.'
                  : 'Si no verificas, la cámara del vehículo lo intentará sola. Mientras no reconozca tu rostro, '
                        'las lecturas de tu sesión no se guardan.',
            ),
          ],
        ),
      ),
    );
  }
}
