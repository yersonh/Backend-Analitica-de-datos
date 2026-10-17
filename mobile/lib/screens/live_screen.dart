// Panel en vivo: equivale a la parte superior del dashboard web (RF09, RF10).

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../live_controller.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/common.dart';
import '../widgets/live_widgets.dart';

class LiveScreen extends StatelessWidget {
  const LiveScreen({super.key, required this.live});
  final LiveController live;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return ListenableBuilder(
      listenable: live,
      builder: (context, _) {
        final s = live.status ?? const <String, dynamic>{};
        final key = statusKey(live.status);
        final st = kStates[key]!;
        return RefreshIndicator(
          onRefresh: () async => live.start(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
            children: [
              if (live.error != null)
                GlassCard(
                  accent: C.rojo,
                  child: Text(live.error!, style: const TextStyle(color: C.rojo)),
                ),
              _Hero(s: s, st: st, keyName: key),
              _PulseCard(s: s, app: app),
              _FusionCard(s: s, st: st, keyName: key),
              _MetersCard(s: s, app: app),
              GlassCard(
                title: 'Tendencia de apertura ocular (EAR)',
                icon: Icons.show_chart,
                child: TrendChart(
                  data: live.earHist,
                  color: C.cyan,
                  unit: 'EAR',
                  dec: 2,
                  min: 0,
                  max: 0.4,
                  ref: app.thr('ear'),
                  refColor: C.rojo,
                  refLabel: 'umbral ${app.thr('ear')}',
                ),
              ),
              GlassCard(
                title: 'Tendencia de pulso (BPM)',
                icon: Icons.monitor_heart_outlined,
                child: TrendChart(
                  data: live.bpmHist,
                  color: C.rojo,
                  unit: 'BPM',
                  dec: 0,
                  min: 50,
                  max: 110,
                  auto: true,
                  ref: asDouble(s['baseline_bpm']),
                  refColor: const Color(0xFFB4C3DF),
                  refLabel: s['baseline_bpm'] != null ? 'basal ${asDouble(s['baseline_bpm'])!.round()}' : '',
                ),
              ),
              _Kpis(live: live),
              GlassCard(
                title: 'Distribución por nivel',
                icon: Icons.donut_large,
                child: RiskDonut(counts: live.counts),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.s, required this.st, required this.keyName});
  final Map<String, dynamic> s;
  final StatusStyle st;
  final String keyName;

  @override
  Widget build(BuildContext context) {
    final reasons = ((s['detail'] as String?) ?? '').split(', ').where((r) => r.isNotEmpty).toList();
    final ear = asDouble(s['ear']);
    final bpm = asDouble(s['bpm']);
    final base = asDouble(s['baseline_bpm']);
    final visual = s['visual_signal'] == true, fisio = s['physiological_signal'] == true;
    final noFace = s['face_detected'] == false;
    var open = 1.0;
    if (s['eyes_closed'] == true) {
      open = 0.08;
    } else if (ear != null) {
      open = (ear / 0.32).clamp(0.15, 1.05);
    }
    final tag = noFace
        ? 'BUSCANDO ROSTRO…'
        : (ear != null ? 'APERTURA ${((ear / 0.32).clamp(0.0, 1.0) * 100).round()}%' : 'APERTURA —');

    return GlassCard(
      accent: st.accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('ESTADO ACTUAL', style: TextStyle(color: st.accent, fontSize: 11, letterSpacing: 1.2)),
                    const SizedBox(height: 4),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      child: Text(
                        st.title,
                        key: ValueKey(keyName),
                        style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: st.accent),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(st.desc, style: const TextStyle(color: C.muted)),
                    if (s['saved'] == true) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: st.accent.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(99),
                          border: Border.all(color: st.accent.withValues(alpha: 0.4)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.history, size: 14, color: st.accent),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                'Recibida ${agoSeconds(s['saved_age'])}',
                                style: TextStyle(color: st.accent, fontSize: 12, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Column(
                children: [
                  EyeIndicator(open: open, color: st.accent, searching: noFace),
                  const SizedBox(height: 4),
                  Text(tag, style: TextStyle(color: st.accent, fontSize: 10, letterSpacing: 1)),
                ],
              ),
            ],
          ),
          if (reasons.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 6, runSpacing: 6, children: [for (final r in reasons) Pill(r, color: st.accent)]),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              _Channel(
                k: 'Canal visual',
                v: fmt(ear, 3),
                sub: visual ? 'Señal de fatiga' : (ear != null ? 'Sin indicios' : 'Sin lectura'),
                on: visual,
                accent: st.accent,
              ),
              const SizedBox(width: 8),
              _Channel(
                k: 'Canal fisiológico',
                v: fmt(bpm, 0),
                sub: fisio ? 'Señal de somnolencia' : (bpm != null ? 'Sin indicios' : 'Sin lectura'),
                on: fisio,
                accent: st.accent,
              ),
              const SizedBox(width: 8),
              _Channel(
                k: 'Basal personal',
                v: fmt(base, 0),
                sub: base != null ? 'Basal fijado' : 'Calibrando…',
                on: false,
                accent: st.accent,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Channel extends StatelessWidget {
  const _Channel({required this.k, required this.v, required this.sub, required this.on, required this.accent});
  final String k, v, sub;
  final bool on;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: on ? accent.withValues(alpha: 0.14) : C.cardHi,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: on ? accent : Colors.transparent),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(k, style: const TextStyle(color: C.muted, fontSize: 11)),
            Text(v, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            Text(sub, style: TextStyle(color: on ? accent : C.muted, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

class _PulseCard extends StatefulWidget {
  const _PulseCard({required this.s, required this.app});
  final Map<String, dynamic> s;
  final AppState app;

  @override
  State<_PulseCard> createState() => _PulseCardState();
}

class _PulseCardState extends State<_PulseCard> {
  // fase del latido (0..1) que publica el ECG: el corazón late con el mismo reloj
  // de ~30 fps en lugar de tener uno propio a 60 fps (eso calentaba el teléfono)
  final _phase = ValueNotifier<double>(0);

  @override
  void dispose() {
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    final bpm = asDouble(s['bpm']);
    final mean = asDouble(s['bpm_mean']);
    final base = asDouble(s['baseline_bpm']);
    final drop = (base != null && base != 0 && mean != null) ? (base - mean) / base : null;
    final implausible = s['implausible_reading'] == true;
    final fisio = s['physiological_signal'] == true;

    final (pillText, pillColor, pillIdle) = implausible
        ? ('Lectura inválida', C.rojo, false)
        : fisio
        ? ('Somnolencia', C.rojo, false)
        : bpm != null && s['saved'] == true
        ? ('Guardado', C.azul, false)
        : bpm != null
        ? ('Estable', C.verde, false)
        : ('Sin datos', C.gris, true);
    final ecgColor = implausible ? C.violeta : (fisio ? C.rojo : C.cyan);

    return GlassCard(
      title: 'Pulso cardíaco',
      icon: Icons.favorite_border,
      trailing: Pill(pillText, color: pillColor, idle: pillIdle),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              RepaintBoundary(
                child: ValueListenableBuilder<double>(
                  valueListenable: _phase,
                  builder: (context, p, child) {
                    // golpe en el pico R del trazo (fase ≈ 0.38); quieto si el ECG está detenido
                    final scale = 1 + (1 - ((p - 0.38).abs() / 0.12)).clamp(0.0, 1.0) * 0.18;
                    return Transform.scale(scale: scale, child: child);
                  },
                  child: const Icon(Icons.favorite, color: C.rojo, size: 40),
                ),
              ),
              const SizedBox(width: 14),
              TweenAnimationBuilder<double>(
                tween: Tween(end: bpm ?? 0),
                duration: const Duration(milliseconds: 600),
                builder: (context, v, _) => Text(
                  bpm == null ? '—' : v.round().toString(),
                  style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: 6),
              const Text('BPM', style: TextStyle(color: C.muted)),
              const Spacer(),
              Text(
                drop != null
                    ? 'Δ basal ${drop > 0 ? '−' : '+'}${(drop.abs() * 100).toStringAsFixed(1)} %'
                    : 'Δ basal —',
                style: TextStyle(
                  color: drop != null && drop >= widget.app.thr('relative_drop') ? C.rojo : C.muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          EcgView(bpm: s['data_is_fresh'] == true ? bpm : null, color: ecgColor, phase: _phase),
          const SizedBox(height: 10),
          Row(
            children: [
              _mini('Media 60s', fmt(mean, 1)),
              _mini('σ BPM', fmt(s['bpm_std'], 2)),
              _mini('Basal', fmt(base, 0)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _mini(String k, String v) => Expanded(
    child: Column(
      children: [
        Text(k, style: const TextStyle(color: C.muted, fontSize: 11)),
        Text(v, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
      ],
    ),
  );
}

class _FusionCard extends StatelessWidget {
  const _FusionCard({required this.s, required this.st, required this.keyName});
  final Map<String, dynamic> s;
  final StatusStyle st;
  final String keyName;

  @override
  Widget build(BuildContext context) {
    final vis = s['visual_signal'] == true, fis = s['physiological_signal'] == true;
    final has = s['has_any_data'] == true;
    final both = vis && fis;
    final out = s['saved'] == true
        ? 'EN ESPERA'
        : !has
        ? 'SIN DATOS'
        : keyName.startsWith('alerta')
        ? 'ALERTA ${(s['risk_level'] ?? '').toString().toUpperCase()}'
        : (s['status'] ?? '').toString().replaceAll('_', ' ').toUpperCase();
    final outSub = both ? 'FATIGA CONFIRMADA' : (vis || fis ? 'UN CANAL' : 'RESULTADO');

    Widget node(String title, String sub, bool on) => AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: on ? st.accent.withValues(alpha: 0.15) : C.cardHi,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: on ? st.accent : C.border),
      ),
      child: Column(
        children: [
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
          ),
          const SizedBox(height: 2),
          Text(
            sub,
            textAlign: TextAlign.center,
            style: const TextStyle(color: C.muted, fontSize: 9.5),
          ),
        ],
      ),
    );
    Widget arrow(bool on) =>
        Icon(Icons.arrow_forward_rounded, size: 18, color: on ? st.accent : C.muted.withValues(alpha: 0.4));

    return GlassCard(
      title: 'Motor de fusión multimodal',
      icon: Icons.hub_outlined,
      child: Column(
        children: [
          // entradas apiladas a la izquierda -> núcleo -> resultado
          Row(
            children: [
              Expanded(
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(child: node('VISUAL', 'EAR · MAR · CABEZA', vis)),
                        arrow(vis),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(child: node('FISIOLÓGICO', 'CAÍDA · VARIAB.', fis)),
                        arrow(fis),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(child: node('FUSIÓN', 'VISUAL ∧ FISIOLÓGICA', both || keyName == 'advertencia_sensor')),
              arrow(has),
              Expanded(child: node(out, outSub, has)),
            ],
          ),
          const SizedBox(height: 10),
          const Note(
            'Un evento de fatiga exige señal visual Y fisiológica al mismo tiempo (RF05). '
            'Con un solo canal el estado queda en vigilancia.',
          ),
        ],
      ),
    );
  }
}

class _MetersCard extends StatelessWidget {
  const _MetersCard({required this.s, required this.app});
  final Map<String, dynamic> s;
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final ear = app.thr('ear'), mar = app.thr('mar'), tilt = app.thr('head_tilt_deg');
    final drop = app.thr('relative_drop'), std = app.thr('low_variability_std');
    final base = asDouble(s['baseline_bpm']), mean = asDouble(s['bpm_mean']);
    final dropV = (base != null && base != 0 && mean != null)
        ? ((base - mean) / base).clamp(0.0, double.infinity)
        : null;
    final tiltV = asDouble(s['head_tilt_deg'])?.abs();

    final specs = <(MeterSpec, double?)>[
      (
        MeterSpec(
          name: 'Apertura ocular',
          hint: 'EAR',
          max: 0.4,
          thr: ear,
          isBad: (v) => v < ear,
          format: (v) => v.toStringAsFixed(3),
          thrLabel: 'cierre $ear',
        ),
        asDouble(s['ear']),
      ),
      (
        MeterSpec(
          name: 'Apertura bucal',
          hint: 'MAR · bostezo',
          max: 1,
          thr: mar,
          isBad: (v) => v > mar,
          format: (v) => v.toStringAsFixed(3),
          thrLabel: 'bostezo $mar',
        ),
        asDouble(s['mar']),
      ),
      (
        MeterSpec(
          name: 'Inclinación de cabeza',
          hint: 'grados',
          max: 45,
          thr: tilt,
          isBad: (v) => v > tilt,
          format: (v) => '${v.toStringAsFixed(1)}°',
          thrLabel: '${tilt.round()}°',
        ),
        tiltV,
      ),
      (
        MeterSpec(
          name: 'Caída vs. basal',
          hint: 'media 60s',
          max: 0.2,
          thr: drop,
          isBad: (v) => v >= drop,
          format: (v) => '${(v * 100).toStringAsFixed(1)} %',
          thrLabel: '${(drop * 100).round()} %',
        ),
        dropV,
      ),
      (
        MeterSpec(
          name: 'Variabilidad',
          hint: 'σ BPM',
          max: 8,
          thr: std,
          isBad: (v) => v < std,
          format: (v) => v.toStringAsFixed(2),
          thrLabel: 'σ $std',
        ),
        asDouble(s['bpm_std']),
      ),
    ];
    return GlassCard(
      title: 'Métricas por canal vs. umbral',
      icon: Icons.tune,
      child: Column(
        children: [for (final (spec, v) in specs) MeterBar(spec: spec, value: v)],
      ),
    );
  }
}

class _Kpis extends StatelessWidget {
  const _Kpis({required this.live});
  final LiveController live;

  @override
  Widget build(BuildContext context) {
    int c(String k) => (live.counts[k] as num?)?.toInt() ?? 0;
    final normal = (live.status?['normal_count'] as num?)?.toInt() ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: KpiGrid(
        minWidth: 120,
        children: [
          KpiTile(label: 'Lecturas normales', value: '$normal', color: C.verde),
          KpiTile(label: 'Riesgo alto', value: '${c('alto')}', color: C.rojo),
          KpiTile(label: 'Riesgo medio', value: '${c('medio')}', color: C.ambar),
          KpiTile(label: 'Adv. sensor', value: '${c('advertencia_sensor')}', color: C.violeta),
          KpiTile(label: 'Total eventos', value: '${c('alto') + c('medio') + c('advertencia_sensor')}', color: C.cyan),
        ],
      ),
    );
  }
}
