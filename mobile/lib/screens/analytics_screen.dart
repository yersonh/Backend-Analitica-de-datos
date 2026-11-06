// Analítica de datos con la metodología CRISP-DM: fase 1 (negocio), fase 2
// (calidad), fase 3 (ventanas y descriptiva), fase 4 (K-Means, árbol de
// decisión, anomalías y regresión), fase 5 (evaluación) y fase 6 (despliegue). Consume GET /analitica/reporte igual que el panel web.

import 'dart:io';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../api.dart';
import '../app_state.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/common.dart';
import '../widgets/model_sections.dart';

const _statusColor = {'normal': C.verde, 'vigilancia': C.azul, 'alerta': C.rojo, 'advertencia_sensor': C.violeta};
const _clusterColors = [C.verde, C.ambar, C.rojo, C.azul, C.violeta, C.gris];

Color _clusterColor(String name, List<String> names) {
  if (name == 'Alerta') return C.verde;
  if (name == 'Somnolencia') return C.rojo;
  if (name.startsWith('Intermedio')) {
    return names.where((x) => x.startsWith('Intermedio')).length > 1
        ? _clusterColors[3 + names.indexOf(name) % 3]
        : C.ambar;
  }
  return C.gris;
}

Color? _heatColor(dynamic v) {
  final x = asDouble(v);
  if (x == null) return null;
  final a = x.abs().clamp(0.0, 1.0) * 0.75;
  return (x >= 0 ? C.azul : C.rojo).withValues(alpha: a);
}

Map<String, dynamic> _map(dynamic v) => ((v as Map?) ?? const {}).cast<String, dynamic>();
List<dynamic> _list(dynamic v) => (v as List?) ?? const [];

class AnalyticsScreen extends StatefulWidget {
  /// [session]: sesión a analizar (p. ej. al abrir un usuario desde el panel
  /// de todos los usuarios). Sin ella se usa la sesión seleccionada en la app.
  const AnalyticsScreen({super.key, this.session});
  final String? session;

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  String? _session;
  int _ventana = 60;
  List<Map<String, dynamic>> _sessions = [];
  Map<String, dynamic>? _report;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    final app = AppScope.read(context);
    _session = widget.session ?? app.sessionId ?? 'default';
    _ventana = (app.config?['ventana_defecto'] as num?)?.toInt() ?? 60;
    _loadSessions();
    _loadReport();
  }

  AppState get _app => AppScope.read(context);

  Future<void> _loadSessions() async {
    if (!_app.can('todas_sesiones')) return;
    try {
      final r = await _app.api.getJson('/sesiones');
      if (!mounted) return;
      setState(() => _sessions = _list(r['sesiones']).map((e) => _map(e)).toList());
    } on ApiException {
      // el selector queda solo con la sesión actual
    }
  }

  Future<void> _loadReport() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await _app.api.getJson('/analitica/reporte', {'session_id': _session!, 'ventana': '$_ventana'});
      if (mounted) setState(() => _report = r);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = 'No se pudo calcular la analítica: ${e.message}');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _exportCsv(bool dataset) async {
    final path = dataset ? '/analitica/dataset.csv' : '/lecturas.csv';
    final query = {'session_id': _session!, if (dataset) 'ventana': '$_ventana'};
    final name = dataset ? 'dataset_ventanas_${_session}_${_ventana}s.csv' : 'lecturas_$_session.csv';
    try {
      final bytes = await _app.api.getBytes(path, query);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(bytes);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/csv')],
          subject: name,
        ),
      );
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, ok: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final picker = app.can('todas_sesiones') && widget.session == null;
    final total = _sessions.fold<int>(0, (a, s) => a + ((s['lecturas'] as num?)?.toInt() ?? 0));
    final options = <(String, String)>[
      ('todas', 'Todas las sesiones ($total lecturas)'),
      if (_session != 'todas' && !_sessions.any((s) => s['session_id'] == _session))
        (_session!, '$_session (0 lecturas)'),
      for (final s in _sessions) (s['session_id'] as String, '${s['session_id']} (${s['lecturas']} lecturas)'),
    ];

    return RefreshIndicator(
      onRefresh: _loadReport,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
        children: [
          GlassCard(
            title: 'Analítica de datos',
            icon: Icons.insights,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Note(
                  _session == 'todas'
                      ? 'Lecturas guardadas de TODAS las sesiones.'
                      : 'Lecturas guardadas de la sesión $_session.',
                ),
                const SizedBox(height: 12),
                if (picker) ...[
                  DropdownButtonFormField<String>(
                    initialValue: _session,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Sesión'),
                    items: [
                      for (final o in options)
                        DropdownMenuItem(
                          value: o.$1,
                          child: Text(o.$2, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => _session = v);
                      if (v != 'todas') app.selectSession(v);
                      _loadReport();
                    },
                  ),
                  const SizedBox(height: 10),
                ],
                DropdownButtonFormField<int>(
                  initialValue: _ventana,
                  decoration: const InputDecoration(labelText: 'Ventana'),
                  items: const [
                    DropdownMenuItem(value: 60, child: Text('Ventana 1 min')),
                    DropdownMenuItem(value: 30, child: Text('Ventana 30 s')),
                    DropdownMenuItem(value: 10, child: Text('Ventana 10 s')),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _ventana = v);
                    _loadReport();
                  },
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _loading ? null : _loadReport,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Recalcular'),
                    ),
                    if (app.can('exportar')) ...[
                      OutlinedButton.icon(
                        onPressed: () => _exportCsv(false),
                        icon: const Icon(Icons.download),
                        label: const Text('Lecturas CSV'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _exportCsv(true),
                        icon: const Icon(Icons.download),
                        label: const Text('Dataset CSV'),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Column(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('Calculando analítica…', style: TextStyle(color: C.muted)),
                ],
              ),
            )
          else if (_error != null)
            GlassCard(child: EmptyState(_error!, icon: Icons.error_outline))
          else if (_report != null && _report!['disponible'] != true)
            GlassCard(
              child: EmptyState(
                '${_report!['mensaje']}\n\nDeja los ESP32 enviando datos unos minutos y presiona Recalcular.',
                icon: Icons.hourglass_empty,
              ),
            )
          else if (_report != null)
            ..._sectionsFor(_report!),
        ],
      ),
    );
  }

  List<Widget> _sectionsFor(Map<String, dynamic> r) {
    final params = _map(r['parametros']);
    final labels = _map(params['etiquetas_variables']).map((k, v) => MapEntry(k, '$v'));
    // Igual que el panel web: las 6 fases de CRISP-DM en orden, y cada modelo
    // aparece solo cuando ya hay datos suficientes para calcularlo.
    bool ok(String k) => _map(r[k])['disponible'] == true;
    const modelos = {
      'clustering': 'K-Means',
      'clasificacion': 'Árbol de decisión',
      'anomalias': 'Anomalías',
      'regresion': 'Regresión',
    };
    final pendientes = [
      for (final m in modelos.entries)
        if (!ok(m.key) && _map(r[m.key])['mensaje'] != null) (m.value, '${_map(r[m.key])['mensaje']}'),
    ];
    // Interpretación de cada fase (la genera el servidor: analytics.interpret)
    final interp = _map(r['interpretacion']);
    Widget i(String fase) => _InterpretationCard(lines: [for (final t in _list(interp[fase])) '$t']);
    return [
      _BusinessSection(criterios: _map(params['criterios_exito'])),
      i('fase1'),
      _QualitySection(q: _map(r['calidad_datos'])),
      i('fase2'),
      _DescriptiveSection(
        d: _map(r['descriptiva']),
        labels: labels,
        ventana: (params['ventana_s'] as num?)?.toInt() ?? _ventana,
        diccionario: _map(params['diccionario']),
      ),
      i('fase3'),
      if (ok('clustering')) ...[_ClusterSection(c: _map(r['clustering']), labels: labels), i('fase4a')],
      if (ok('clasificacion')) ...[_ClassifySection(k: _map(r['clasificacion'])), i('fase4b')],
      if (ok('anomalias')) ...[_AnomaliesSection(a: _map(r['anomalias']), labels: labels), i('fase4c')],
      if (ok('regresion')) ...[RegressionSection(g: _map(r['regresion'])), i('fase4d')],
      if (ok('evaluacion')) _EvaluationSection(ev: _map(r['evaluacion'])),
      _DeploymentSection(recomendaciones: [for (final t in _list(interp['fase6'])) '$t']),
      if (pendientes.isNotEmpty) _PendingSection(modelos: pendientes),
    ];
  }
}

