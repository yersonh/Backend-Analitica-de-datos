import 'package:flutter/material.dart';

import '../api.dart';
import '../app_state.dart';
import '../theme.dart';
import '../widgets/brand.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _passFocus = FocusNode();
  bool _busy = false, _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final app = AppScope.read(context);
    // se propone el último usuario que entró en este teléfono
    if (app.recentUsers.isNotEmpty) _user.text = app.recentUsers.first;
    _error = app.notice;
  }

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    _passFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppScope.read(context).login(_user.text.trim().toLowerCase(), _pass.text);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              // AutofillGroup: el gestor de contraseñas del teléfono puede ofrecer guardarla
              child: Form(
                key: _form,
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(child: SidfamLogo(size: 96, intro: true, animate: true)),
                      const SizedBox(height: 18),
                      const FadeSlideIn(
                        delay: Duration(milliseconds: 500),
                        child: ShimmerText(
                          'SIDFAM',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: 10),
                        ),
                      ),
                      const SizedBox(height: 6),
                      const FadeSlideIn(
                        delay: Duration(milliseconds: 650),
                        child: Text(
                          'Cada parpadeo cuenta. Visión y ritmo cardíaco fusionados para cuidar a quien conduce.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: C.muted, height: 1.4),
                        ),
                      ),
                      const SizedBox(height: 30),
                      FadeSlideIn(
                        delay: const Duration(milliseconds: 800),
                        child: Container(
                          padding: const EdgeInsets.all(20),
                          decoration: glassDecoration(),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _RecentUsers(
                                onPick: (u) {
                                  setState(() => _user.text = u);
                                  _pass.clear();
                                  _passFocus.requestFocus();
                                },
                              ),
                              TextFormField(
                                controller: _user,
                                autofillHints: const [AutofillHints.username],
                                autocorrect: false,
                                textInputAction: TextInputAction.next,
                                decoration: const InputDecoration(
                                  labelText: 'Usuario',
                                  prefixIcon: Icon(Icons.person_outline),
                                ),
                                validator: (v) => (v ?? '').trim().isEmpty ? 'Escribe tu usuario' : null,
                              ),
                              const SizedBox(height: 14),
                              TextFormField(
                                controller: _pass,
                                focusNode: _passFocus,
                                autofillHints: const [AutofillHints.password],
                                obscureText: _obscure,
                                onFieldSubmitted: (_) => _submit(),
                                decoration: InputDecoration(
                                  labelText: 'Contraseña',
                                  prefixIcon: const Icon(Icons.lock_outline),
                                  suffixIcon: IconButton(
                                    icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                                    onPressed: () => setState(() => _obscure = !_obscure),
                                  ),
                                ),
                                validator: (v) => (v ?? '').isEmpty ? 'Escribe tu contraseña' : null,
                              ),
                              if (_error != null) ...[
                                const SizedBox(height: 14),
                                Text(_error!, style: const TextStyle(color: C.rojo)),
                              ],
                              const SizedBox(height: 22),
                              GradientButton(
                                onPressed: _busy ? null : _submit,
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 250),
                                  child: _busy
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                                        )
                                      : const Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text('Iniciar sesión'),
                                            SizedBox(width: 8),
                                            Icon(Icons.arrow_forward_rounded, size: 20),
                                          ],
                                        ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Usuarios que ya entraron en este teléfono: un toque los pone en el campo y
/// la "x" los olvida. Solo se guarda el nombre de usuario, nunca la contraseña.
class _RecentUsers extends StatelessWidget {
  const _RecentUsers({required this.onPick});
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    if (app.recentUsers.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Usuarios recientes', style: TextStyle(color: C.muted, fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final u in app.recentUsers)
                InputChip(
                  avatar: const Icon(Icons.person_outline, size: 16),
                  label: Text(u),
                  onPressed: () => onPick(u),
                  onDeleted: () => app.forgetUser(u),
                  deleteButtonTooltipMessage: 'Olvidar',
                  backgroundColor: C.cardHi,
                  side: const BorderSide(color: C.border),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
