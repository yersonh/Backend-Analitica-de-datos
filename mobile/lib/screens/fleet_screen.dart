// Flota: la pantalla principal del supervisor. Todos los conductores en una
// lista, lo más urgente primero, con su estado, pulso, apertura ocular,
// antigüedad de la última lectura y episodios de hoy. Tocar uno abre su panel.

import 'package:flutter/material.dart';

import '../fleet_controller.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/common.dart';

class FleetScreen extends StatelessWidget {
  const FleetScreen({super.key, required this.fleet, required this.onOpen});
  final FleetController fleet;

  /// Abre el panel en vivo de esa sesión.
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: fleet,
      builder: (context, _) {
        final drivers = fleet.drivers;
        return RefreshIndicator(
          onRefresh: fleet.refresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
            children: [
              if (fleet.error != null)
                GlassCard(
                  accent: C.rojo,
                  child: Text(fleet.error!, style: const TextStyle(color: C.rojo)),
                ),
              _Summary(summary: fleet.summary, total: drivers.length),
              if (!fleet.loaded && fleet.error == null)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (drivers.isEmpty)
                const GlassCard(
                  child: EmptyState(
                    'Aún no hay conductores.\nCrea usuarios con rol Conductor y asígnales un session_id '
                    '(el mismo que envían sus ESP32).',
                    icon: Icons.groups_2_outlined,
                  ),
                )
              else
                for (final d in drivers)
                  _DriverCard(key: ValueKey(d['session_id']), d: d, onTap: () => onOpen(d['session_id'] as String)),
            ],
          ),
        );
      },
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.summary, required this.total});
  final Map<String, dynamic> summary;
  final int total;

  int _n(String k) => (summary[k] as num?)?.toInt() ?? 0;

  @override
  Widget build(BuildContext context) {
    final alerta = _n('alerta-alto') + _n('alerta-medio');
    final headline = alerta > 0
        ? '$alerta ${alerta == 1 ? 'conductor necesita' : 'conductores necesitan'} atención'
        : _n('vigilancia') > 0
        ? 'Sin fatiga confirmada, ${_n('vigilancia')} en vigilancia'
        : total == 0
        ? 'Sin conductores registrados'
        : 'Toda la flota sin señales de fatiga';
    final color = alerta > 0 ? C.rojo : (_n('vigilancia') > 0 ? C.cyan : C.esmeralda);
    return GlassCard(
      accent: alerta > 0 ? C.rojo : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'FLOTA · $total ${total == 1 ? 'CONDUCTOR' : 'CONDUCTORES'}',
            style: const TextStyle(color: C.muted, fontSize: 11, letterSpacing: 1.2),
          ),
          const SizedBox(height: 4),
          Text(
            headline,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: color),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _Stat('Alerta', alerta, C.rojo),
              _Stat('Vigilancia', _n('vigilancia'), C.cyan),
              _Stat('Sensor', _n('advertencia_sensor'), C.violeta),
              _Stat('Normal', _n('normal'), C.esmeralda),
              _Stat('Sin señal', _n('sindatos'), C.gris),
            ],
          ),
          const SizedBox(height: 10),
          const Note('Toca un conductor para ver su panel en vivo. Se actualiza cada 3 s.'),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.n, this.color);
  final String label;
  final int n;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final on = n > 0;
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 3),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: on ? color.withValues(alpha: 0.14) : C.cardHi.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: on ? color.withValues(alpha: 0.45) : C.border),
        ),
        child: Column(
          children: [
            Text(
              '$n',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: on ? color : C.muted),
            ),
            FittedBox(
              child: Text(label, style: TextStyle(fontSize: 11, color: on ? color : C.muted)),
            ),
          ],
        ),
      ),
    );
  }
}

class _DriverCard extends StatelessWidget {
  const _DriverCard({super.key, required this.d, required this.onTap});
  final Map<String, dynamic> d;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final estado = d['estado'] as String? ?? 'sindatos';
    final st = kStates[estado] ?? kStates['sindatos']!;
    final name = (d['conductor'] as String?) ?? 'Sin conductor asignado';
    final sid = d['session_id'] as String;
    final live = d['en_vivo'] == true;
    final edad = d['ultima_lectura_seg'];
    final lecturas = (d['lecturas'] as num?)?.toInt() ?? 0;
    final urgent = estado.startsWith('alerta') || estado == 'advertencia_sensor';
    final bpm = asDouble(d['bpm']);
    final ear = asDouble(d['ear']);
    final hoy = ((d['eventos_hoy'] as Map?) ?? const {}).cast<String, dynamic>();
    final altos = (hoy['alto'] as num?)?.toInt() ?? 0;
    final medios = (hoy['medio'] as num?)?.toInt() ?? 0;
    final detail = (d['detail'] as String?) ?? '';
    final title = estado == 'sindatos' ? (lecturas == 0 ? 'Aún sin datos' : 'Sin señal') : st.title;
    // iniciales tomando solo letras ("Lauren (conductor)" -> "LC", no "L(")
    final words = RegExp(r'\p{L}+', unicode: true).allMatches(name).map((m) => m[0]!).toList();
    final initials = words.isEmpty ? '?' : words.take(2).map((w) => w[0]).join().toUpperCase();

    return GlassCard(
      accent: urgent ? st.accent : null,
      padding: EdgeInsets.zero,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: st.accent.withValues(alpha: 0.16),
                        border: Border.all(color: st.accent, width: 2),
                      ),
                      child: Text(
                        initials,
                        style: TextStyle(color: st.accent, fontWeight: FontWeight.w800),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              if (live) ...[
                                Container(
                                  width: 7,
                                  height: 7,
                                  decoration: const BoxDecoration(color: C.verde, shape: BoxShape.circle),
                                ),
                                const SizedBox(width: 5),
                              ],
                              Flexible(
                                child: Text(
                                  live
                                      ? 'En vivo · $sid'
                                      : (edad != null ? 'Última lectura ${agoSeconds(edad)} · $sid' : sid),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: live ? C.verde : C.muted, fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Pill(title, color: st.accent, idle: estado == 'sindatos'),
                  ],
                ),
                if (urgent && detail.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(detail, style: TextStyle(color: st.accent, fontSize: 13)),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    _Metric(Icons.favorite, bpm != null ? '${bpm.round()} BPM' : '— BPM', C.rojo),
                    _Metric(
                      Icons.visibility_outlined,
                      ear != null ? 'Ojos ${((ear / 0.32).clamp(0.0, 1.0) * 100).round()}%' : 'Ojos —',
                      C.cyan,
                    ),
                    _Metric(
                      Icons.warning_amber_rounded,
                      altos + medios == 0 ? 'Hoy sin episodios' : 'Hoy: $altos alto · $medios medio',
                      altos > 0 ? C.rojo : (medios > 0 ? C.ambar : C.muted),
                      flex: 2,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric(this.icon, this.text, this.color, {this.flex = 1});
  final IconData icon;
  final String text;
  final Color color;
  final int flex;

  @override
  Widget build(BuildContext context) => Expanded(
    flex: flex,
    child: Row(
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: C.text, fontSize: 12.5),
          ),
        ),
      ],
    ),
  );
}
