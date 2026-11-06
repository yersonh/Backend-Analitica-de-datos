// Sección de regresión del reporte (logística / lineal). Consume `regresion`
// de /analitica/reporte.

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../theme.dart';
import '../util.dart';
import 'common.dart';

Map<String, dynamic> _map(dynamic v) => ((v as Map?) ?? const {}).cast<String, dynamic>();
List<dynamic> _list(dynamic v) => (v as List?) ?? const [];

// ---------------------------------------------------------------------------
// Regresión: logística (objetivo binario) o lineal (KSS continuo)
// ---------------------------------------------------------------------------


/// Interpretación de cada gráfica o tabla del reporte (interpretacion.graficos,
/// la genera analytics.interpret en el servidor). La fija AnalyticsScreen al
/// armar las secciones; ChartNote('clave') la muestra debajo de su gráfica.
Map<String, List<String>> chartNotes = const {};

class ChartNote extends StatelessWidget {
  const ChartNote(this.clave, {super.key});
  final String clave;

  @override
  Widget build(BuildContext context) {
    final lines = chartNotes[clave] ?? const <String>[];
    if (lines.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: C.cardHi.withValues(alpha: 0.55),
        border: Border.all(color: C.cyan.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('QUÉ MUESTRA', style: TextStyle(color: C.muted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8)),
          const SizedBox(height: 4),
          for (final t in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('•  ', style: TextStyle(color: C.cyan, fontWeight: FontWeight.w700)),
                  Expanded(child: Text(t, style: const TextStyle(color: C.text, fontSize: 12.5, height: 1.4))),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class RegressionSection extends StatelessWidget {
  const RegressionSection({super.key, required this.g});
  final Map<String, dynamic> g;

  @override
  Widget build(BuildContext context) {
    if (g['disponible'] != true) {
      return GlassCard(
        title: 'Fase 4d · Regresión logística / lineal',
        child: EmptyState('${g['mensaje'] ?? ''}', icon: Icons.functions),
      );
    }
    final elegido = g['modelo_elegido'] == 'lineal' ? 'lineal' : 'logística';
    final lin = _map(g['lineal']), log = _map(g['logistica']);
    return GlassCard(
      title: 'Fase 4d · Modelado: regresión (elegida: $elegido)',
      icon: Icons.functions,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: C.cyan.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: C.cyan.withValues(alpha: 0.5)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.lightbulb_outline, color: C.cyan, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text('${g['motivo']}', style: const TextStyle(fontSize: 13, height: 1.4))),
              ],
            ),
          ),
          if (g['modelo_elegido'] == 'lineal') ...[
            _LinearBlock(r: lin, chosen: true),
            _LogisticBlock(r: log, chosen: false),
          ] else ...[
            _LogisticBlock(r: log, chosen: true),
            _LinearBlock(r: lin, chosen: false),
          ],
        ],
      ),
    );
  }
}

Widget _blockTitle(String text, bool chosen) => Padding(
  padding: const EdgeInsets.only(top: 18, bottom: 8),
  child: Row(
    children: [
      Expanded(
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
      ),
      if (chosen) const Pill('elegida', color: C.cyan) else const Pill('complemento', color: C.gris),
    ],
  ),
);

Widget _equation(String eq) => Container(
  margin: const EdgeInsets.only(top: 10),
  padding: const EdgeInsets.all(10),
  decoration: BoxDecoration(
    color: C.bg,
    borderRadius: BorderRadius.circular(10),
    border: Border.all(color: C.border),
  ),
  child: SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Text(
      eq,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: C.muted),
    ),
  ),
);

