// Piezas del panel en vivo: ECG animado, medidores con umbral, tendencias,
// dona de eventos e indicador de apertura ocular.

import 'dart:async';
import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../live_controller.dart';
import '../theme.dart';
import '../util.dart';
import 'common.dart';

// ---------------------------------------------------------------------------
// ECG: misma forma de onda sintética que el canvas del web, al ritmo del BPM.
// ---------------------------------------------------------------------------

class EcgView extends StatefulWidget {
  const EcgView({super.key, required this.bpm, required this.color, this.height = 70, this.phase});
  final double? bpm;
  final Color color;
  final double height;

  /// Si se da, recibe la fase del latido en cada cuadro (para sincronizar el corazón).
  final ValueNotifier<double>? phase;

  @override
  State<EcgView> createState() => _EcgViewState();
}

class _EcgViewState extends State<EcgView> {
  // Temporizador de ~25 fps en vez de Ticker: un Ticker pide un cuadro en cada
  // refresco (60/s) y Flutter compone la pantalla entera en cada uno, aunque no
  // cambie nada; eso calentaba el teléfono. Así solo hay cuadro cuando se dibuja.
  static const _frame = Duration(milliseconds: 40);
  Timer? _timer;
  final _clock = Stopwatch();
  Duration _last = Duration.zero;
  bool _visible = true;
  double _phase = 0;
  List<double?> _ys = const [];
  int _x = 0;
  final _rnd = Random();

  static double _g(double p, double c, double w, double a) => a * exp(-pow(p - c, 2) / (2 * w * w));
  static double _wave(double p) =>
      _g(p, .16, .028, .12) - _g(p, .34, .008, .14) + _g(p, .38, .011, 1) - _g(p, .42, .01, .28) + _g(p, .64, .045, .3);

  // corre solo con pulso y con la pestaña visible; si no, la línea queda quieta
  void _sync() {
    final run = widget.bpm != null && _visible;
    if (run && _timer == null) {
      _clock
        ..reset()
        ..start();
      _last = Duration.zero;
      _timer = Timer.periodic(_frame, (_) => _tick(_clock.elapsed));
    } else if (!run && _timer != null) {
      _timer!.cancel();
      _timer = null;
      _clock.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _sync();
  }

  @override
  void didUpdateWidget(EcgView old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _tick(Duration now) {
    final dt = min((now - _last).inMicroseconds / 1e6, 0.08);
    _last = now;
    if (_ys.isEmpty) return;
    const speed = 110.0; // px/s
    final steps = max(1, (speed * dt).round());
    final bpm = widget.bpm;
    final rate = bpm != null ? bpm / 60 : 0;
    for (var s = 0; s < steps; s++) {
      _phase = (_phase + rate * dt / steps) % 1;
      final amp = bpm != null ? _wave(_phase) : 0.0;
      _ys[_x] = amp + (_rnd.nextDouble() - 0.5) * 0.02;
      _x = (_x + 1) % _ys.length;
      for (var k = 0; k < 18; k++) {
        _ys[(_x + k) % _ys.length] = null; // hueco delante del cabezal
      }
    }
    widget.phase?.value = _phase;
    setState(() {});
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth.floor();
        if (_ys.length != w && w > 0) {
          _ys = List<double?>.filled(w, widget.bpm == null ? 0.0 : null); // sin pulso: línea plana
          _x = 0;
        }
        // RepaintBoundary: cada cuadro del trazo repinta solo este recuadro, no toda
        // la pantalla con las sombras de las tarjetas (eso calentaba el teléfono)
        return RepaintBoundary(
          child: SizedBox(
            height: widget.height,
            width: double.infinity,
            child: CustomPaint(painter: _EcgPainter(_ys, _x, widget.color)),
          ),
        );
      },
    );
  }
}

