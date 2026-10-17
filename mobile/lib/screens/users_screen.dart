// Gestión de usuarios y roles (permiso "usuarios": solo administrador).
// Usa la misma API JSON que /usuarios del panel web.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../app_state.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/common.dart';

class UsersScreen extends StatefulWidget {
  /// [embedded]: dentro de una pestaña del panel (sin barra superior propia).
  const UsersScreen({super.key, this.embedded = false});
  final bool embedded;

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  List<Map<String, dynamic>> _users = [];
  List<String> _sessions = [];
  String _roleFilter = 'all';
  String _q = '';
  String? _error;
  bool _loading = true;

  AppState get _app => AppScope.read(context);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await _app.api.getJson('/api/usuarios');
      _users = ((r['usuarios'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
      _error = null;
    } on ApiException catch (e) {
      _error = e.message;
    }
    try {
      final s = await _app.api.getJson('/sesiones');
      _sessions = [for (final x in (s['sesiones'] as List? ?? const [])) (x as Map)['session_id'] as String];
    } on ApiException {
      // solo son sugerencias
    }
    if (mounted) setState(() => _loading = false);
  }

  static String _initials(Map<String, dynamic> u) {
    final src = (u['full_name'] as String?) ?? (u['username'] as String);
    return src.split(RegExp(r'[\s._-]+')).where((w) => w.isNotEmpty).take(2).map((w) => w[0].toUpperCase()).join();
  }

  String _lastLogin(dynamic ts) =>
      ts == null ? 'Nunca' : relTime(ts).replaceFirst(RegExp(r'^hace \d+ s$'), 'hace un momento');

  @override
  Widget build(BuildContext context) {
    final me = _app.user?['id'];
    final list = _users.where((u) {
      if (_roleFilter != 'all' && u['role'] != _roleFilter) return false;
      if (_q.isEmpty) return true;
      return [
        u['username'],
        u['full_name'],
        u['session_id'],
      ].any((v) => (v ?? '').toString().toLowerCase().contains(_q));
    }).toList();
    int active(String r) => _users.where((u) => u['role'] == r && u['active'] == true).length;

    return Scaffold(
      appBar: widget.embedded ? null : AppBar(title: const Text('Usuarios y roles')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEdit(null),
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Nuevo usuario'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 96),
                children: [
                  KpiGrid(
                    minWidth: 110,
                    children: [
                      KpiTile(label: 'Total', value: '${_users.length}'),
                      KpiTile(label: 'Administradores', value: '${active('administrador')}', color: C.violeta),
                      KpiTile(label: 'Supervisores', value: '${active('supervisor')}', color: C.cyan),
                      KpiTile(label: 'Conductores', value: '${active('conductor')}', color: C.verde),
                      KpiTile(
                        label: 'Inactivos',
                        value: '${_users.where((u) => u['active'] != true).length}',
                        color: C.gris,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Buscar por usuario, nombre o sesión',
                    ),
                    onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final f in const {
                        'all': 'Todos',
                        'administrador': 'Administrador',
                        'supervisor': 'Supervisor',
                        'conductor': 'Conductor',
                      }.entries)
                        ChoiceChip(
                          label: Text(f.value),
                          selected: _roleFilter == f.key,
                          onSelected: (_) => setState(() => _roleFilter = f.key),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (_error != null)
                    GlassCard(
                      child: Text(_error!, style: const TextStyle(color: C.rojo)),
                    ),
                  if (list.isEmpty)
                    EmptyState(
                      _users.isEmpty ? 'Aún no hay usuarios.' : 'Ningún usuario coincide con la búsqueda.',
                      icon: Icons.group_outlined,
                    ),
                  for (final u in list) _userTile(u, u['id'] == me),
                ],
              ),
            ),
    );
  }

  Widget _userTile(Map<String, dynamic> u, bool isMe) {
    final c = C.role(u['role'] as String?);
    final activo = u['active'] == true;
    return Opacity(
      opacity: activo ? 1 : 0.55,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: C.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: C.border),
        ),
        child: ListTile(
          onTap: () => _actions(u, isMe),
          leading: CircleAvatar(
            backgroundColor: c.withValues(alpha: 0.2),
            foregroundColor: c,
            child: Text(_initials(u), style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          title: Row(
            children: [
              Flexible(child: Text('${u['full_name'] ?? u['username']}', overflow: TextOverflow.ellipsis)),
              if (isMe) ...[const SizedBox(width: 6), const Pill('TÚ', color: C.cyan)],
            ],
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '@${u['username']} · ${u['session_id'] ?? 'Todas las sesiones'}',
                style: const TextStyle(color: C.muted, fontSize: 12),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  Pill('${u['role_label']}', color: c),
                  Pill(activo ? 'Activo' : 'Inactivo', color: activo ? C.verde : C.gris),
                  if (u['must_change_password'] == true) const Pill('clave temporal', color: C.ambar),
                  Text(
                    'Último acceso: ${_lastLogin(u['last_login'])}',
                    style: const TextStyle(color: C.muted, fontSize: 11),
                  ),
                ],
              ),
            ],
          ),
          trailing: const Icon(Icons.more_vert),
        ),
      ),
    );
  }

  void _actions(Map<String, dynamic> u, bool isMe) {
    final activo = u['active'] == true;
    showModalBottomSheet(
      context: context,
      backgroundColor: C.card,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Editar'),
              onTap: () {
                Navigator.pop(ctx);
                _openEdit(u);
              },
            ),
            ListTile(
              leading: const Icon(Icons.key_outlined),
              title: const Text('Restablecer contraseña'),
              onTap: () {
                Navigator.pop(ctx);
                _confirm(
                  'Restablecer contraseña',
                  'Se generará una contraseña temporal para @${u['username']} y se cerrarán sus sesiones abiertas.',
                  'Restablecer',
                  () async {
                    final r = await _app.api.postJson('/api/usuarios/${u['id']}/clave', {});
                    await _showSecret(u, r['password_temporal'] as String);
                    _load();
                  },
                );
              },
            ),
            if (!isMe)
              ListTile(
                leading: Icon(activo ? Icons.block : Icons.check_circle_outline, color: activo ? C.rojo : C.verde),
                title: Text(activo ? 'Desactivar' : 'Activar'),
                onTap: () {
                  Navigator.pop(ctx);
                  Future<void> run() async {
                    await _app.api.patchJson('/api/usuarios/${u['id']}', {'active': !activo});
                    if (mounted) {
                      showSnack(context, activo ? '@${u['username']} desactivado' : '@${u['username']} activado');
                    }
                    _load();
                  }

                  if (!activo) {
                    run().catchError((Object e) {
                      if (mounted) showSnack(context, '$e', ok: false);
                    });
                  } else {
                    _confirm(
                      'Desactivar usuario',
                      '@${u['username']} no podrá entrar y se cerrarán sus sesiones abiertas. Podrás reactivarlo después.',
                      'Desactivar',
                      run,
                    );
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirm(String title, String text, String ok, Future<void> Function() action) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: C.rojo),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ok),
          ),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await action();
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, ok: false);
    }
  }

  Future<void> _showSecret(Map<String, dynamic> u, String pw) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Contraseña temporal'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Para @${u['username']}${u['full_name'] != null ? ' (${u['full_name']})' : ''}',
              style: const TextStyle(color: C.muted),
            ),
            const SizedBox(height: 12),
            SelectableText(
              pw,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            const Note(
              'Compártela por un canal seguro. Se pedirá cambiarla en el primer acceso y no se volverá a mostrar.',
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy),
            label: const Text('Copiar'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: pw));
              if (ctx.mounted) showSnack(ctx, 'Copiada al portapapeles');
            },
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Listo')),
        ],
      ),
    );
  }

  Future<void> _openEdit(Map<String, dynamic>? u) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.card,
      builder: (ctx) =>
          _EditSheet(user: u, isMe: u != null && u['id'] == _app.user?['id'], sessions: _sessions, app: _app),
    );
    if (result == null || !mounted) return;
    showSnack(context, u == null ? 'Usuario @${result['usuario']['username']} creado' : 'Cambios guardados');
    if (result['password_temporal'] != null) {
      await _showSecret((result['usuario'] as Map).cast<String, dynamic>(), result['password_temporal'] as String);
    }
    _load();
  }
}