// ---------------------------------------------------------------------------
// Gráficas genéricas
// ---------------------------------------------------------------------------

Widget _barChart({
  required List<String> labels,
  required List<double> values,
  required List<Color> colors,
  double height = 200,
  int labelEvery = 1,
}) {
  if (values.isEmpty) return const EmptyState('Sin datos', icon: Icons.bar_chart);
  final maxV = values.fold<double>(0, (a, b) => b > a ? b : a);
  return SizedBox(
    height: height,
    child: BarChart(
      BarChartData(
        maxY: maxV == 0 ? 1 : maxV * 1.15,
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
              reservedSize: 34,
              getTitlesWidget: (v, meta) => axisLabel(v, meta, n(v, 1)),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              getTitlesWidget: (v, meta) {
                final i = v.toInt();
                if (i < 0 || i >= labels.length || i % labelEvery != 0) return const SizedBox();
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(labels[i], style: const TextStyle(color: C.muted, fontSize: 9.5)),
                );
              },
            ),
          ),
        ),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => C.cardHi,
            getTooltipItem: (group, _, rod, _) =>
                BarTooltipItem('${labels[group.x]}\n${n(rod.toY)}', const TextStyle(color: C.text, fontSize: 12)),
          ),
        ),
        barGroups: [
          for (var i = 0; i < values.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: values[i],
                  color: colors[i % colors.length],
                  width: values.length > 16 ? 6 : 16,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                ),
              ],
            ),
        ],
      ),
    ),
  );
}

Widget _legend(List<(String, Color)> items) => Padding(
  padding: const EdgeInsets.only(top: 8),
  child: Wrap(
    spacing: 14,
    runSpacing: 6,
    children: [
      for (final (label, color) in items)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
            ),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(color: C.muted, fontSize: 12)),
          ],
        ),
    ],
  ),
);

