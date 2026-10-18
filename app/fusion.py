"""
Lógica de fusión multimodal para SIDFAM (RF05, RF06, RF07).

RF05: un episodio de fatiga REAL exige evidencia en AMBOS canales al
mismo tiempo. Por eso un `FatigueEvent` con status "alerta" solo se
genera cuando hay señal visual (ojos/bostezo/cabeceo) Y señal
fisiológica de somnolencia (caída relativa del pulso respecto al
basal; la baja variabilidad solo refuerza) frescas simultáneamente.

  - Solo un canal activo            -> status "vigilancia" (no confirmado)
  - Ambos canales activos           -> status "alerta"; risk_level según
                                       cuántas razones concretas se
                                       acumularon (2 -> "medio", 3+ -> "alto")
  - Lectura de pulso implausible    -> status/risk_level
                                       "advertencia_sensor" (revisar el
                                       sensor, NO es fatiga del usuario)

Se mantiene un estado por "session_id" (por defecto una sola sesión,
ya que el prototipo inicial es de un solo usuario). Esto deja abierta
la extensión a múltiples usuarios/dispositivos en el futuro (RNF05).
"""

from dataclasses import dataclass, field
import time

from .vision import VisionResult
from .pulse import PulseResult

EYES_CLOSED_SUSTAIN_SECONDS = 2.0   # cuánto tiempo sostenido de ojos cerrados cuenta como señal
HEAD_TILT_SUSTAIN_SECONDS = 2.0
SIGNAL_FRESHNESS_SECONDS = 10       # antigüedad máxima de una señal para que cuente en la fusión


@dataclass
class _SessionState:
    eyes_closed_since: float | None = None
    head_tilted_since: float | None = None
    last_vision: VisionResult | None = None
    last_pulse: PulseResult | None = None
    last_vision_timestamp: float | None = None
    last_pulse_timestamp: float | None = None
    # Control de "un evento por episodio": se abre al empezar un episodio y
    # no se vuelve a guardar hasta que la condición cesa y vuelve a darse.
    in_fatigue_episode: bool = False
    in_sensor_warning_episode: bool = False
    fatigue_episode_risk: str | None = None   # risk_level con el que se abrió el episodio en curso


@dataclass
class FatigueEvent:
    session_id: str
    timestamp: float
    risk_level: str          # "medio" | "alto" | "advertencia_sensor"
    visual_signal: bool
    physiological_signal: bool
    detail: str
    bpm: float | None = None
    ear: float | None = None
    sensor_warning: bool = False


