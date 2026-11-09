"""Reglas de fusión RF05-RF07, microsueño y calibración visual (app/fusion.py)."""

from app import fusion
from app.fusion import FusionEngine
from app.pulse import PulseResult
from app.vision import VisionResult

S = "s1"


def face(ear=0.30, mar=0.2, tilt=0.0, pitch=0.45, closed=None, yawning=None, tilted=None):
    """VisionResult con flags de umbral fijo, como los devuelve vision.py."""
    from app import vision
    return VisionResult(
        face_detected=True, ear=ear, mar=mar, head_tilt_deg=tilt, pitch_ratio=pitch,
        eyes_closed=ear < vision.EAR_THRESHOLD if closed is None else closed,
        yawning=mar > vision.MAR_THRESHOLD if yawning is None else yawning,
        head_tilted=abs(tilt) > vision.HEAD_TILT_THRESHOLD_DEG if tilted is None else tilted,
    )


def pulse(drop=False, low_var=False, implausible=False, bpm=70.0):
    return PulseResult(has_enough_data=True, bpm_current=bpm, baseline_bpm=75.0,
                       relative_drop_signal=drop, low_variability=low_var,
                       implausible_reading=implausible)


def frames(engine, clock, vision_result, seconds, step=0.33):
    """Envía el mismo frame durante `seconds`; devuelve los eventos generados."""
    events = []
    t = 0.0
    while t <= seconds:
        e = engine.update_vision(S, vision_result)
        if e:
            events.append(e)
        clock.advance(step)
        t += step
    return events


def test_ojos_cerrados_poco_tiempo_es_normal(clock):
    f = FusionEngine()
    frames(f, clock, face(ear=0.15), 1.5)
    assert f.get_current_status(S)["status"] == "normal"


def test_solo_vision_es_vigilancia_sin_evento(clock):
    f = FusionEngine()
    events = frames(f, clock, face(ear=0.15), 2.5)
    st = f.get_current_status(S)
    assert st["status"] == "vigilancia"
    assert events == []


def test_solo_pulso_es_vigilancia(clock):
    f = FusionEngine()
    assert f.update_pulse(S, pulse(drop=True)) is None
    assert f.get_current_status(S)["status"] == "vigilancia"


def test_rf05_ambos_canales_generan_un_evento_por_episodio(clock):
    f = FusionEngine()
    f.update_pulse(S, pulse(drop=True))
    events = frames(f, clock, face(ear=0.15), 4)
    assert len(events) == 1
    assert events[0].risk_level == "medio"
    assert f.get_current_status(S)["status"] == "alerta"


def test_escalada_medio_a_alto_se_registra_una_vez(clock):
    f = FusionEngine()
    f.update_pulse(S, pulse(drop=True))
    events = frames(f, clock, face(ear=0.15), 2.5)
    assert [e.risk_level for e in events] == ["medio"]
    e = f.update_pulse(S, pulse(drop=True, low_var=True))
    assert e and e.risk_level == "alto" and e.detail.startswith("Escalada")
    assert f.update_pulse(S, pulse(drop=True, low_var=True)) is None


def test_episodio_nuevo_tras_cerrar_el_anterior(clock):
    f = FusionEngine()
    f.update_pulse(S, pulse(drop=True))
    assert len(frames(f, clock, face(ear=0.15), 2.5)) == 1
    frames(f, clock, face(ear=0.30), 1)
    f.update_pulse(S, pulse(drop=True))
    assert len(frames(f, clock, face(ear=0.15), 2.5)) == 1


def test_lectura_implausible_es_advertencia_de_sensor(clock):
    f = FusionEngine()
    e = f.update_pulse(S, pulse(implausible=True, bpm=250))
    assert e and e.risk_level == "advertencia_sensor" and e.sensor_warning
    assert f.update_pulse(S, pulse(implausible=True, bpm=250)) is None
    assert f.get_current_status(S)["status"] == "advertencia_sensor"


