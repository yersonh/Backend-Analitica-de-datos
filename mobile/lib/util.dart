// Formateo y textos compartidos (copiados del JS del panel web).

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'theme.dart';

double? asDouble(dynamic v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);

String fmt(dynamic v, [int d = 2]) {
  final x = asDouble(v);
  return (x == null || x.isNaN) ? '—' : x.toStringAsFixed(d);
}

/// Número con separadores es-CO y hasta [d] decimales (como `n()` del web).
String n(dynamic v, [int d = 2]) {
  final x = asDouble(v);
  if (x == null) return '—';
  final f = NumberFormat.decimalPattern('es')
    ..maximumFractionDigits = d
    ..minimumFractionDigits = 0;
  return f.format(x);
}

String pct(dynamic v) => asDouble(v) == null ? '—' : '${n(asDouble(v)! * 100, 1)} %';

DateTime? parseTs(dynamic ts) => ts is String ? DateTime.tryParse(ts)?.toLocal() : null;

String relTime(dynamic ts) {
  final d = parseTs(ts);
  if (d == null) return '';
  final s = DateTime.now().difference(d).inSeconds;
  if (s < 60) return 'hace ${s < 0 ? 0 : s} s';
  if (s < 3600) return 'hace ${(s / 60).round()} min';
  if (s < 86400) return 'hace ${(s / 3600).round()} h';
  return 'hace ${(s / 86400).round()} d';
}

/// "hace X" a partir de una antigüedad en segundos.
String agoSeconds(dynamic secs) {
  final s = asDouble(secs)?.round();
  if (s == null) return '';
  if (s < 60) return 'hace $s s';
  if (s < 3600) return 'hace ${(s / 60).round()} min';
  if (s < 86400) return 'hace ${(s / 3600).round()} h';
  return 'hace ${(s / 86400).round()} d';
}

String clockFull(dynamic ts) {
  final d = parseTs(ts);
  return d == null ? (ts?.toString() ?? '') : DateFormat('dd MMM HH:mm:ss', 'es').format(d);
}

String hms(DateTime t) => DateFormat('HH:mm:ss').format(t);

class StatusStyle {
  const StatusStyle(this.accent, this.title, this.desc);
  final Color accent;
  final String title;
  final String desc;
}

const kStates = <String, StatusStyle>{
  'normal': StatusStyle(
    C.esmeralda,
    'Alerta y despierto',
    'Sin señales de fatiga. Ambos canales dentro de rango normal.',
  ),
  'vigilancia': StatusStyle(C.cyan, 'En vigilancia', 'Un solo canal muestra indicios. Aún no se confirma como fatiga.'),
  'alerta-medio': StatusStyle(
    C.naranja,
    'Fatiga detectada',
    'Señal visual y fisiológica simultáneas. Se recomienda una pausa.',
  ),
  'alerta-alto': StatusStyle(
    C.rojo,
    '¡Riesgo alto!',
    'Múltiples señales sostenidas de fatiga. Intervención inmediata recomendada.',
  ),
  'advertencia_sensor': StatusStyle(
    C.violeta,
    'Revisar sensor',
    'Lectura de pulso fuera de rango fisiológico. Posible problema del sensor, no del conductor.',
  ),
  'guardada': StatusStyle(
    C.azul,
    'Última lectura',
    'Sin datos en vivo por ahora: se muestra lo último que recibió el sistema. Se actualiza solo en cuanto lleguen lecturas.',
  ),
  'sindatos': StatusStyle(
    C.gris,
    'Esperando datos',
    'El sistema aún no ha recibido lecturas de los dispositivos para esta sesión.',
  ),
};

/// Clave de [kStates] para un estado de /estado.
String statusKey(Map<String, dynamic>? s) {
  if (s?['saved'] == true) return 'guardada';
  if (s == null || s['has_any_data'] != true) return 'sindatos';
  final st = s['status'];
  if (st == 'advertencia_sensor') return 'advertencia_sensor';
  if (st == 'alerta') return 'alerta-${s['risk_level'] ?? 'medio'}';
  if (st == 'vigilancia') return 'vigilancia';
  return 'normal';
}

/// Si el servidor no tiene datos en memoria (p. ej. recién reiniciado) pero
/// envía `ultima_guardada`, arma el estado con esas lecturas de la base y lo
/// marca con `saved` / `saved_at`. Con datos en vivo devuelve [s] tal cual.
Map<String, dynamic>? withSaved(Map<String, dynamic>? s) {
  final g = s?['ultima_guardada'];
  if (s == null || s['has_any_data'] == true || g is! Map) return s;
  final f = g['frame'] is Map ? (g['frame'] as Map).cast<String, dynamic>() : null;
  final p = g['pulso'] is Map ? (g['pulso'] as Map).cast<String, dynamic>() : null;
  if (f == null && p == null) return s;
  // age_seconds lo calcula el servidor (sus horas no traen zona horaria)
  num age(Map<String, dynamic>? r) => (r?['age_seconds'] as num?) ?? double.infinity;
  final last = (f != null && age(f) < age(p)) ? f : (p ?? f!);
  bool? b(dynamic v) => v == null ? null : (v == true || v == 1);
  return {
    ...s,
    'saved': true,
    'saved_age': last['age_seconds'],
    'ear': f?['ear'],
    'mar': f?['mar'],
    'head_tilt_deg': f?['head_tilt_deg'],
    'face_detected': b(f?['face_detected']),
    'eyes_closed': b(f?['eyes_closed']) ?? false,
    'yawning': b(f?['yawning']) ?? false,
    'head_tilted': b(f?['head_tilted']) ?? false,
    'bpm': p?['bpm'],
    'bpm_mean': p?['bpm_mean'],
    'bpm_std': p?['bpm_std'],
    'baseline_bpm': p?['baseline_bpm'],
    'implausible_reading': b(p?['implausible_reading']) ?? false,
    'data_is_fresh': false,
  };
}

class RiskStyle {
  const RiskStyle(this.color, this.label, this.icon);
  final Color color;
  final String label;
  final IconData icon;
}

const kRisk = <String, RiskStyle>{
  'alto': RiskStyle(C.rojo, 'Riesgo alto', Icons.warning_amber_rounded),
  'medio': RiskStyle(C.ambar, 'Riesgo medio', Icons.visibility_outlined),
  'advertencia_sensor': RiskStyle(C.violeta, 'Sensor', Icons.sensors),
};

RiskStyle riskStyle(String? r) => kRisk[r] ?? RiskStyle(C.gris, r ?? '—', Icons.info_outline);

const kKss = <int, String>{
  1: 'Extremadamente alerta',
  2: 'Muy alerta',
  3: 'Alerta',
  4: 'Bastante alerta',
  5: 'Ni alerta ni somnoliento',
  6: 'Algunos signos de sueño',
  7: 'Somnoliento, sin esfuerzo para seguir despierto',
  8: 'Somnoliento, con esfuerzo para seguir despierto',
  9: 'Muy somnoliento, luchando contra el sueño',
};