Widget _lineChart(List<(String, Color, List<double?>)> series, {double? minY, double? maxY, List<String>? xLabels}) {
  final len = series.isEmpty ? 0 : series.first.$3.length;
  if (len < 2) return const EmptyState('Sin suficientes ventanas', icon: Icons.show_chart);
  final every = (len / 5).ceil().clamp(1, 1 << 30);
  return Column(
    children: [
      SizedBox(
        height: 200,
        child: LineChart(
          LineChartData(
            minY: minY,
            maxY: maxY,
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
                  reservedSize: 36,
                  getTitlesWidget: (v, meta) => axisLabel(v, meta, n(v, 0)),
                ),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: xLabels != null,
                  reservedSize: 24,
                  interval: 1,
                  getTitlesWidget: (v, meta) {
                    final i = v.toInt();
                    if (xLabels == null || v != i || i % every != 0 || i >= xLabels.length) return const SizedBox();
                    return Text(xLabels[i], style: const TextStyle(color: C.muted, fontSize: 9));
                  },
                ),
              ),
            ),
            lineTouchData: LineTouchData(
              touchTooltipData: LineTouchTooltipData(
                getTooltipColor: (_) => C.cardHi,
                getTooltipItems: (spots) => [
                  for (final s in spots)
                    LineTooltipItem(
                      '${series[s.barIndex].$1}: ${n(s.y)}',
                      TextStyle(color: series[s.barIndex].$2, fontSize: 11),
                    ),
                ],
              ),
            ),
            lineBarsData: [
              for (final (_, color, values) in series)
                LineChartBarData(
                  spots: [
                    for (var i = 0; i < values.length; i++)
                      if (values[i] != null) FlSpot(i.toDouble(), values[i]!),
                  ],
                  isCurved: true,
                  curveSmoothness: 0.25,
                  preventCurveOverShooting: true,
                  color: color,
                  barWidth: 1.6,
                  dotData: const FlDotData(show: false),
                ),
            ],
          ),
        ),
      ),
      _legend([for (final (label, color, _) in series) (label, color)]),
    ],
  );
}

// ---------------------------------------------------------------------------
// Secciones del reporte
// ---------------------------------------------------------------------------

/// Los modelos sin datos no se dibujan: esta tarjeta dice qué les falta.
class _PendingSection extends StatelessWidget {
  const _PendingSection({required this.modelos});
  final List<(String, String)> modelos;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      title: 'Modelos pendientes',
      icon: Icons.hourglass_empty,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Note(
            'Aparecen solos en cuanto haya datos suficientes. '
            'Sigue recolectando lecturas con la cámara y el pulso a la vez.',
          ),
          for (final (nombre, mensaje) in modelos)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '$nombre: ',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    TextSpan(text: mensaje),
                  ],
                ),
                style: const TextStyle(fontSize: 13),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// CRISP-DM: fases 1, 5 y 6 (mismos textos que el panel web)
// ---------------------------------------------------------------------------

class _BusinessSection extends StatelessWidget {
  const _BusinessSection({required this.criterios});
  final Map<String, dynamic> criterios;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      title: 'Fase 1 · Comprensión del negocio',
      icon: Icons.flag_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Note(
            'Objetivo: detectar a tiempo la fatiga del conductor combinando dos fuentes, la cámara (ojos, boca y '
            'cabeza) y el pulso, para alertarlo y avisar al supervisor antes de un accidente. Un sistema de seguridad '
            'debe perder la menor cantidad posible de fatiga real, aunque eso cueste alguna falsa alarma; por eso se '
            'pide más recall que precisión.',
          ),
          const SizedBox(height: 12),
          KpiGrid(
            children: [
              KpiTile(
                label: 'Criterio de éxito · Recall',
                value: '≥ ${pct(criterios['recall'])}',
                hint: 'de la fatiga real, cuánta debe detectarse',
              ),
              KpiTile(
                label: 'Criterio de éxito · Precisión',
                value: '≥ ${pct(criterios['precision'])}',
                hint: 'de las alertas, cuántas deben ser fatiga',
              ),
              const KpiTile(
                label: 'Etiqueta real',
                value: 'KSS ≥ 7',
                hint: 'autoreporte de somnolencia (escala 1–9)',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EvaluationSection extends StatelessWidget {
  const _EvaluationSection({required this.ev});
  final Map<String, dynamic> ev;

  @override
  Widget build(BuildContext context) {
    final crit = _map(ev['criterios']);
    final modelos = _list(ev['modelos']).map(_map).toList();
    Widget mark(String valor, bool ok) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(valor),
        const SizedBox(width: 6),
        Pill(ok ? '✓ cumple' : '✗ no cumple', color: ok ? C.verde : C.rojo),
      ],
    );
    final real = ev['etiqueta_real'] == true;
    return GlassCard(
      title: 'Fase 5 · Evaluación frente a los criterios de éxito',
      icon: Icons.fact_check_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Note(
            'Se comparan los modelos supervisados de la fase 4, medidos con ventanas que no usaron para entrenar, '
            'contra los criterios de la fase 1: recall ≥ ${pct(crit['recall'])} y precisión ≥ ${pct(crit['precision'])}.',
          ),
          const SizedBox(height: 8),
          SimpleTable(
            headers: const ['Modelo', 'Recall', 'Precisión', 'F1', '¿Cumple?'],
            rows: [
              for (final m in modelos)
                [
                  '${m['modelo']}',
                  mark(pct(m['recall']), m['cumple_recall'] == true),
                  mark(pct(m['precision']), m['cumple_precision'] == true),
                  n(m['f1'], 3),
                  m['cumple'] == true ? '✓ Sí' : '✗ No',
                ],
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: (real ? C.verde : C.ambar).withValues(alpha: 0.1),
              border: Border.all(color: (real ? C.verde : C.ambar).withValues(alpha: 0.4)),
            ),
            child: Text('${ev['conclusion'] ?? ''}', style: const TextStyle(color: C.text, fontSize: 13, height: 1.4)),
          ),
        ],
      ),
    );
  }
}

