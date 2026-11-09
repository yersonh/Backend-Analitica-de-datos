"""Reglas del canal fisiológico (app/pulse.py)."""

from app import pulse
from app.pulse import PulseAnalyzer

READY = pulse.BASELINE_WARMUP_COUNT + pulse.BASELINE_SAMPLE_COUNT


def feed(analyzer, clock, values, session="s1", step=2.0):
    result = None
    for v in values:
        result = analyzer.add_reading(session, v)
        clock.advance(step)
    return result


def test_basal_ignora_calentamiento_y_usa_mediana(clock):
    a = PulseAnalyzer()
    # Calentamiento agitado (100 BPM) que NO debe entrar al basal
    r = feed(a, clock, [100] * pulse.BASELINE_WARMUP_COUNT + [70] * (pulse.BASELINE_SAMPLE_COUNT - 1))
    assert r.baseline_bpm is None
    r = feed(a, clock, [70])
    assert r.baseline_bpm == 70


def test_lectura_implausible_no_es_fatiga_ni_entra_a_la_ventana(clock):
    a = PulseAnalyzer()
    feed(a, clock, [70] * READY)
    r = a.add_reading("s1", 250)
    assert r.implausible_reading
    assert not r.physiological_drowsy_signal
    assert 250 not in [x.bpm for x in a._buffers["s1"]]


def test_caida_relativa_dispara_senal(clock):
    a = PulseAnalyzer()
    feed(a, clock, [70] * READY)
    # 8 % bajo 70 = 64.4: una ventana completa en 62 dispara la señal
    r = feed(a, clock, [62] * 35)
    assert r.relative_drop_signal and r.physiological_drowsy_signal


def test_caida_pequena_no_dispara(clock):
    a = PulseAnalyzer()
    feed(a, clock, [70] * READY)
    r = feed(a, clock, [67] * 35)
    assert not r.relative_drop_signal


def test_baja_variabilidad_sola_no_es_somnolencia(clock):
    a = PulseAnalyzer()
    r = feed(a, clock, [70] * (READY + 10))
    assert r.low_variability
    assert not r.physiological_drowsy_signal


def test_basal_se_reinicia_tras_inactividad(clock):
    a = PulseAnalyzer()
    feed(a, clock, [70] * READY)
    assert a._baselines["s1"] == 70
    clock.advance(pulse.IDLE_RESET_SECONDS + 1)
    r = a.add_reading("s1", 90)
    assert r.baseline_bpm is None
    assert "s1" not in a._baselines


def test_reset_explicito(clock):
    a = PulseAnalyzer()
    feed(a, clock, [70] * READY)
    a.reset("s1")
    assert a.add_reading("s1", 70).baseline_bpm is None


def test_sesiones_independientes(clock):
    a = PulseAnalyzer()
    feed(a, clock, [70] * READY, session="a")
    assert a.add_reading("b", 70).baseline_bpm is None