class FusionEngine:
    def __init__(self):
        self._sessions: dict[str, _SessionState] = {}

    def _state(self, session_id: str) -> _SessionState:
        if session_id not in self._sessions:
            self._sessions[session_id] = _SessionState()
        return self._sessions[session_id]

    def update_vision(self, session_id: str, result: VisionResult) -> FatigueEvent | None:
        state = self._state(session_id)
        now = time.time()
        state.last_vision = result
        state.last_vision_timestamp = now

        if result.face_detected and result.eyes_closed:
            if state.eyes_closed_since is None:
                state.eyes_closed_since = now
        else:
            state.eyes_closed_since = None

        if result.face_detected and result.head_tilted:
            if state.head_tilted_since is None:
                state.head_tilted_since = now
        else:
            state.head_tilted_since = None

        return self._evaluate(session_id)

    def update_pulse(self, session_id: str, result: PulseResult) -> FatigueEvent | None:
        state = self._state(session_id)
        state.last_pulse = result
        state.last_pulse_timestamp = time.time()
        return self._evaluate(session_id)

    @staticmethod
    def _risk_from_reasons(n_reasons: int) -> str:
        """2 razones -> "medio"; 3 o más -> "alto".

        Como para entrar en "alerta" se exige al menos 1 razón visual y 1
        fisiológica, el mínimo real es 2 y no existe un "bajo" aquí.
        """
        return "alto" if n_reasons >= 3 else "medio"

    def _derive_status(self, visual_signal: bool, physiological_signal: bool,
                       reasons: list[str], implausible: bool) -> tuple[str, str | None]:
        """Estado actual (mismo criterio para el dashboard y para _evaluate)."""
        if implausible:
            return "advertencia_sensor", None
        if visual_signal and physiological_signal:
            return "alerta", self._risk_from_reasons(len(reasons))
        if visual_signal or physiological_signal:
            return "vigilancia", None
        return "normal", None

    def _analyze(self, state: _SessionState, now: float):
        """Aplica las reglas de umbral + tiempo sostenido usando SOLO las
        señales frescas (dentro de SIGNAL_FRESHNESS_SECONDS).

        Devuelve (visual_signal, physiological_signal, reasons, implausible_reading).
        No guarda nada ni construye eventos: lo reutilizan _evaluate()
        (para decidir si hay evento) y get_current_status() (para el
        estado en tiempo real del dashboard).
        """
        vision_fresh = (
            state.last_vision_timestamp is not None
            and (now - state.last_vision_timestamp) <= SIGNAL_FRESHNESS_SECONDS
        )
        pulse_fresh = (
            state.last_pulse_timestamp is not None
            and (now - state.last_pulse_timestamp) <= SIGNAL_FRESHNESS_SECONDS
        )

        vision = state.last_vision if vision_fresh else None
        pulse = state.last_pulse if pulse_fresh else None

        visual_signal = False
        reasons: list[str] = []

        if vision and vision.face_detected:
            if state.eyes_closed_since and (now - state.eyes_closed_since) >= EYES_CLOSED_SUSTAIN_SECONDS:
                visual_signal = True
                reasons.append("ojos cerrados sostenido")
            if vision.yawning:
                visual_signal = True
                reasons.append("bostezo detectado")
            if state.head_tilted_since and (now - state.head_tilted_since) >= HEAD_TILT_SUSTAIN_SECONDS:
                visual_signal = True
                reasons.append("cabeceo sostenido")

        physiological_signal = False
        if pulse and pulse.has_enough_data and pulse.relative_drop_signal:
            physiological_signal = True
            reasons.append("caída sostenida del pulso respecto al basal")
            # La baja variabilidad solo refuerza (sube el riesgo), no dispara sola
            if pulse.low_variability:
                reasons.append("baja variabilidad de pulso sostenida")

        implausible_reading = bool(pulse and pulse.implausible_reading)

        return visual_signal, physiological_signal, reasons, implausible_reading

    def _evaluate(self, session_id: str) -> FatigueEvent | None:
        """Decide si hay que GUARDAR un evento nuevo. El estado actual en vivo
        (get_current_status) reporta la condición todo el tiempo que dure; aquí
        en cambio se registra UNA fila por episodio: al inicio, y solo otra vez
        si el riesgo escala de "medio" a "alto" dentro del mismo episodio.
        """
        state = self._state(session_id)
        now = time.time()

        visual_signal, physiological_signal, reasons, implausible = self._analyze(state, now)
        status, risk_level = self._derive_status(
            visual_signal, physiological_signal, reasons, implausible
        )

        bpm = state.last_pulse.bpm_current if state.last_pulse else None
        ear = state.last_vision.ear if state.last_vision else None

        # --- Episodio de advertencia de sensor (independiente) ---
        if status == "advertencia_sensor":
            # cualquier episodio de fatiga que estuviera abierto se cierra
            state.in_fatigue_episode = False
            state.fatigue_episode_risk = None
            if state.in_sensor_warning_episode:
                return None
            state.in_sensor_warning_episode = True
            return FatigueEvent(
                session_id=session_id,
                timestamp=now,
                risk_level="advertencia_sensor",
                visual_signal=visual_signal,
                physiological_signal=physiological_signal,
                detail="lectura de pulso fuera de rango fisiológico plausible (posible error de sensor)",
                bpm=bpm,
                ear=ear,
                sensor_warning=True,
            )

        state.in_sensor_warning_episode = False

        # --- Episodio de fatiga (RF05: ambas señales frescas a la vez) ---
        if status == "alerta":
            if not state.in_fatigue_episode:
                # inicio de un episodio nuevo
                state.in_fatigue_episode = True
                state.fatigue_episode_risk = risk_level
                return FatigueEvent(
                    session_id=session_id,
                    timestamp=now,
                    risk_level=risk_level,
                    visual_signal=visual_signal,
                    physiological_signal=physiological_signal,
                    detail=", ".join(reasons),
                    bpm=bpm,
                    ear=ear,
                )
            if state.fatigue_episode_risk == "medio" and risk_level == "alto":
                # escalada dentro del mismo episodio: se registra una vez
                state.fatigue_episode_risk = "alto"
                return FatigueEvent(
                    session_id=session_id,
                    timestamp=now,
                    risk_level="alto",
                    visual_signal=visual_signal,
                    physiological_signal=physiological_signal,
                    detail="Escalada: " + ", ".join(reasons),
                    bpm=bpm,
                    ear=ear,
                )
            return None

        # el estado ya no es "alerta": el episodio se cierra
        state.in_fatigue_episode = False
        state.fatigue_episode_risk = None
        return None

    def get_current_status(self, session_id: str) -> dict:
        """Estado en tiempo real para el dashboard (RF09, RF10).

        Reutiliza la misma lógica de fusión que _evaluate() pero sin
        persistir ni exigir que exista un evento. A diferencia de la
        fusión, aquí se devuelve SIEMPRE el último ear/bpm conocido
        (fresco o no) para que el usuario vea qué está leyendo el
        sistema, junto con data_is_fresh para saber si es reciente.
        """
        state = self._state(session_id)
        now = time.time()

        visual_signal, physiological_signal, reasons, implausible = self._analyze(state, now)
        status, risk_level = self._derive_status(
            visual_signal, physiological_signal, reasons, implausible
        )

        timestamps = [
            ts for ts in (state.last_vision_timestamp, state.last_pulse_timestamp)
            if ts is not None
        ]
        has_any_data = bool(timestamps)
        data_is_fresh = has_any_data and (now - max(timestamps)) <= SIGNAL_FRESHNESS_SECONDS

        vision = state.last_vision
        pulse = state.last_pulse

        return {
            "status": status,
            "risk_level": risk_level,
            "visual_signal": visual_signal,
            "physiological_signal": physiological_signal,
            "implausible_reading": implausible,
            "detail": ", ".join(reasons),
            "ear": vision.ear if vision else None,
            "bpm": pulse.bpm_current if pulse else None,
            "baseline_bpm": pulse.baseline_bpm if pulse else None,
            "data_is_fresh": data_is_fresh,
            "has_any_data": has_any_data,
            # Detalle por canal para las tarjetas del dashboard (último valor conocido)
            "face_detected": vision.face_detected if vision else None,
            "mar": vision.mar if vision else None,
            "head_tilt_deg": vision.head_tilt_deg if vision else None,
            "eyes_closed": vision.eyes_closed if vision else False,
            "yawning": vision.yawning if vision else False,
            "head_tilted": vision.head_tilted if vision else False,
            "bpm_mean": pulse.bpm_mean if pulse else None,
            "bpm_std": pulse.bpm_std if pulse else None,
        }


# Instancia única reutilizada por toda la app (ver app/main.py)
fusion_engine = FusionEngine()
