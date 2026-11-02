"""
Módulo de procesamiento de la señal fisiológica (pulso cardíaco) para SIDFAM.

Supuesto de hardware: el ESP32 normal ya calcula el BPM instantáneo
(p. ej. con una librería del sensor MAX30102/MAX30105) y lo envía
periódicamente al backend. Aquí se mantiene un buffer por dispositivo
para poder calcular variabilidad (HRV aproximada) sobre una ventana
de tiempo, en vez de evaluar cada lectura de forma aislada.

Diseño de umbrales (alineado con RF05 y con la literatura de somnolencia):
la evidencia asocia la somnolencia a una caída RELATIVA del pulso
respecto al valor basal de la propia persona (~5-10 %), no a un umbral
absoluto fijo. Por eso:

  1. Se aprende un `baseline_bpm` personal con las primeras
     BASELINE_SAMPLE_COUNT lecturas plausibles de la sesión y NO se
     recalcula (para no "perseguir" una caída gradual real).
  2. Se marca `relative_drop_signal` cuando la MEDIANA de la ventana cae
     por debajo de `baseline_bpm * (1 - RELATIVE_DROP_THRESHOLD)`. La
     mediana (también en el basal) resiste los picos de ruido del sensor.
  3. `low_variability` (std muy baja y sostenida) NO es señal de
     somnolencia por sí sola: el ESP32 envía BPM ya promediados y daría
     falsos positivos. Solo suma como razón extra en la fusión cuando ya
     hay caída sostenida.
  4. Una lectura fuera de [PLAUSIBLE_BPM_MIN, PLAUSIBLE_BPM_MAX] NO es
     fatiga: es un problema de calidad de dato (`implausible_reading`),
     una alerta distinta de sensor. Tampoco entra a la ventana de análisis.

Si el sensor que finalmente se use entrega valores crudos (IR/RED)
en lugar de BPM, este módulo es el lugar para agregar la detección
de picos antes de llegar a las métricas de abajo.
"""

from collections import deque
from dataclasses import dataclass, field
import statistics
import time

WINDOW_SECONDS = 60           # ventana de análisis de HRV
MIN_SAMPLES_FOR_ANALYSIS = 15   # ~30 s de lecturas (1 cada 2 s) antes de evaluar
LOW_VARIABILITY_STD = 1.5     # std de BPM muy baja y sostenida -> señal de somnolencia

BASELINE_SAMPLE_COUNT = 20    # lecturas plausibles para fijar el basal personal
RELATIVE_DROP_THRESHOLD = 0.08  # caída >= 8 % de la media respecto al basal -> somnolencia

PLAUSIBLE_BPM_MIN = 30       # por debajo: lectura no fisiológica (error de sensor)
PLAUSIBLE_BPM_MAX = 220      # por encima: lectura no fisiológica (error de sensor)


@dataclass
class PulseReading:
    bpm: float
    timestamp: float = field(default_factory=lambda: time.time())


@dataclass
class PulseResult:
    has_enough_data: bool
    bpm_current: float | None = None
    bpm_mean: float | None = None
    bpm_median: float | None = None            # la que decide relative_drop_signal
    bpm_std: float | None = None
    baseline_bpm: float | None = None
    low_variability: bool = False
    relative_drop_signal: bool = False
    implausible_reading: bool = False          # calidad de dato, NO fatiga
    physiological_drowsy_signal: bool = False  # = relative_drop_signal

    def __post_init__(self):
        # Solo la caída sostenida respecto al basal es señal de somnolencia.
        # La baja variabilidad sola da falsos positivos (el ESP32 envía BPM ya
        # promediados); solo suma como razón extra en fusion.py.
        self.physiological_drowsy_signal = self.relative_drop_signal


class PulseAnalyzer:
    """Mantiene un buffer deslizante y un basal personal por device_id."""

    def __init__(self):
        self._buffers: dict[str, deque[PulseReading]] = {}
        self._baselines: dict[str, float] = {}
        self._baseline_samples: dict[str, list[float]] = {}

    def _get_buffer(self, device_id: str) -> deque[PulseReading]:
        if device_id not in self._buffers:
            self._buffers[device_id] = deque(maxlen=200)
        return self._buffers[device_id]

    def _prune(self, buffer: deque[PulseReading]) -> None:
        cutoff = time.time() - WINDOW_SECONDS
        while buffer and buffer[0].timestamp < cutoff:
            buffer.popleft()

    def _update_baseline(self, device_id: str, bpm: float, implausible: bool) -> float | None:
        """Acumula lecturas plausibles hasta fijar el basal; luego lo deja fijo.
        Usa la mediana para que unas pocas lecturas con ruido no muevan el basal."""
        baseline = self._baselines.get(device_id)
        if baseline is not None or implausible:
            return baseline

        samples = self._baseline_samples.setdefault(device_id, [])
        samples.append(bpm)
        if len(samples) >= BASELINE_SAMPLE_COUNT:
            baseline = round(statistics.median(samples), 2)
            self._baselines[device_id] = baseline
            del self._baseline_samples[device_id]
        return baseline

    def add_reading(self, device_id: str, bpm: float) -> PulseResult:
        implausible = bpm < PLAUSIBLE_BPM_MIN or bpm > PLAUSIBLE_BPM_MAX
        baseline = self._update_baseline(device_id, bpm, implausible)

        buffer = self._get_buffer(device_id)
        if not implausible:
            # Una lectura imposible es error del sensor: no entra a la ventana
            buffer.append(PulseReading(bpm=bpm))
        self._prune(buffer)

        if len(buffer) < MIN_SAMPLES_FOR_ANALYSIS:
            return PulseResult(
                has_enough_data=False,
                bpm_current=bpm,
                baseline_bpm=baseline,
                implausible_reading=implausible,
            )

        values = [r.bpm for r in buffer]
        mean_bpm = round(statistics.mean(values), 2)
        median_bpm = round(statistics.median(values), 2)
        std_bpm = round(statistics.pstdev(values), 2)

        low_variability = std_bpm < LOW_VARIABILITY_STD
        # Caída sostenida: la MEDIANA de los últimos 60 s, robusta a picos de ruido
        relative_drop = (
            baseline is not None
            and median_bpm <= baseline * (1 - RELATIVE_DROP_THRESHOLD)
        )

        return PulseResult(
            has_enough_data=True,
            bpm_current=bpm,
            bpm_mean=mean_bpm,
            bpm_median=median_bpm,
            bpm_std=std_bpm,
            baseline_bpm=baseline,
            low_variability=low_variability,
            relative_drop_signal=relative_drop,
            implausible_reading=implausible,
        )


# Instancia única reutilizada por toda la app (ver app/main.py)
pulse_analyzer = PulseAnalyzer()