class _DeploymentSection extends StatelessWidget {
  const _DeploymentSection({required this.recomendaciones});
  final List<String> recomendaciones;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      title: 'Fase 6 · Despliegue',
      icon: Icons.rocket_launch_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Note(
            'El conocimiento obtenido se usa en tiempo real: el motor de fusión (fusion.py) solo da alerta cuando la '
            'cámara y el pulso muestran fatiga a la vez, el ESP32 hace sonar el buzzer, y el supervisor sigue a cada '
            'conductor en el panel web y en esta app. Los datos y el dataset preparado se pueden exportar en CSV para '
            'nuevas iteraciones del proceso.',
          ),
          if (recomendaciones.isNotEmpty) ...[
            const SubTitle('Recomendaciones a partir de los resultados'),
            for (final t in recomendaciones) _Bullet(t),
          ],
        ],
      ),
    );
  }
}

/// Recuadro "Interpretación" debajo de cada fase (mismo texto que el panel web).
class _InterpretationCard extends StatelessWidget {
  const _InterpretationCard({required this.lines});
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) return const SizedBox.shrink();
    return GlassCard(
      title: 'Interpretación',
      icon: Icons.lightbulb_outline,
      accent: C.cyan,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (final t in lines) _Bullet(t)],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('•  ', style: TextStyle(color: C.cyan, fontWeight: FontWeight.w700)),
        Expanded(child: Text(text, style: const TextStyle(color: C.text, fontSize: 13, height: 1.45))),
      ],
    ),
  );
}

class _QualitySection extends StatelessWidget {
  const _QualitySection({required this.q});
  final Map<String, dynamic> q;

