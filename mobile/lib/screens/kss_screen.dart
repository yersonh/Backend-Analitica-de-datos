// Autoreporte de somnolencia con la escala de Karolinska (KSS, 1-9).

import 'package:flutter/material.dart';

import '../api.dart';
import '../app_state.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/common.dart';

class KssScreen extends StatefulWidget {
  const KssScreen({super.key});

  @override
  State<KssScreen> createState() => _KssScreenState();
}

class _KssScreenState extends State<KssScreen> {
  int _kss = 3;
  final _note = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Color _color(int v) => v <= 3 ? C.verde : (v <= 6 ? C.ambar : C.rojo);

  Future<void> _submit() async {
    final app = AppScope.read(context);
    final session = app.sessionId;
    if (session == null || session == 'todas') {
      showSnack(context, 'Elige una sesión concreta para registrar el KSS', ok: false);
      return;
    }
    setState(() => _busy = true);
    try {
      await app.api.postForm('/autoreporte', {
        'session_id': session,
        'kss': '$_kss',
        if (_note.text.trim().isNotEmpty) 'note': _note.text.trim(),
      });
      _note.clear();
      if (mounted) showSnack(context, 'Registrado ✓  KSS $_kss en la sesión $session');
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, ok: false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
      children: [
        GlassCard(
          title: 'Autoreporte de somnolencia (KSS)',
          icon: Icons.bedtime_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Note(
                'Durante las pruebas, la persona monitoreada indica cada 5 minutos qué tan somnolienta se siente '
                'en la escala de Karolinska (1 = muy alerta, 9 = muy somnolienta, luchando contra el sueño). Estas '
                'respuestas son la etiqueta real con la que se evalúa el árbol de decisión.',
              ),
              const SizedBox(height: 8),
              Text('Sesión: ${app.sessionId ?? '—'}', style: const TextStyle(color: C.muted, fontSize: 12)),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  '$_kss',
                  style: TextStyle(fontSize: 64, fontWeight: FontWeight.w800, color: _color(_kss), height: 1),
                ),
              ),
              Center(
                child: Text(
                  kKss[_kss]!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _color(_kss)),
                ),
              ),
              Slider(
                value: _kss.toDouble(),
                min: 1,
                max: 9,
                divisions: 8,
                label: '$_kss',
                activeColor: _color(_kss),
                onChanged: (v) => setState(() => _kss = v.round()),
              ),
              const SizedBox(height: 4),
              for (final e in kKss.entries)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  selected: e.key == _kss,
                  selectedColor: _color(e.key),
                  leading: Icon(e.key == _kss ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 20),
                  onTap: () => setState(() => _kss = e.key),
                  title: Text('${e.key} · ${e.value}', style: const TextStyle(fontSize: 13)),
                ),
              const SizedBox(height: 8),
              TextField(
                controller: _note,
                decoration: const InputDecoration(labelText: 'Nota (opcional)'),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _busy ? null : _submit,
                icon: const Icon(Icons.send),
                label: const Text('Registrar'),
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