/// Barras divergentes: coeficiente estandarizado de cada variable.
Widget _coefBars(List<Map<String, dynamic>> rows, {bool odds = false}) {
  final maxAbs = rows.fold<double>(
    0.0001,
    (a, r) => (asDouble(r['coeficiente']) ?? 0).abs() > a ? (asDouble(r['coeficiente']) ?? 0).abs() : a,
  );
  return Column(
    children: [
      for (final r in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              SizedBox(width: 118, child: Text('${r['variable']}', style: const TextStyle(fontSize: 12))),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, c) {
                    final v = asDouble(r['coeficiente']) ?? 0;
                    final half = c.maxWidth / 2;
                    final w = half * v.abs() / maxAbs;
                    final color = v >= 0 ? C.rojo : C.verde;
                    return SizedBox(
                      height: 14,
                      child: Stack(
                        children: [
                          Positioned(
                            left: half - 0.5,
                            top: 0,
                            bottom: 0,
                            child: Container(width: 1, color: C.border),
                          ),
                          Positioned(
                            left: v >= 0 ? half : half - w,
                            top: 2,
                            bottom: 2,
                            width: w,
                            child: Container(
                              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              SizedBox(
                width: 62,
                child: Text(
                  odds ? '×${n(r['odds_ratio'], 2)}' : n(r['coeficiente'], 2),
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      const SizedBox(height: 4),
      Note(
        odds
            ? 'Rojo = aumenta la probabilidad de fatiga, verde = la reduce. ×N: cuánto se multiplican las '
                  'odds de fatiga al subir la variable una desviación estándar.'
            : 'Rojo = sube el KSS estimado (más somnolencia), verde = lo baja. Valor: puntos KSS por cada '
                  'desviación estándar de la variable.',
      ),
    ],
  );
}

class _LogisticBlock extends StatelessWidget {
  const _LogisticBlock({required this.r, required this.chosen});
  final Map<String, dynamic> r;
  final bool chosen;

  @override
  Widget build(BuildContext context) {
    if (r['disponible'] != true) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [_blockTitle('Regresión logística', chosen), Note('${r['mensaje'] ?? ''}')],
      );
    }
    final m = _map(r['metricas']);
    final cv = r['validacion_cruzada'] == null ? null : _map(r['validacion_cruzada']);
    final cm = _list(_map(r['matriz_confusion'])['valores']).map((x) => _list(x)).toList();
    final roc = _list(r['curva_roc']).map(_map).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _blockTitle('Regresión logística · P(fatiga)', chosen),
        Note('Etiqueta: ${r['fuente_etiqueta']}. Partición: ${r['particion']}'),
        if (r['advertencia'] != null) ...[
          const SizedBox(height: 8),
          Text('${r['advertencia']}', style: const TextStyle(color: C.ambar, fontSize: 12.5)),
        ],
        const SizedBox(height: 10),
        KpiGrid(
          children: [
            KpiTile(
              label: 'Exactitud',
              value: pct(m['exactitud']),
              hint: 'base: ${pct(m['exactitud_clasificador_base'])}',
            ),
            KpiTile(label: 'Precisión', value: pct(m['precision']), hint: 'alertas que eran fatiga'),
            KpiTile(label: 'Recall', value: pct(m['recall']), hint: 'fatiga real detectada'),
            KpiTile(label: 'F1', value: n(m['f1'], 3)),
            KpiTile(label: 'AUC-ROC', value: n(m['auc'], 3), hint: '0,5 = azar · 1 = perfecto', color: C.violeta),
            if (cv != null)
              KpiTile(
                label: 'F1 validación cruzada',
                value: n(cv['f1_medio'], 3),
                hint: '± ${n(cv['f1_desv'], 3)} · ${cv['esquema']}',
                color: C.violeta,
              ),
          ],
        ),
        if (roc.length > 1) ...[
          const SubTitle('Curva ROC (conjunto de prueba)'),
          SizedBox(
            height: 200,
            child: LineChart(
              LineChartData(
                minX: 0,
                maxX: 1,
                minY: 0,
                maxY: 1,
                gridData: FlGridData(
                  getDrawingHorizontalLine: (_) => const FlLine(color: C.border, strokeWidth: 1),
                  getDrawingVerticalLine: (_) => const FlLine(color: C.border, strokeWidth: 1),
                ),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(),
                  rightTitles: const AxisTitles(),
                  leftTitles: AxisTitles(
                    axisNameWidget: const Text('verdaderos positivos', style: TextStyle(color: C.muted, fontSize: 10)),
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 30,
                      interval: 0.5,
                      getTitlesWidget: (v, meta) => axisLabel(v, meta, n(v, 1)),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    axisNameWidget: const Text('falsos positivos', style: TextStyle(color: C.muted, fontSize: 10)),
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 22,
                      interval: 0.5,
                      getTitlesWidget: (v, meta) => axisLabel(v, meta, n(v, 1)),
                    ),
                  ),
                ),
                lineTouchData: const LineTouchData(enabled: false),
                lineBarsData: [
                  LineChartBarData(
                    spots: const [FlSpot(0, 0), FlSpot(1, 1)],
                    color: C.gris,
                    barWidth: 1,
                    dashArray: [5, 4],
                    dotData: const FlDotData(show: false),
                  ),
                  LineChartBarData(
                    spots: [for (final p in roc) FlSpot(asDouble(p['fpr']) ?? 0, asDouble(p['tpr']) ?? 0)],
                    isStepLineChart: true,
                    color: C.violeta,
                    barWidth: 2.2,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(show: true, color: C.violeta.withValues(alpha: 0.15)),
                  ),
                ],
              ),
            ),
          ),
          const ChartNote('roc'),
        ],
        if (cm.length == 2) ...[
          const SubTitle('Matriz de confusión'),
          SimpleTable(
            headers: const ['', 'Predicho: sin fatiga', 'Predicho: fatiga'],
            rows: [
              ['Real: sin fatiga', '${cm[0][0]}', '${cm[0][1]}'],
              ['Real: fatiga', '${cm[1][0]}', '${cm[1][1]}'],
            ],
          ),
        ],
        const SubTitle('Coeficientes (odds ratio por variable)'),
        _coefBars(_list(r['coeficientes']).map(_map).toList(), odds: true),
        _equation('${r['ecuacion']}'),
        const ChartNote('coef_log'),
      ],
    );
  }
}

class _LinearBlock extends StatelessWidget {
  const _LinearBlock({required this.r, required this.chosen});
  final Map<String, dynamic> r;
  final bool chosen;

  @override
  Widget build(BuildContext context) {
    if (r['disponible'] != true) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [_blockTitle('Regresión lineal · nivel KSS', chosen), Note('${r['mensaje'] ?? ''}')],
      );
    }
    final m = _map(r['metricas']);
    final cv = r['validacion_cruzada'] == null ? null : _map(r['validacion_cruzada']);
    final pts = _list(r['real_vs_predicho']).map(_map).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _blockTitle('Regresión lineal · nivel KSS (1–9)', chosen),
        Note('Partición: ${r['particion']}'),
        const SizedBox(height: 10),
        KpiGrid(
          children: [
            KpiTile(label: 'R² (prueba)', value: n(m['r2'], 2), hint: 'varianza del KSS explicada'),
            KpiTile(label: 'MAE', value: n(m['mae'], 2), hint: 'puntos KSS (base: ${n(m['mae_modelo_base'], 2)})'),
            KpiTile(label: 'RMSE', value: n(m['rmse'], 2)),
            if (cv != null)
              KpiTile(
                label: 'R² validación cruzada',
                value: n(cv['r2_medio'], 2),
                hint: '± ${n(cv['r2_desv'], 2)} · ${cv['esquema']}',
                color: C.violeta,
              ),
          ],
        ),
        const SubTitle('KSS real vs. predicho'),
        SizedBox(
          height: 220,
          child: ScatterChart(
            ScatterChartData(
              minX: 1,
              maxX: 9,
              minY: 1,
              maxY: 9,
              gridData: FlGridData(
                horizontalInterval: 2,
                verticalInterval: 2,
                getDrawingHorizontalLine: (_) => const FlLine(color: C.border, strokeWidth: 1),
                getDrawingVerticalLine: (_) => const FlLine(color: C.border, strokeWidth: 1),
              ),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(),
                rightTitles: const AxisTitles(),
                leftTitles: AxisTitles(
                  axisNameWidget: const Text('predicho', style: TextStyle(color: C.muted, fontSize: 10)),
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 24,
                    interval: 2,
                    getTitlesWidget: (v, meta) => axisLabel(v, meta, n(v, 0)),
                  ),
                ),
                bottomTitles: AxisTitles(
                  axisNameWidget: const Text('real', style: TextStyle(color: C.muted, fontSize: 10)),
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 22,
                    interval: 2,
                    getTitlesWidget: (v, meta) => axisLabel(v, meta, n(v, 0)),
                  ),
                ),
              ),
              scatterSpots: [
                for (var k = 1; k <= 9; k++)
                  ScatterSpot(
                    k.toDouble(),
                    k.toDouble(),
                    dotPainter: FlDotCirclePainter(radius: 1.5, color: C.gris, strokeWidth: 0),
                  ),
                for (final p in pts)
                  ScatterSpot(
                    asDouble(p['real']) ?? 0,
                    asDouble(p['predicho']) ?? 0,
                    dotPainter: FlDotCirclePainter(radius: 3.5, color: C.azul.withValues(alpha: 0.6), strokeWidth: 0),
                  ),
              ],
            ),
          ),
        ),
        const Note('Puntos grises: la diagonal ideal (predicho = real).'),
        const ChartNote('lin'),
        const SubTitle('Coeficientes'),
        _coefBars(_list(r['coeficientes']).map(_map).toList()),
        _equation('${r['ecuacion']}'),
        const ChartNote('coef_lin'),
      ],
    );
  }
}