class _EditSheet extends StatefulWidget {
  const _EditSheet({required this.user, required this.isMe, required this.sessions, required this.app});
  final Map<String, dynamic>? user;
  final bool isMe;
  final List<String> sessions;
  final AppState app;

  @override
  State<_EditSheet> createState() => _EditSheetState();
}

class _EditSheetState extends State<_EditSheet> {
  late final _username = TextEditingController(text: widget.user?['username'] as String?);
  late final _name = TextEditingController(text: widget.user?['full_name'] as String?);
  late final _session = TextEditingController(text: widget.user?['session_id'] as String?);
  final _password = TextEditingController();
  TextEditingController? _sessionField; // el del Autocomplete (con sugerencias de /sesiones)
  late String _role = (widget.user?['role'] as String?) ?? 'conductor';
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _name.dispose();
    _session.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final body = <String, dynamic>{
      'full_name': _name.text.trim(),
      'role': _role,
      'session_id': (_sessionField?.text ?? _session.text).trim(),
    };
    try {
      Map<String, dynamic> r;
      if (widget.user != null) {
        r = await widget.app.api.patchJson('/api/usuarios/${widget.user!['id']}', body);
      } else {
        body['username'] = _username.text.trim().toLowerCase();
        body['password'] = _password.text.isEmpty ? null : _password.text;
        r = await widget.app.api.postJson('/api/usuarios', body);
      }
      if (mounted) Navigator.pop(context, r);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.user != null;
    final roles = widget.app.roles;
    final desc = (roles[_role] as Map?)?['descripcion'] as String? ?? '';
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              editing ? 'Editar usuario' : 'Nuevo usuario',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Note(
              editing
                  ? '@${widget.user!['username']} · cambiar el rol o la sesión cierra sus sesiones abiertas.'
                  : 'Se le pedirá cambiar la contraseña en su primer acceso.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _username,
              enabled: !editing,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Usuario',
                helperText: '3-32 caracteres: minúsculas, números, . _ -',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Nombre completo (opcional)'),
            ),
            const SizedBox(height: 14),
            const Text('Rol', style: TextStyle(color: C.muted)),
            const SizedBox(height: 6),
            SegmentedButton<String>(
              segments: [
                for (final r in ['conductor', 'supervisor', 'administrador'])
                  ButtonSegment(
                    value: r,
                    label: Text((roles[r] as Map?)?['label'] as String? ?? r, style: const TextStyle(fontSize: 12)),
                    enabled: !(widget.isMe && r != widget.user!['role']),
                  ),
              ],
              selected: {_role},
              onSelectionChanged: (s) => setState(() => _role = s.first),
            ),
            const SizedBox(height: 6),
            Note(desc),
            const SizedBox(height: 14),
            Autocomplete<String>(
              initialValue: TextEditingValue(text: _session.text),
              optionsBuilder: (v) => widget.sessions.where((s) => s.toLowerCase().contains(v.text.toLowerCase())),
              fieldViewBuilder: (context, controller, focus, onSubmit) {
                _sessionField = controller;
                return TextField(
                  controller: controller,
                  focusNode: focus,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'Sesión ${_role == 'conductor' ? '(obligatoria)' : '(opcional)'}',
                    helperText: 'El SESSION_ID de sus ESP32',
                  ),
                );
              },
            ),
            if (!editing) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Contraseña inicial (opcional)',
                  helperText: 'Vacía = se genera una temporal. Mínimo ${widget.app.minPassword} caracteres.',
                ),
              ),
            ],
            if (_error != null) ...[const SizedBox(height: 12), Text(_error!, style: const TextStyle(color: C.rojo))],
            const SizedBox(height: 18),
            FilledButton(
              onPressed: _busy ? null : _save,
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
              child: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(editing ? 'Guardar cambios' : 'Crear usuario'),
            ),
          ],
        ),
      ),
    );
  }
}
