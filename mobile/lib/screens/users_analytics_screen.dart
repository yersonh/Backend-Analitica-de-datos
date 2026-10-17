// Analítica de todos los usuarios (administrador / supervisor): un resumen
// por persona para compararlas, y desde cada una su análisis CRISP-DM
// completo. Consume GET /analitica/usuarios.

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../app_state.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/common.dart';
import 'analytics_screen.dart';

const _nivelColor = {'alto': C.rojo, 'medio': C.ambar, 'bajo': C.verde, 'sin_datos': C.gris};
const _nivelLabel = {'alto': 'Riesgo alto', 'medio': 'Riesgo medio', 'bajo': 'Riesgo bajo', 'sin_datos': 'Sin datos'};

/// Pestaña "Analítica" de quien ve todas las sesiones: resumen por usuario o
/// detalle CRISP-DM de la sesión seleccionada.
class AnalyticsHub extends StatefulWidget {
  const AnalyticsHub({super.key});

  @override
  State<AnalyticsHub> createState() => _AnalyticsHubState();
}

class _AnalyticsHubState extends State<AnalyticsHub> {
  int _view = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, icon: Icon(Icons.groups_outlined), label: Text('Todos los usuarios')),
              ButtonSegment(value: 1, icon: Icon(Icons.insights), label: Text('Detalle CRISP-DM')),
            ],
            selected: {_view},
            onSelectionChanged: (s) => setState(() => _view = s.first),
          ),
        ),
        Expanded(
          child: IndexedStack(index: _view, children: const [UsersAnalyticsView(), AnalyticsScreen()]),
        ),
      ],
    );
  }
}

class UsersAnalyticsView extends StatefulWidget {
  const UsersAnalyticsView({super.key});

  @override
  State<UsersAnalyticsView> createState() => _UsersAnalyticsViewState();
}

class _UsersAnalyticsViewState extends State<UsersAnalyticsView> {
  Map<String, dynamic>? _data;
  String? _error;
  bool _loading = true;
  String _filter = 'todos';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await AppScope.read(context).api.getJson('/analitica/usuarios');
      if (mounted) {
        setState(() {
          _data = r;
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _open(String session, String title) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: AnalyticsScreen(session: session),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _data == null) return const Center(child: CircularProgressIndicator());
    if (_error != null && _data == null) {
      return ListView(
        children: [GlassCard(child: EmptyState(_error!, icon: Icons.error_outline))],
      );
    }
    final t = ((_data?['totales'] as Map?) ?? const {}).cast<String, dynamic>();
    final niveles = ((_data?['por_nivel'] as Map?) ?? const {}).cast<String, dynamic>();
    final usuarios = ((_data?['usuarios'] as List?) ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    final visibles = usuarios.where((u) => _filter == 'todos' || u['nivel_riesgo'] == _filter).toList();
    final conDatos = usuarios.where((u) => (u['lecturas'] as num? ?? 0) > 0).toList();

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
        children: [
          GlassCard(
            title: 'Analítica de todos los usuarios',
            icon: Icons.groups_outlined,
            trailing: IconButton(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Note(
                  'Indicadores de cada persona monitoreada para compararlas. Toca una persona para ver su '
                  'análisis CRISP-DM completo (calidad, modelos, regresión y evaluación).',
                ),
                const SizedBox(height: 12),
                KpiGrid(
                  minWidth: 110,
                  children: [
                    KpiTile(
                      label: 'Usuarios',
                      value: n(t['usuarios'], 0),
                      hint: '${n(t['conductores'], 0)} conductores',
                    ),
                    KpiTile(label: 'Sesiones con datos', value: n(t['sesiones'], 0), color: C.violeta),
                    KpiTile(label: 'Lecturas', value: n(t['lecturas'], 0), color: C.azul),
                    KpiTile(label: 'Horas monitoreadas', value: n(t['horas_monitoreo'], 1), color: C.verde),
                    KpiTile(label: 'Episodios de fatiga', value: n(t['episodios_fatiga'], 0), color: C.rojo),
                    KpiTile(label: 'Autoreportes KSS', value: n(t['kss_reportes'], 0), color: C.ambar),
                  ],
                ),
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  onPressed: () => _open('todas', 'Todas las sesiones'),
                  icon: const Icon(Icons.hub_outlined),
                  label: const Text('Analizar todas las sesiones juntas'),
                ),
              ],
            ),
          ),
          if (conDatos.isNotEmpty)
            GlassCard(
              title: 'Comparación: episodios de fatiga por hora',
              icon: Icons.bar_chart,
              child: _ComparisonChart(rows: conDatos),
            ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final k in ['todos', 'alto', 'medio', 'bajo', 'sin_datos'])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(
                        k == 'todos' ? 'Todos (${usuarios.length})' : '${_nivelLabel[k]} (${niveles[k] ?? 0})',
                      ),
                      selected: _filter == k,
                      onSelected: (_) => setState(() => _filter = k),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (visibles.isEmpty)
            EmptyState(
              usuarios.isEmpty
                  ? 'Aún no hay usuarios ni sesiones con datos. Crea conductores en la pestaña Usuarios.'
                  : 'Nadie en este nivel.',
            ),
          for (final u in visibles)
            _UserCard(
              u: u,
              onTap: (u['lecturas'] as num? ?? 0) > 0
                  ? () => _open('${u['session_id']}', '${u['nombre'] ?? u['session_id']}')
                  : null,
            ),
        ],
      ),
    );
  }
}