  @override
  Widget build(BuildContext context) {
    final a = _map(q['atipicos_eliminados']);
    final rg = _map(q['rangos_validos']);
    final lim = _map(q['atipicos_limites'])['bpm'];
    String rango(dynamic r) => r is List && r.length == 2 ? '${n(r[0], 1)}–${n(r[1], 1)}' : '—';
    return GlassCard(
      title: 'Fase 2 · Comprensión de los datos: calidad',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Note(
            'Se toman todas las lecturas crudas de la sesión (tabla sensor_readings) y se revisa su calidad: '
            'duplicados, faltantes, lecturas imposibles y atípicos. Las lecturas duplicadas se eliminan; los demás '
            'valores problemáticos se reemplazan por nulos en vez de borrar la fila completa.',
          ),
          const SizedBox(height: 12),
          KpiGrid(
            children: [
              KpiTile(
                label: 'Registros',
                value: n(q['registros_iniciales'], 0),
                hint: '${n(q['lecturas_frame'], 0)} frames · ${n(q['lecturas_pulso'], 0)} pulso',
              ),
              KpiTile(
                label: 'Duplicados',
                value: n(q['duplicados_eliminados'], 0),
                hint: 'eliminados: ${n(q['duplicados_exactos'], 0)} exactos (misma hora) y '
                    '${n(q['duplicados_reenvios'], 0)} repetidas (mismo valor en < 1 s)',
              ),
              KpiTile(
                label: 'Frames sin rostro',
                value: n(q['frames_sin_rostro'], 0),
                hint: '${n(q['pct_frames_sin_rostro'], 1)} % de los frames',
              ),
              KpiTile(
                label: 'BPM implausibles',
                value: n(q['bpm_implausibles'], 0),
                hint: 'fuera de ${rango(rg['bpm'])} BPM (error de sensor)',
              ),
              KpiTile(
                label: 'Inconsistentes',
                value: n(q['valores_inconsistentes'], 0),
                hint: 'EAR fuera de ${rango(rg['ear'])} o MAR fuera de ${rango(rg['mar'])} (imposibles por definición)',
              ),
              KpiTile(label: 'Atípicos BPM', value: n(a['bpm'] ?? 0, 0), hint: 'regla IQR × 3: fuera de ${rango(lim)} BPM'),
              KpiTile(
                label: 'Pérdidas de comunicación',
                value: n(q['perdidas_comunicacion'], 0),
                hint: '${n(q['segundos_sin_comunicacion'], 0)} s sin lecturas (huecos > 10 s)',
              ),
              KpiTile(
                label: 'Sesiones / personas',
                value: '${n(q['sesiones'], 0)} / ${n(q['personas'], 0)}',
                hint: 'persona = texto antes de "_"',
              ),
            ],
          ),
          if (_list(q['duplicados_detalle']).isNotEmpty)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              expandedAlignment: Alignment.centerLeft,
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              title: Text(
                'Ver las ${_list(q['duplicados_detalle']).length} lecturas repetidas que se eliminaron',
                style: const TextStyle(fontWeight: FontWeight.w600, color: C.text, fontSize: 13.5),
              ),
              children: [
                const Note(
                  'Cada fila son dos lecturas de la misma sesión que llegaron casi al mismo tiempo (menos de 1 s; lo normal '
                  'es una cada 2 s) con exactamente el mismo valor. La red demoró una y la siguiente llegó rápido, y el sensor '
                  'no alcanzó a registrar un latido nuevo entre las dos. Se quita la segunda porque repite el mismo dato y lo '
                  'contaría dos veces.',
                ),
                for (final d in _list(q['duplicados_detalle']).map(_map))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      '${d['session_id']} · ${d['fuente'] == 'pulso' ? 'Pulso' : 'Cámara'} · '
                      '${_map(d['valores']).entries.map((e) => '${e.key} = ${n(e.value, 3)}').join(' · ')}\n'
                      'Original: ${'${d['hora_original'] ?? '—'}'.replaceAll('T', ' ')}\n'
                      'Repetida (se quitó): ${'${d['hora']}'.replaceAll('T', ' ')} '
                      '(+${n(d['segundos_tras_original'], 3)} s)',
                      style: const TextStyle(color: C.text, fontSize: 12.5, height: 1.4),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Diccionario de variables de cada ventana (mismo contenido que el panel web,
/// viene en parametros.diccionario del reporte).
class _VariableDictionary extends StatelessWidget {
  const _VariableDictionary({required this.dic});
  final Map<String, dynamic> dic;

  @override
  Widget build(BuildContext context) {
    final vars = _list(dic['caracteristicas']).map(_map).toList();
    final otras = _list(dic['otras_columnas']).map(_map).toList();
    if (vars.isEmpty) return const SizedBox.shrink();
    const code = TextStyle(color: C.muted, fontSize: 11.5, fontFamily: 'monospace');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SubTitle('Diccionario de variables de cada ventana'),
        const Note('Estas 8 variables se calculan en cada ventana y son las que usan todos los modelos de la fase 4.'),
        const SizedBox(height: 8),
        for (final v in vars)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: C.cardHi.withValues(alpha: 0.6),
              border: Border.all(color: C.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('${v['nombre']}', style: const TextStyle(fontWeight: FontWeight.w700, color: C.text)),
                    ),
                    Pill(
                      v['fatiga'] == 'Sube' ? '↑ sube con fatiga' : '↓ baja con fatiga',
                      color: v['fatiga'] == 'Sube' ? C.rojo : C.cyan,
                    ),
                  ],
                ),
                Text('${v['clave']} · ${v['fuente']}', style: code),
                const SizedBox(height: 6),
                Text('${v['mide']}', style: const TextStyle(color: C.text, fontSize: 13)),
                const SizedBox(height: 4),
                Note('Cálculo: ${v['calculo']}'),
                Note('Rango: ${v['rango']}'),
              ],
            ),
          ),
        if (otras.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            expandedAlignment: Alignment.centerLeft,
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            title: const Text(
              'Otras columnas de la ventana (identificación, calidad y etiquetas)',
              style: TextStyle(fontWeight: FontWeight.w600, color: C.text, fontSize: 13.5),
            ),
            children: [
              const Note(
                'No entran a los modelos como variables, pero aparecen en el dataset que se descarga en CSV. '
                'Las de rol «Etiqueta» son la respuesta que los modelos supervisados intentan predecir.',
              ),
              const SizedBox(height: 6),
              for (final o in otras)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${o['nombre']} · ${o['rol']}', style: const TextStyle(fontWeight: FontWeight.w600, color: C.text)),
                      Text('${o['clave']}', style: code),
                      Note('${o['descripcion']}'),
                    ],
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

class _DescriptiveSection extends StatelessWidget {
  const _DescriptiveSection({required this.d, required this.labels, required this.ventana, required this.diccionario});
  final Map<String, dynamic> d;
  final Map<String, String> labels;
  final int ventana;
  final Map<String, dynamic> diccionario;

  @override
  Widget build(BuildContext context) {
    final serie = _list(d['serie_temporal']).map(_map).toList();
    // Con varios días el eje lleva la fecha: si no, las horas parecen desordenadas
    String ts(Map<String, dynamic> r) => ((r['timestamp'] as String?) ?? '').padRight(19);
    final variosDias = serie.isNotEmpty && ts(serie.first).substring(0, 10) != ts(serie.last).substring(0, 10);
    final xLabels = [
      for (final r in serie)
        variosDias
            ? '${ts(r).substring(8, 10)}/${ts(r).substring(5, 7)} ${ts(r).substring(11, 16)}'
            : ts(r).substring(11, 19),
    ];
    final dist = _map(d['distribucion_estados']);
    final dia = _map(d['eventos_por_dia']);
    final hora = _map(d['eventos_por_hora']);
    final st = _map(d['estadisticos']);
    final est = _map(d['medias_por_estado']);
    final corr = d['correlacion'] == null ? null : _map(d['correlacion']);
    final ventanaTxt = ventana >= 60 ? '${ventana ~/ 60} min' : '$ventana s';

    return GlassCard(
      title: 'Fase 3 · Preparación de los datos: ventanas y análisis descriptivo',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Note(
            'Las lecturas de cámara (~cada 1,5 s) y de pulso (~cada 2 s) llegan en instantes distintos. Para '
            'integrarlas se agrupan en ventanas de $ventanaTxt y en cada una se calculan las variables: EAR medio, '
            'PERCLOS, MAR máximo, bostezos, inclinación media, BPM medio, su desviación y la caída del BPM respecto '
            'al basal. Resultado: ${n(d['ventanas_totales'], 0)} ventanas, ${n(d['ventanas_completas'], 0)} con '
            'todas las variables.',
          ),
          _VariableDictionary(dic: diccionario),
          const SubTitle('Serie temporal por ventana · BPM medio'),
          _lineChart([
            ('BPM medio', C.rojo, [for (final r in serie) asDouble(r['bpm_mean'])]),
          ], xLabels: xLabels),
          const SubTitle('Serie temporal por ventana · ojos'),
          _lineChart(
            [
              ('PERCLOS (%)', C.ambar, [for (final r in serie) asDouble(r['perclos'])]),
              (
                'EAR medio × 100',
                C.azul,
                [for (final r in serie) asDouble(r['ear_mean']) == null ? null : asDouble(r['ear_mean'])! * 100],
              ),
            ],
            minY: 0,
            maxY: 100,
            xLabels: xLabels,
          ),
          const SubTitle('Distribución de ventanas por estado'),
          _barChart(
            labels: dist.keys.toList(),
            values: [for (final v in dist.values) asDouble(v) ?? 0],
            colors: [for (final k in dist.keys) _statusColor[k] ?? C.gris],
          ),
          const SubTitle('Episodios de fatiga por hora del día'),
          _barChart(
            labels: [for (var h = 0; h < 24; h++) '${h}h'],
            values: [for (var h = 0; h < 24; h++) asDouble(hora['$h']) ?? 0],
            colors: const [C.rojo],
            labelEvery: 3,
          ),
          const SubTitle('Frecuencia de episodios de fatiga por día'),
          _barChart(
            labels: [for (final k in dia.keys) k.length >= 10 ? k.substring(5) : k],
            values: [for (final v in dia.values) asDouble(v) ?? 0],
            colors: const [C.ambar],
            labelEvery: (dia.length / 6).ceil().clamp(1, 1 << 30),
          ),
          const SubTitle('Estadísticos descriptivos por ventana'),
          SimpleTable(
            headers: const ['Variable', 'n', 'Media', 'Desv.', 'Mín.', 'Mediana', 'Máx.'],
            rows: [
              for (final e in st.entries)
                [
                  labels[e.key] ?? e.key,
                  n(_map(e.value)['n'], 0),
                  n(_map(e.value)['media']),
                  n(_map(e.value)['desv']),
                  n(_map(e.value)['min']),
                  n(_map(e.value)['p50']),
                  n(_map(e.value)['max']),
                ],
            ],
          ),
          if (est.isNotEmpty) ...[
            const SubTitle('Promedio de cada variable según el estado de la fusión'),
            SimpleTable(
              headers: ['Variable', ...est.keys],
              rows: [
                for (final v in labels.keys) [labels[v], for (final s in est.keys) n(_map(est[s])[v])],
              ],
            ),
          ],
          if (corr != null) ...[
            const SubTitle('Matriz de correlación (Pearson)'),
            Builder(
              builder: (context) {
                final vars = _list(corr['variables']).cast<String>();
                final m = _list(corr['matriz']).map(_list).toList();
                return SimpleTable(
                  headers: ['', ...vars.map((v) => labels[v] ?? v)],
                  rows: [
                    for (var i = 0; i < m.length; i++) [labels[vars[i]] ?? vars[i], for (final v in m[i]) n(v)],
                  ],
                  cellColors: [
                    for (var i = 0; i < m.length; i++) [null, for (final v in m[i]) _heatColor(v)],
                  ],
                );
              },
            ),
            const SizedBox(height: 6),
            const Note(
              'Azul = correlación positiva, rojo = negativa. Una correlación negativa entre EAR medio y '
              'PERCLOS es lo esperado: cuanto menos abiertos los ojos, mayor el porcentaje de tiempo con ojos cerrados.',
            ),
          ],
        ],
      ),
    );
  }
}

class _ClusterSection extends StatelessWidget {
  const _ClusterSection({required this.c, required this.labels});
  final Map<String, dynamic> c;
  final Map<String, String> labels;

