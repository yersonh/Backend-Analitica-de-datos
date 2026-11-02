// Historial de episodios de fatiga (RF07, RF09), con filtros por nivel.

import 'dart:async';

import 'package:flutter/material.dart';

import '../live_controller.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/common.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.live});
  final LiveController live;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  String _filter = 'all';
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    // refresca los "hace X min"
    _clock = Timer.periodic(const Duration(seconds: 30), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const filters = {
      'all': 'Todos',
      'normal': 'Normal',
      'vigilancia': 'Vigilancia',
      'alto': 'Alto',
      'medio': 'Medio',
      'advertencia_sensor': 'Sensor',
    };
    return ListenableBuilder(
      listenable: widget.live,
      builder: (context, _) {
        final events = widget.live.events;
        // Alertas + minutos normales y en vigilancia (el servidor manda pocos y
        // ya resumidos) en una sola línea de tiempo, del más reciente al más antiguo.
        final normales = [for (final n in widget.live.normales) {...n, 'risk_level': 'normal'}];
        final vigilancias = [for (final v in widget.live.vigilancias) {...v, 'risk_level': 'vigilancia'}];
        final all = [...events, ...vigilancias, ...normales]
          ..sort((a, b) {
            final ta = parseTs(a['timestamp']), tb = parseTs(b['timestamp']);
            if (ta == null || tb == null) return 0;
            return tb.compareTo(ta);
          });
        final list = all.where((e) => _filter == 'all' || e['risk_level'] == _filter).toList();
        return Column(
          children: [
            SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                children: [
                  for (final f in filters.entries)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(f.value),
                        selected: _filter == f.key,
                        onSelected: (_) => setState(() => _filter = f.key),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: list.isEmpty
                  ? EmptyState(
                      all.isEmpty
                          ? 'Todavía no hay lecturas de esta sesión.'
                          : _filter == 'normal'
                          ? 'No hay minutos normales en las últimas 24 h.'
                          : _filter == 'vigilancia'
                          ? 'No hay minutos en vigilancia en las últimas 24 h.'
                          : 'No hay episodios con este filtro. ¡Buen viaje!',
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
                      itemCount: list.length,
                      itemBuilder: (context, i) => switch (list[i]['risk_level']) {
                        'normal' => MinuteTile(minute: list[i], color: C.verde, icon: Icons.check_circle_outline, label: 'Normal'),
                        'vigilancia' => MinuteTile(minute: list[i], color: kWatch.color, icon: kWatch.icon, label: kWatch.label),
                        _ => EventTile(event: list[i], fresh: widget.live.freshIds.contains(list[i]['id'])),
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// Un minuto sin episodio (normal o en vigilancia): fila compacta con EAR y BPM medios.
class MinuteTile extends StatelessWidget {
  const MinuteTile({super.key, required this.minute, required this.color, required this.icon, required this.label});
  final Map<String, dynamic> minute;
  final Color color;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final m = minute;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w700)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'EAR ${m['ear'] != null ? fmt(m['ear'], 3) : '—'} · BPM ${m['bpm'] != null ? fmt(m['bpm'], 0) : '—'}',
              style: const TextStyle(fontSize: 12, color: C.muted),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(clockFull(m['timestamp']), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class EventTile extends StatelessWidget {
  const EventTile({super.key, required this.event, this.fresh = false});
  final Map<String, dynamic> event;
  final bool fresh;

  @override
  Widget build(BuildContext context) {
    final e = event;
    final r = riskStyle(e['risk_level'] as String?);
    final escalada = (e['detail'] as String? ?? '').startsWith('Escalada');
    final vis = e['visual_signal'] == true || e['visual_signal'] == 1;
    final fis = e['physiological_signal'] == true || e['physiological_signal'] == 1;

    Widget tag(String t, bool on) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: on ? r.color.withValues(alpha: 0.15) : C.cardHi,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(t, style: TextStyle(fontSize: 11, color: on ? r.color : C.muted)),
    );

    // Flutter no admite bordes redondeados con colores distintos por lado: la
    // franja de color va como una caja aparte dentro de la tarjeta recortada.
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: fresh ? r.color.withValues(alpha: 0.10) : C.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: C.border),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 4, color: r.color),
            Expanded(
              child: Padding(padding: const EdgeInsets.all(12), child: _body(e, r, escalada, vis, fis, tag)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(
    Map<String, dynamic> e,
    RiskStyle r,
    bool escalada,
    bool vis,
    bool fis,
    Widget Function(String, bool) tag,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(r.icon, color: r.color),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 6,
                children: [
                  Pill(r.label, color: r.color),
                  if (escalada) const Pill('↑ escalada', color: C.rojo),
                ],
              ),
              const SizedBox(height: 6),
              Text(e['detail']?.toString() ?? ''),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  tag('visual ${vis ? '✓' : '—'}', vis),
                  tag('fisiológica ${fis ? '✓' : '—'}', fis),
                  tag('BPM ${e['bpm'] ?? '—'}', false),
                  tag('EAR ${e['ear'] != null ? fmt(e['ear'], 3) : '—'}', false),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(relTime(e['timestamp']), style: const TextStyle(color: C.muted, fontSize: 11)),
            Text(clockFull(e['timestamp']), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
          ],
        ),
      ],
    );
  }
}
