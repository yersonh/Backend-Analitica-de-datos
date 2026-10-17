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
  final _server = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false, _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final app = AppScope.read(context);
    _server.text = app.baseUrl;
    _error = app.notice;
  }

  @override
  void dispose() {
    _server.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppScope.read(context).login(_server.text, _user.text.trim().toLowerCase(), _pass.text);
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
              child: Form(
                key: _form,
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
                            TextFormField(
                              controller: _server,
                              keyboardType: TextInputType.url,
                              autocorrect: false,
                              decoration: const InputDecoration(
                                labelText: 'Servidor',
                                hintText: 'http://192.168.1.100:8000',
                                prefixIcon: Icon(Icons.dns_outlined),
                              ),
                              validator: (v) => (v ?? '').trim().isEmpty ? 'Escribe la dirección del backend' : null,
                            ),
                            const SizedBox(height: 14),
                            TextFormField(
                              controller: _user,
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
                                        child: CircularProgressIndicator(strokeWidth: 2.4, color: Color(0xFF031322)),
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
                    const SizedBox(height: 18),
                    const Text(
                      'Usa la IP del computador que corre uvicorn (--host 0.0.0.0) o la URL de Railway.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: C.muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