  @override
  Widget build(BuildContext context) {
    if (c['disponible'] != true) {
      return GlassCard(
        title: 'Fase 4a · Clustering K-Means',
        child: EmptyState('${c['mensaje'] ?? ''}', icon: Icons.scatter_plot),
      );
    }
    final grupos = _list(c['grupos']).map(_map).toList();
    final names = [for (final g in grupos) g['nombre'] as String];
    final pts = _list(c['puntos_pca']).map(_map).toList();
    final sil = _map(c['silueta_por_k']);
    final pca = _list(c['pca_varianza_explicada']);
    final cr = _map(c['cruce_cluster_vs_fusion']);
    final k = (c['k'] as num?)?.toInt();
    final pcaVar = pca.length >= 2 ? (asDouble(pca[0])! + asDouble(pca[1])!) * 100 : null;

    return GlassCard(
      title: 'Fase 4a · Modelado: clustering K-Means (no supervisado)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Note(
            'Sin usar ninguna etiqueta, K-Means agrupa las ventanas por similitud en las 8 variables '
            '(estandarizadas con z-score). El número de grupos se elige con el coeficiente de silueta y cada grupo se '
            'nombra según su centroide: mayor PERCLOS, caída de BPM y bostezos → "Somnolencia".',
          ),
          const SizedBox(height: 12),
          KpiGrid(
            children: [
              KpiTile(label: 'Grupos (k)', value: '$k'),
              KpiTile(label: 'Silueta', value: n(c['silueta']), hint: '−1 a 1; > 0,25 = estructura razonable'),
              KpiTile(
                label: 'ARI vs. fusión',
                value: n(c['ari_vs_fusion']),
                hint: 'acuerdo con las reglas (0 = azar, 1 = total)',
              ),
              KpiTile(
                label: 'Varianza PCA',
                value: pcaVar == null ? '—' : '${n(pcaVar, 1)} %',
                hint: 'explicada por el gráfico 2D',
              ),
            ],
          ),
          const SubTitle('Ventanas proyectadas con PCA (2 componentes)'),
          SizedBox(
            height: 240,
            child: ScatterChart(
              ScatterChartData(
                gridData: FlGridData(
                  getDrawingHorizontalLine: (_) => const FlLine(color: C.border, strokeWidth: 1),
                  getDrawingVerticalLine: (_) => const FlLine(color: C.border, strokeWidth: 1),
                ),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(),
                  rightTitles: const AxisTitles(),
                  leftTitles: AxisTitles(
                    axisNameWidget: const Text('CP2', style: TextStyle(color: C.muted, fontSize: 10)),
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 30,
                      getTitlesWidget: (v, meta) => axisLabel(v, meta, n(v, 1), 9),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    axisNameWidget: const Text('CP1', style: TextStyle(color: C.muted, fontSize: 10)),
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 22,
                      getTitlesWidget: (v, meta) => axisLabel(v, meta, n(v, 1), 9),
                    ),
                  ),
                ),
                scatterSpots: [
                  for (final p in pts)
                    if (asDouble(p['x']) != null && asDouble(p['y']) != null)
                      ScatterSpot(
                        asDouble(p['x'])!,
                        asDouble(p['y'])!,
                        dotPainter: FlDotCirclePainter(
                          radius: 3.5,
                          color: _clusterColor('${p['cluster']}', names).withValues(alpha: 0.75),
                          strokeWidth: 0,
                        ),
                      ),
                ],
              ),
            ),
          ),
          _legend([for (final nm in names) (nm, _clusterColor(nm, names))]),
          const SubTitle('Coeficiente de silueta según k'),
          _barChart(
            labels: [for (final kk in sil.keys) 'k=$kk'],
            values: [for (final v in sil.values) asDouble(v) ?? 0],
            colors: [for (final kk in sil.keys) kk == '$k' ? C.azul : C.azul.withValues(alpha: 0.35)],
            height: 170,
          ),
          const SubTitle('Centroides de cada grupo (unidades originales)'),
          SimpleTable(
            headers: ['Grupo', 'Ventanas', ...labels.values],
            rows: [
              for (final g in grupos)
                [
                  Pill('${g['nombre']}', color: _clusterColor('${g['nombre']}', names)),
                  '${g['tamano']} (${n(g['porcentaje'], 1)} %)',
                  for (final v in labels.keys) n(_map(g['centroide'])[v]),
                ],
            ],
          ),
          const SubTitle('Grupos vs. estado de la fusión por reglas'),
          SimpleTable(
            headers: ['Grupo \\ estado fusión', ..._list(cr['columnas']).map((x) => '$x')],
            rows: [
              for (var i = 0; i < _list(cr['filas']).length; i++)
                ['${_list(cr['filas'])[i]}', ..._list(_list(cr['valores'])[i]).map((v) => '$v')],
            ],
          ),
        ],
      ),
    );
  }
}