class _EcgPainter extends CustomPainter {
  _EcgPainter(this.ys, this.head, this.color);
  final List<double?> ys;
  final int head;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    double y(double amp) => h * 0.62 - amp * h * 0.48;
    final glow = Paint()
      ..color = color.withValues(alpha: 0.22)
      ..strokeWidth = 6
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round; // halo sin desenfoque: el blur por cuadro es caro
    final line = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    var drawing = false;
    for (var i = 0; i < ys.length; i++) {
      final v = ys[i];
      if (v == null) {
        drawing = false;
        continue;
      }
      if (!drawing) {
        path.moveTo(i.toDouble(), y(v));
        drawing = true;
      } else {
        path.lineTo(i.toDouble(), y(v));
      }
    }
    canvas.drawPath(path, glow);
    canvas.drawPath(path, line);
    final prev = ys.isEmpty ? null : ys[(head - 1 + ys.length) % ys.length];
    canvas.drawCircle(Offset(head.toDouble(), y(prev ?? 0)), 2.4, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// ---------------------------------------------------------------------------
// Medidor con marca de umbral (los 5 del web: EAR, MAR, cabeza, caída, σ).
// ---------------------------------------------------------------------------

class MeterSpec {
  const MeterSpec({
    required this.name,
    required this.hint,
    required this.max,
    required this.thr,
    required this.isBad,
    required this.format,
    required this.thrLabel,
  });
  final String name, hint, thrLabel;
  final double max, thr;
  final bool Function(double v) isBad;
  final String Function(double v) format;
}

class MeterBar extends StatelessWidget {
  const MeterBar({super.key, required this.spec, required this.value});
  final MeterSpec spec;
  final double? value;

  @override
  Widget build(BuildContext context) {
    final has = value != null && !value!.isNaN;
    final bad = has && spec.isBad(value!);
    final color = bad ? C.rojo : C.cyan;
    final frac = has ? (value! / spec.max).clamp(0.0, 1.0) : 0.0;
    final tick = (spec.thr / spec.max).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(spec.name, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(spec.hint, style: const TextStyle(color: C.muted, fontSize: 12)),
              ),
              Text(
                has ? spec.format(value!) : '—',
                style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
              ),
              const SizedBox(width: 8),
              Pill(has ? (bad ? 'Alerta' : 'OK') : '—', color: bad ? C.rojo : C.verde, idle: !has),
            ],
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, c) {
              return SizedBox(
                height: 22,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: Container(
                        height: 8,
                        decoration: BoxDecoration(color: C.cardHi, borderRadius: BorderRadius.circular(99)),
                      ),
                    ),
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 500),
                      curve: Curves.easeOutCubic,
                      top: 0,
                      left: 0,
                      width: c.maxWidth * frac,
                      child: Container(
                        height: 8,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: [color.withValues(alpha: 0.5), color]),
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                    ),
                    Positioned(
                      left: c.maxWidth * tick - 1,
                      top: -3,
                      child: Container(width: 2, height: 14, color: C.text.withValues(alpha: 0.8)),
                    ),
                    Positioned(
                      left: (c.maxWidth * tick - 40).clamp(0.0, c.maxWidth - 80),
                      top: 11,
                      width: 80,
                      child: Text(
                        spec.thrLabel,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: C.muted, fontSize: 10),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tendencia con línea de referencia (umbral EAR o BPM basal).
// ---------------------------------------------------------------------------

class TrendChart extends StatelessWidget {
  const TrendChart({
    super.key,
    required this.data,
    required this.color,
    required this.unit,
    required this.dec,
    this.min,
    this.max,
    this.auto = false,
    this.ref,
    this.refColor = C.rojo,
    this.refLabel = '',
  });

  final List<TrendPoint> data;
  final Color color;
  final String unit;
  final int dec;
  final double? min, max;
  final bool auto;
  final double? ref;
  final Color refColor;
  final String refLabel;

  @override
  Widget build(BuildContext context) {
    if (data.length < 2) {
      return const SizedBox(
        height: 170,
        child: Center(
          child: Text('Esperando lecturas…', style: TextStyle(color: C.muted)),
        ),
      );
    }
    var lo = min ?? 0, hi = max ?? 1;
    if (auto) {
      final vs = [...data.map((d) => d.v), ?ref];
      lo = (vs.reduce((a, b) => a < b ? a : b) - 5).floorToDouble();
      hi = (vs.reduce((a, b) => a > b ? a : b) + 5).ceilToDouble();
    }
    return SizedBox(
      height: 170,
      child: LineChart(
        duration: const Duration(milliseconds: 150),
        LineChartData(
          minX: 0,
          maxX: (data.length - 1).toDouble(),
          minY: lo,
          maxY: hi,
          gridData: FlGridData(
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) => const FlLine(color: C.border, strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            bottomTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 38,
                getTitlesWidget: (v, meta) => axisLabel(v, meta, v.toStringAsFixed(dec)),
              ),
            ),
          ),
          extraLinesData: ExtraLinesData(
            horizontalLines: [
              if (ref != null)
                HorizontalLine(
                  y: ref!,
                  color: refColor,
                  strokeWidth: 1,
                  dashArray: [5, 4],
                  label: HorizontalLineLabel(
                    show: refLabel.isNotEmpty,
                    alignment: Alignment.topRight,
                    style: TextStyle(color: refColor, fontSize: 10),
                    labelResolver: (_) => refLabel,
                  ),
                ),
            ],
          ),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => C.cardHi,
              getTooltipItems: (spots) => [
                for (final s in spots)
                  LineTooltipItem(
                    '${data[s.x.toInt()].v.toStringAsFixed(dec + 1)} $unit\n${hms(data[s.x.toInt()].t)}',
                    const TextStyle(color: C.text, fontSize: 12),
                  ),
              ],
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: [for (var i = 0; i < data.length; i++) FlSpot(i.toDouble(), data[i].v)],
              isCurved: true,
              curveSmoothness: 0.2,
              preventCurveOverShooting: true,
              color: color,
              barWidth: 2,
              dotData: FlDotData(
                checkToShowDot: (spot, _) => spot.x == data.length - 1,
                getDotPainter: (_, _, _, _) =>
                    FlDotCirclePainter(radius: 4, color: color, strokeColor: C.bg, strokeWidth: 2),
              ),
              belowBarData: BarAreaData(
                show: true,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [color.withValues(alpha: 0.35), color.withValues(alpha: 0)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Dona de eventos por nivel.
// ---------------------------------------------------------------------------

class RiskDonut extends StatelessWidget {
  const RiskDonut({super.key, required this.counts});
  final Map<String, dynamic> counts;

  static const keys = ['alto', 'medio', 'advertencia_sensor'];

  @override
  Widget build(BuildContext context) {
    int v(String k) => (counts[k] as num?)?.toInt() ?? 0;
    final total = keys.fold<int>(0, (a, k) => a + v(k));
    return Row(
      children: [
        SizedBox(
          width: 130,
          height: 130,
          child: Stack(
            alignment: Alignment.center,
            children: [
              PieChart(
                PieChartData(
                  centerSpaceRadius: 44,
                  sectionsSpace: total > 1 ? 2 : 0,
                  startDegreeOffset: -90,
                  sections: total == 0
                      ? [PieChartSectionData(value: 1, color: C.cardHi, radius: 14, showTitle: false)]
                      : [
                          for (final k in keys)
                            if (v(k) > 0)
                              PieChartSectionData(
                                value: v(k).toDouble(),
                                color: kRisk[k]!.color,
                                radius: 14,
                                showTitle: false,
                              ),
                        ],
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('$total', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
                  const Text('eventos', style: TextStyle(color: C.muted, fontSize: 11)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            children: [
              for (final k in keys)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(color: kRisk[k]!.color, borderRadius: BorderRadius.circular(3)),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(kRisk[k]!.label)),
                      Text('${v(k)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                      SizedBox(
                        width: 44,
                        child: Text(
                          '${total == 0 ? 0 : (v(k) / total * 100).round()} %',
                          textAlign: TextAlign.right,
                          style: const TextStyle(color: C.muted, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Ojo cuya apertura sigue al EAR (versión simple del escáner del web).
// ---------------------------------------------------------------------------

class EyeIndicator extends StatelessWidget {
  const EyeIndicator({super.key, required this.open, required this.color, required this.searching});
  final double open; // 0..1
  final Color color;
  final bool searching;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: open),
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => CustomPaint(size: const Size(110, 64), painter: _EyePainter(v, color, searching)),
    );
  }
}

class _EyePainter extends CustomPainter {
  _EyePainter(this.open, this.color, this.searching);
  final double open;
  final Color color;
  final bool searching;

  @override
  void paint(Canvas canvas, Size s) {
    final cy = s.height / 2, h = s.height * 0.5 * open;
    final eye = Path()
      ..moveTo(0, cy)
      ..quadraticBezierTo(s.width / 2, cy - h * 2, s.width, cy)
      ..quadraticBezierTo(s.width / 2, cy + h * 2, 0, cy)
      ..close();
    canvas.drawPath(eye, Paint()..color = color.withValues(alpha: 0.12));
    canvas.save();
    canvas.clipPath(eye);
    if (!searching) {
      final r = s.height * 0.32;
      canvas.drawCircle(Offset(s.width / 2, cy), r, Paint()..color = color.withValues(alpha: 0.7));
      canvas.drawCircle(Offset(s.width / 2, cy), r * 0.45, Paint()..color = C.text);
    }
    canvas.restore();
    canvas.drawPath(
      eye,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _EyePainter old) => old.open != open || old.color != color || old.searching != searching;
}
