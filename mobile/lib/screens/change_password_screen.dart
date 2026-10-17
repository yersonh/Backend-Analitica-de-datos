import 'package:flutter/material.dart';

import '../api.dart';
import '../app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Cambio de la contraseña propia. Obligatorio (sin botón atrás) cuando el
/// usuario tiene una contraseña temporal.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key, this.forced = false});
  final bool forced;

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _form = GlobalKey<FormState>();
  final _actual = TextEditingController();
  final _nueva = TextEditingController();
  final _confirmar = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _actual.dispose();
    _nueva.dispose();
    _confirmar.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final app = AppScope.read(context);
    try {
      await app.changePassword(_actual.text, _nueva.text, _confirmar.text);
      if (!mounted) return;
      if (!widget.forced) {
        Navigator.of(context).pop();
        showSnack(context, 'Contraseña actualizada. Se cerraron tus otras sesiones.');
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final min = app.minPassword;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cambiar contraseña'),
        automaticallyImplyLeading: !widget.forced,
        actions: [if (widget.forced) TextButton(onPressed: app.logout, child: const Text('Salir'))],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.forced)
                const GlassCard(
                  accent: C.ambar,
                  child: Text('Tu contraseña es temporal. Debes cambiarla antes de continuar.'),
                ),
              Text(
                'Hola, ${app.displayName}. La nueva contraseña debe tener al menos $min caracteres y combinar letras con números o símbolos.',
                style: const TextStyle(color: C.muted),
              ),
              const SizedBox(height: 18),
              TextFormField(
                controller: _actual,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Contraseña actual'),
                validator: (v) => (v ?? '').isEmpty ? 'Obligatoria' : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _nueva,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Nueva contraseña'),
                validator: (v) => (v ?? '').length < min ? 'Mínimo $min caracteres' : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _confirmar,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Confirmar nueva contraseña'),
                validator: (v) => v != _nueva.text ? 'No coincide' : null,
              ),
              if (_error != null) ...[const SizedBox(height: 14), Text(_error!, style: const TextStyle(color: C.rojo))],
              const SizedBox(height: 22),
              FilledButton(
                onPressed: _busy ? null : _submit,
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                child: _busy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Guardar'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