class _ClassifySection extends StatelessWidget {
  const _ClassifySection({required this.k});
  final Map<String, dynamic> k;

  @override
  Widget build(BuildContext context) {
    if (k['disponible'] != true) {
      return GlassCard(
        title: 'Fase 4b · Árbol de decisión',
        child: EmptyState(
          '${k['mensaje'] ?? ''}${k['fuente_etiqueta'] != null ? '\nEtiqueta: ${k['fuente_etiqueta']}' : ''}',
          icon: Icons.account_tree_outlined,
        ),
      );
    }
    final m = _map(k['metricas']);
    final cm = _list(_map(k['matriz_confusion'])['valores'])
        .map((r) => _list(r).map((v) => (v as num).toInt()).toList())
        .toList();
    final maxCm = cm.expand((r) => r).fold<int>(1, (a, b) => b > a ? b : a);
    Color cell(int v, bool ok) => (ok ? C.verde : C.rojo).withValues(alpha: 0.12 + 0.6 * v / maxCm);
    final clases = _map(k['clases']);
    final imp = _list(k['importancia_variables']).map(_map).toList();
    final comp = _list(k['comparacion_modelos']).map(_map).toList();

    return GlassCard(
      title: 'Fase 4b · Modelado: árbol de decisión (supervisado)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Note(
            'El árbol aprende a predecir si una ventana corresponde a fatiga a partir de las 8 variables. Se entrena '
            'con una parte de las ventanas y se evalúa con otra que el modelo no vio. Etiqueta usada: '
            '${k['fuente_etiqueta']}.\nPartición entrenamiento/prueba: ${k['particion']}',
          ),
          if (k['advertencia'] != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: C.ambar.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: C.ambar),
              ),
              child: Text('${k['advertencia']}', style: const TextStyle(color: C.ambar)),
            ),
          ],
          const SizedBox(height: 12),
          KpiGrid(
            children: [
              KpiTile(
                label: 'Exactitud',
                value: pct(m['exactitud']),
                hint: 'base (clase mayoritaria): ${pct(m['exactitud_clasificador_base'])}',
              ),
              KpiTile(label: 'Precisión', value: pct(m['precision']), hint: 'de las alertas, cuántas eran fatiga'),
              KpiTile(label: 'Recall', value: pct(m['recall']), hint: 'de la fatiga real, cuánta se detectó'),
              KpiTile(label: 'F1', value: n(m['f1'], 3), hint: 'media armónica precisión/recall'),
              KpiTile(
                label: 'Ventanas',
                value: '${((k['n_entrenamiento'] as num?) ?? 0) + ((k['n_prueba'] as num?) ?? 0)}',
                hint: '${clases['fatiga']} fatiga · ${clases['sin_fatiga']} sin fatiga',
              ),
            ],
          ),
          if (cm.length == 2) ...[
            const SubTitle('Matriz de confusión (conjunto de prueba)'),
            SimpleTable(
              headers: const ['', 'Predicho: sin fatiga', 'Predicho: fatiga'],
              rows: [
                ['Real: sin fatiga', '${cm[0][0]}', '${cm[0][1]}'],
                ['Real: fatiga', '${cm[1][0]}', '${cm[1][1]}'],
              ],
              cellColors: [
                [null, cell(cm[0][0], true), cell(cm[0][1], false)],
                [null, cell(cm[1][0], false), cell(cm[1][1], true)],
              ],
            ),
            const SizedBox(height: 6),
            const Note(
              'Verde = aciertos. Abajo a la izquierda están los falsos negativos (fatiga no detectada), el error '
              'más costoso en este problema.',
            ),
          ],
          const SubTitle('Importancia de cada variable en el árbol'),
          for (final r in imp)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(width: 130, child: Text('${r['variable']}', style: const TextStyle(fontSize: 12))),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: (asDouble(r['importancia']) ?? 0).clamp(0.0, 1.0),
                        minHeight: 10,
                        color: C.violeta,
                        backgroundColor: C.cardHi,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 48,
                    child: Text(
                      n(r['importancia'], 3),
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          const SubTitle('Reglas aprendidas por el árbol'),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: C.bg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: C.border),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                '${k['reglas'] ?? ''}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: C.muted),
              ),
            ),
          ),
          if (comp.isNotEmpty) ...[
            SubTitle(
              'Comparación de algoritmos (validación cruzada ${k['validacion_cruzada']}, '
              '${k['folds_validacion_cruzada']} particiones, F1)',
            ),
            SimpleTable(
              headers: const ['Modelo', 'F1 medio', 'Desv.'],
              rows: [
                for (final r in comp) ['${r['modelo']}', n(r['f1_medio'], 3), '± ${n(r['f1_desv'], 3)}'],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _AnomaliesSection extends StatelessWidget {
  const _AnomaliesSection({required this.a, required this.labels});
  final Map<String, dynamic> a;
  final Map<String, String> labels;

  @override
  Widget build(BuildContext context) {
    if (a['disponible'] != true) {
      return GlassCard(
        title: 'Fase 4c · Detección de anomalías',
        child: EmptyState('${a['mensaje'] ?? ''}', icon: Icons.radar),
      );
    }
    final rows = _list(a['anomalias']).map(_map).toList();
    return GlassCard(
      title: 'Fase 4c · Modelado: anomalías con Isolation Forest',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Note(
            'Isolation Forest marca las ventanas cuya combinación de variables se aleja del patrón general '
            '(${a['algoritmo']}). Pueden ser episodios de fatiga intensos o problemas de captura (mala iluminación, '
            'sensor mal puesto). Se detectaron ${a['anomalias_detectadas']} de ${a['ventanas_analizadas']} ventanas.',
          ),
          const SizedBox(height: 10),
          if (rows.isEmpty)
            const EmptyState('Sin anomalías.')
          else
            SimpleTable(
              headers: [
                'Ventana',
                'Estado',
                'Variable más atípica',
                'Puntaje',
                for (final k in ['ear_mean', 'perclos', 'yawn_count', 'tilt_abs_mean', 'bpm_mean', 'bpm_drop_pct'])
                  labels[k] ?? k,
              ],
              rows: [
                for (final r in rows)
                  [
                    ((r['timestamp'] as String?) ?? '').replaceAll('T', ' '),
                    '${r['estado_fusion']}',
                    '${r['variable_mas_atipica']}',
                    n(r['puntaje_anomalia'], 3),
                    n(r['ear_mean'], 3),
                    n(r['perclos'], 1),
                    n(r['yawn_count'], 0),
                    n(r['tilt_abs_mean'], 1),
                    n(r['bpm_mean'], 1),
                    n(r['bpm_drop_pct'], 1),
                  ],
              ],
            ),
        ],
      ),
    );
  }
}
