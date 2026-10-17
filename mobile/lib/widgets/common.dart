import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../theme.dart';
import 'brand.dart';

/// Tarjeta oscura con borde, equivalente al `.glass` del panel web.
class GlassCard extends StatelessWidget {
  const GlassCard({super.key, this.title, this.icon, this.trailing, required this.child, this.accent, this.padding});

  final String? title;
  final IconData? icon;
  final Widget? trailing;
  final Widget child;
  final Color? accent;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return FadeSlideIn(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutCubic,
        margin: const EdgeInsets.only(bottom: 14),
        padding: padding ?? const EdgeInsets.all(16),
        decoration: glassDecoration(accent: accent),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null) ...[
              Row(
                children: [
                  if (icon != null) ...[
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: (accent ?? C.cyan).withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Icon(icon, size: 16, color: accent ?? C.cyan),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Text(
                      title!,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: C.text),
                    ),
                  ),
                  ?trailing,
                ],
              ),
              const SizedBox(height: 12),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.color = C.verde, this.idle = false});
  final String text;
  final Color color;
  final bool idle;

  @override
  Widget build(BuildContext context) {
    final c = idle ? C.gris : color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: c.withValues(alpha: 0.4)),
      ),
      child: Text(
        text,
        style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// KPI pequeño (etiqueta, valor y pista), como `.kpi` del web.
class KpiTile extends StatelessWidget {
  const KpiTile({super.key, required this.label, required this.value, this.hint, this.color = C.cyan});
  final String label;
  final String value;
  final String? hint;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color.withValues(alpha: 0.16), C.cardHi.withValues(alpha: 0.7)],
        ),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(color: C.muted, fontSize: 12)),
          const SizedBox(height: 4),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            transitionBuilder: (child, a) => FadeTransition(
              opacity: a,
              child: ScaleTransition(scale: Tween(begin: 0.8, end: 1.0).animate(a), child: child),
            ),
            child: Text(
              value,
              key: ValueKey(value),
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
          ),
          if (hint != null) ...[
            const SizedBox(height: 2),
            Text(hint!, style: const TextStyle(color: C.muted, fontSize: 11)),
          ],
        ],
      ),
    );
  }
}

/// Rejilla de KPI de dos columnas que se adapta al ancho.
class KpiGrid extends StatelessWidget {
  const KpiGrid({super.key, required this.children, this.minWidth = 150});
  final List<Widget> children;
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final cols = (c.maxWidth / minWidth).floor().clamp(2, 4);
        final w = (c.maxWidth - (cols - 1) * 10) / cols;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [for (final ch in children) SizedBox(width: w, child: ch)],
        );
      },
    );
  }
}

class SubTitle extends StatelessWidget {
  const SubTitle(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 8),
    child: Text(
      text,
      style: const TextStyle(fontWeight: FontWeight.w600, color: C.text),
    ),
  );
}

class Note extends StatelessWidget {
  const Note(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Text(text, style: const TextStyle(color: C.muted, fontSize: 12.5, height: 1.4));
}

class EmptyState extends StatelessWidget {
  const EmptyState(this.text, {super.key, this.icon = Icons.verified_user_outlined});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Column(
      children: [
        Icon(icon, size: 36, color: C.muted),
        const SizedBox(height: 8),
        Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: C.muted),
        ),
      ],
    ),
  );
}

/// Tabla con desplazamiento horizontal. Cada celda es texto o un widget.
class SimpleTable extends StatelessWidget {
  const SimpleTable({super.key, required this.headers, required this.rows, this.cellColors});
  final List<String> headers;
  final List<List<Object?>> rows;

  /// Color de fondo opcional por celda [fila][columna].
  final List<List<Color?>>? cellColors;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowHeight: 38,
        dataRowMinHeight: 34,
        dataRowMaxHeight: 48,
        horizontalMargin: 10,
        columnSpacing: 18,
        headingTextStyle: const TextStyle(color: C.muted, fontSize: 12, fontWeight: FontWeight.w600),
        dataTextStyle: const TextStyle(color: C.text, fontSize: 13),
        border: const TableBorder(horizontalInside: BorderSide(color: C.border)),
        columns: [for (final h in headers) DataColumn(label: Text(h))],
        rows: [
          for (var i = 0; i < rows.length; i++)
            DataRow(
              cells: [
                for (var j = 0; j < rows[i].length; j++)
                  DataCell(
                    Container(
                      color: cellColors?[i][j],
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                      child: rows[i][j] is Widget ? rows[i][j] as Widget : Text('${rows[i][j] ?? '—'}'),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

void showSnack(BuildContext context, String msg, {bool ok = true}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Row(
        children: [
          Icon(ok ? Icons.check_circle_outline : Icons.error_outline, color: ok ? C.verde : C.rojo),
          const SizedBox(width: 10),
          Expanded(
            child: Text(msg, style: const TextStyle(color: C.text)),
          ),
        ],
      ),
    ),
  );
}

/// Etiqueta de eje para fl_chart. La librería rotula siempre también el mínimo
/// y el máximo aunque no caigan en la rejilla (p. ej. "85" pegado a "84"): se omiten.
Widget axisLabel(double v, TitleMeta meta, String text, [double size = 10]) {
  final steps = v / meta.appliedInterval;
  final onGrid = (steps - steps.round()).abs() < 1e-6;
  if ((v == meta.max || v == meta.min) && !onGrid) return const SizedBox.shrink();
  return Text(
    text,
    style: TextStyle(color: C.muted, fontSize: size),
  );
}