class _ComparisonChart extends StatelessWidget {
  const _ComparisonChart({required this.rows});
  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    final values = [for (final r in rows) asDouble(r['episodios_por_hora']) ?? 0];
    final maxV = values.fold<double>(0, (a, b) => b > a ? b : a);
    final labels = [for (final r in rows) '${r['nombre'] ?? r['session_id']}'];
    return Column(
      children: [
        SizedBox(
          height: 190,
          child: BarChart(
            BarChartData(
              maxY: maxV == 0 ? 1 : maxV * 1.2,
              gridData: FlGridData(
                drawVerticalLine: false,
                getDrawingHorizontalLine: (_) => const FlLine(color: C.border, strokeWidth: 1),
              ),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(),
                rightTitles: const AxisTitles(),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 32,
                    getTitlesWidget: (v, meta) => axisLabel(v, meta, n(v, 1)),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 26,
                    getTitlesWidget: (v, meta) {
                      final i = v.toInt();
                      if (i < 0 || i >= labels.length) return const SizedBox.shrink();
                      final l = labels[i];
                      return Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          l.length > 10 ? '${l.substring(0, 9)}…' : l,
                          style: const TextStyle(color: C.muted, fontSize: 10),
                        ),
                      );
                    },
                  ),
                ),
              ),
              barTouchData: BarTouchData(
                touchTooltipData: BarTouchTooltipData(
                  getTooltipColor: (_) => C.cardHi,
                  getTooltipItem: (group, _, rod, _) => BarTooltipItem(
                    '${labels[group.x]}\n${n(rod.toY, 2)} episodios/h',
                    const TextStyle(color: C.text, fontSize: 12),
                  ),
                ),
              ),
              barGroups: [
                for (var i = 0; i < rows.length; i++)
                  BarChartGroupData(
                    x: i,
                    barRods: [
                      BarChartRodData(
                        toY: values[i],
                        width: 18,
                        color: _nivelColor[rows[i]['nivel_riesgo']] ?? C.gris,
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        const Note('Episodios de fatiga (medio o alto) por hora de monitoreo. El color indica el nivel de riesgo.'),
      ],
    );
  }
}

class _UserCard extends StatelessWidget {
  const _UserCard({required this.u, this.onTap});
  final Map<String, dynamic> u;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final nivel = '${u['nivel_riesgo']}';
    final color = _nivelColor[nivel] ?? C.gris;
    final sinDatos = (u['lecturas'] as num? ?? 0) == 0;
    final nombre = '${u['nombre'] ?? u['session_id']}';

    Widget stat(String k, String v) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(k, style: const TextStyle(color: C.muted, fontSize: 10.5)),
        Text(v, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
      ],
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: C.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: C.role(u['rol'] as String?).withValues(alpha: 0.2),
                    foregroundColor: C.role(u['rol'] as String?),
                    child: Text(
                      nombre.isEmpty ? '?' : nombre.substring(0, 1).toUpperCase(),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(nombre, style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text(
                          [
                            if (u['usuario'] != null) '@${u['usuario']}' else 'sin usuario asignado',
                            'sesión ${u['session_id']}',
                          ].join(' · '),
                          style: const TextStyle(color: C.muted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  Pill(_nivelLabel[nivel] ?? nivel, color: color),
                  if (onTap != null) const Icon(Icons.chevron_right, color: C.muted),
                ],
              ),
              if (sinDatos)
                const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Note('Todavía no ha enviado lecturas. Sus ESP32 deben usar este session_id.'),
                )
              else ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 18,
                  runSpacing: 10,
                  children: [
                    stat('Episodios', '${u['episodios_alto']} alto · ${u['episodios_medio']} medio'),
                    stat('Por hora', n(u['episodios_por_hora'], 2)),
                    stat('% en alerta', '${n(u['pct_alerta'], 1)} %'),
                    stat('BPM medio', '${n(u['bpm_medio'], 0)} (basal ${n(u['basal_bpm'], 0)})'),
                    stat('PERCLOS', '${n(u['perclos'], 1)} %'),
                    stat('KSS', u['kss_reportes'] == 0 ? '—' : '${n(u['kss_medio'], 1)} (${u['kss_reportes']})'),
                    stat('Monitoreo', '${n(u['horas_monitoreo'], 2)} h · ${n(u['lecturas'], 0)} lecturas'),
                  ],
                ),
                const SizedBox(height: 6),
                Text('Última lectura ${relTime(u['hasta'])}', style: const TextStyle(color: C.muted, fontSize: 11)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