def test_senales_viejas_no_cuentan(clock):
    f = FusionEngine()
    f.update_pulse(S, pulse(drop=True))
    clock.advance(fusion.SIGNAL_FRESHNESS_SECONDS + 1)
    events = frames(f, clock, face(ear=0.15), 2.5)
    assert events == []
    assert f.get_current_status(S)["status"] == "vigilancia"


def test_bostezo_de_un_frame_no_cuenta(clock):
    f = FusionEngine()
    f.update_vision(S, face(mar=0.8))
    clock.advance(0.33)
    f.update_vision(S, face(mar=0.2))
    assert f.get_current_status(S)["status"] == "normal"


def test_bostezo_sostenido_si_cuenta(clock):
    f = FusionEngine()
    frames(f, clock, face(mar=0.8), fusion.YAWN_SUSTAIN_SECONDS + 0.5)
    st = f.get_current_status(S)
    assert st["status"] == "vigilancia" and "bostezo" in st["detail"]


def test_microsueno_activa_aviso_sin_confirmar_pulso(clock):
    f = FusionEngine()
    events = frames(f, clock, face(ear=0.12), fusion.MICROSLEEP_SECONDS + 0.5)
    st = f.get_current_status(S)
    assert st["microsueno"] is True
    assert st["status"] == "vigilancia"   # RF05 intacto: no es "alerta"
    assert events == []                    # ni se guarda episodio de fatiga


def test_sin_microsueno_antes_del_umbral(clock):
    f = FusionEngine()
    frames(f, clock, face(ear=0.12), fusion.MICROSLEEP_SECONDS - 0.7)
    assert f.get_current_status(S)["microsueno"] is False


def calibrate(f, clock, ear, pitch=0.45):
    for _ in range(fusion.CALIBRATION_FRAMES):
        f.update_vision(S, face(ear=ear, pitch=pitch))
        clock.advance(0.33)


def test_calibracion_ear_personal_ojos_pequenos(clock):
    f = FusionEngine()
    calibrate(f, clock, ear=0.22)                 # ojos naturalmente "pequeños"
    st = f.get_current_status(S)
    assert st["ear_basal"] == 0.22
    assert abs(st["ear_umbral"] - 0.22 * fusion.EAR_CLOSED_FRACTION) < 1e-9
    r = face(ear=0.20)                            # con umbral fijo 0.21 contaría como cerrado
    f.update_vision(S, r)
    assert r.eyes_closed is False


def test_calibracion_ear_personal_ojos_grandes(clock):
    f = FusionEngine()
    calibrate(f, clock, ear=0.32)                 # umbral personal 0.24
    r = face(ear=0.23)                            # con umbral fijo 0.21 contaría como abierto
    f.update_vision(S, r)
    assert r.eyes_closed is True


def test_umbral_ear_acotado():
    assert FusionEngine.ear_threshold(0.10) == fusion.EAR_THRESHOLD_MIN
    assert FusionEngine.ear_threshold(0.50) == fusion.EAR_THRESHOLD_MAX


def test_cabeceo_frontal_por_pitch(clock):
    f = FusionEngine()
    calibrate(f, clock, ear=0.30, pitch=0.45)
    r = face(ear=0.30, pitch=0.60)                # la cabeza cae hacia adelante
    f.update_vision(S, r)
    assert r.head_tilted is True
    r = face(ear=0.30, pitch=0.47)                # variación normal
    f.update_vision(S, r)
    assert r.head_tilted is False


def test_calibracion_se_pierde_tras_inactividad(clock):
    f = FusionEngine()
    calibrate(f, clock, ear=0.30)
    assert f.get_current_status(S)["ear_basal"] is not None
    clock.advance(fusion.IDLE_RESET_SECONDS + 1)
    f.update_vision(S, face(ear=0.30))
    assert f.get_current_status(S)["ear_basal"] is None


def test_reset_explicito(clock):
    f = FusionEngine()
    calibrate(f, clock, ear=0.30)
    f.reset(S)
    assert f.get_current_status(S)["ear_basal"] is None
