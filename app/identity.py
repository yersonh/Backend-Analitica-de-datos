"""
Verificación de identidad del conductor por rostro (SIDFAM).

Objetivo: que los datos de una sesión (frames, pulso, fusión, episodios) sean
SOLO del conductor dueño de esa sesión. Si frente a la cámara hay otra
persona, sus lecturas no se guardan ni alimentan la fusión.

Modelos (OpenCV Zoo, ONNX, se descargan con scripts/descargar_modelos.py):
  - YuNet  (face_detection_yunet_2023mar.onnx): detecta el rostro y 5 puntos.
  - SFace  (face_recognition_sface_2021dec.onnx): convierte el rostro alineado
    en un vector de 128 rasgos. Dos vectores de la misma persona tienen
    similitud coseno alta (umbral recomendado por OpenCV: 0.363).

Datos sensibles (Ley 1581 de 2012): solo se guardan esos vectores (nunca las
fotos) y la fecha del consentimiento explícito. El conductor puede borrar su
registro (DELETE /api/identidad/registro) y el administrador también.

Flujo:
  1. Registro: el conductor envía ENROLL_MIN_SAMPLES-ENROLL_MAX_SAMPLES fotos
     desde la app. Cada una debe tener exactamente un rostro y ser coherente
     con las demás.
  2. Verificación al entrar: la app envía una foto y, si coincide, la sesión
     queda verificada.
  3. Verificación continua: cada frame que llega (ESP32-CAM o celular) se
     revisa cada CHECK_INTERVAL_VERIFIED segundos (cada
     CHECK_INTERVAL_UNVERIFIED mientras no esté verificada). Hacen falta
     MISMATCHES_TO_REJECT comparaciones fallidas seguidas para pasar a
     "no_coincide" (una foto mala no corta los datos), y una sola coincidencia
     para volver a "verificado".

Política de datos (`allows_data`):
  - Sesión sin conductor con registro facial -> se aceptan (como antes): no
    hay contra qué comparar. /estado lo marca "sin_registro".
  - Con registro -> se aceptan solo si hubo una coincidencia en los últimos
    VALID_SECONDS y no hay un "no_coincide" posterior.
  - Modelos ausentes (desarrollo local sin descargarlos) -> se aceptan y
    /estado marca "deshabilitada"; el arranque lo registra en el log.

Una foto de la persona frente a la cámara puede engañar al sistema: no hay
detección de vida (anti-spoofing). Es una limitación declarada del prototipo.
"""

from __future__ import annotations

import logging
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

import cv2
import numpy as np

from . import database

log = logging.getLogger("sidfam")

MODELS_DIR = Path(__file__).parent / "models"
DETECTOR_FILE = "face_detection_yunet_2023mar.onnx"
RECOGNIZER_FILE = "face_recognition_sface_2021dec.onnx"

MATCH_THRESHOLD = 0.363          # similitud coseno mínima para "misma persona" (SFace)
DETECTION_SCORE = 0.8            # confianza mínima de YuNet
MIN_FACE_PX = 60                 # rostro más angosto que esto: muy lejos para comparar
ENROLL_MIN_SAMPLES = 3
ENROLL_MAX_SAMPLES = 5
CHECK_INTERVAL_VERIFIED = 5.0    # s entre comprobaciones mientras está verificada
CHECK_INTERVAL_UNVERIFIED = 1.0  # s entre comprobaciones mientras no lo está
VALID_SECONDS = 300              # una coincidencia vale 5 min (el rostro puede no verse un rato)
MISMATCHES_TO_REJECT = 2         # comparaciones fallidas seguidas para "no_coincide"
ENROLLMENT_CACHE_SECONDS = 30    # cuánto se reutiliza el registro leído de la base


class IdentityError(Exception):
    """Foto no apta para registrar o verificar (sin rostro, varios, muy lejos...)."""


@dataclass
class FaceSample:
    embedding: np.ndarray        # 128 floats, normalizado (norma 1)
    box: tuple[int, int, int, int]


def _normalize(v: np.ndarray) -> np.ndarray:
    v = np.asarray(v, dtype=np.float32).reshape(-1)
    n = float(np.linalg.norm(v))
    return v / n if n > 0 else v


def similarity(a, b) -> float:
    """Similitud coseno entre dos vectores (los normaliza)."""
    return float(np.dot(_normalize(a), _normalize(b)))


class FaceIdentifier:
    """YuNet + SFace de OpenCV. Se cargan una sola vez y bajo un lock (los
    objetos dnn de OpenCV no son thread-safe y la ingesta corre en threadpool)."""

    def __init__(self, models_dir: Path = MODELS_DIR):
        self._dir = models_dir
        self._lock = threading.Lock()
        self._detector = None
        self._recognizer = None
        self._load_error: str | None = None
        self._loaded = False

    def _load(self) -> None:
        if self._loaded:
            return
        self._loaded = True
        det, rec = self._dir / DETECTOR_FILE, self._dir / RECOGNIZER_FILE
        if not det.exists() or not rec.exists():
            self._load_error = (f"faltan los modelos en {self._dir} "
                                "(ejecuta: python scripts/descargar_modelos.py)")
            return
        try:
            self._detector = cv2.FaceDetectorYN.create(str(det), "", (320, 240), DETECTION_SCORE, 0.3, 5000)
            self._recognizer = cv2.FaceRecognizerSF.create(str(rec), "")
        except cv2.error as e:   # pragma: no cover - depende de la versión de OpenCV
            self._load_error = f"no se pudieron cargar los modelos: {e}"
            self._detector = self._recognizer = None

    @property
    def available(self) -> bool:
        with self._lock:
            self._load()
            return self._detector is not None

    @property
    def unavailable_reason(self) -> str | None:
        with self._lock:
            self._load()
            return self._load_error

    def faces(self, image_bgr: np.ndarray) -> list[FaceSample]:
        """Todos los rostros suficientemente grandes de la imagen, el mayor primero."""
        with self._lock:
            self._load()
            if self._detector is None:
                return []
            h, w = image_bgr.shape[:2]
            self._detector.setInputSize((w, h))
            _, detections = self._detector.detect(image_bgr)
            if detections is None:
                return []
            out = []
            for d in sorted(detections, key=lambda d: d[2] * d[3], reverse=True):
                if d[2] < MIN_FACE_PX:
                    continue
                aligned = self._recognizer.alignCrop(image_bgr, d)
                feat = self._recognizer.feature(aligned)
                out.append(FaceSample(_normalize(feat), tuple(int(x) for x in d[:4])))
            return out


face_identifier = FaceIdentifier()


def single_face_embedding(identifier, image_bgr: np.ndarray) -> np.ndarray:
    """Vector del único rostro de la foto; IdentityError si no hay o hay varios."""
    faces = identifier.faces(image_bgr)
    if not faces:
        raise IdentityError("No se ve un rostro claro: acércate, mira de frente y busca buena luz.")
    if len(faces) > 1:
        raise IdentityError("Hay más de un rostro en la foto: debe salir solo el conductor.")
    return faces[0].embedding


def best_similarity(embedding: np.ndarray, enrollments: list[dict]) -> tuple[float, int | None]:
    """Mejor similitud contra todas las muestras de todos los registros de la sesión."""
    best, user_id = -1.0, None
    for e in enrollments:
        for sample in e["embeddings"]:
            sim = similarity(embedding, sample)
            if sim > best:
                best, user_id = sim, int(e["user_id"])
    return best, user_id


def build_enrollment(identifier, images: list[np.ndarray]) -> list[list[float]]:
    """Valida las fotos de registro y devuelve sus vectores (listas, para JSON)."""
    if not ENROLL_MIN_SAMPLES <= len(images) <= ENROLL_MAX_SAMPLES:
        raise IdentityError(f"Envía entre {ENROLL_MIN_SAMPLES} y {ENROLL_MAX_SAMPLES} fotos.")
    embeddings = []
    for i, img in enumerate(images, 1):
        try:
            embeddings.append(single_face_embedding(identifier, img))
        except IdentityError as e:
            raise IdentityError(f"Foto {i}: {e}") from None
    # Todas deben ser de la misma persona (evita registrar a dos personas mezcladas)
    for i in range(len(embeddings)):
        for j in range(i + 1, len(embeddings)):
            if similarity(embeddings[i], embeddings[j]) < MATCH_THRESHOLD:
                raise IdentityError("Las fotos no parecen de la misma persona. Repite el registro solo, "
                                    "de frente y con buena luz.")
    return [e.astype(float).round(6).tolist() for e in embeddings]


@dataclass
class _SessionIdentity:
    status: str = "pendiente"                  # pendiente | verificado | no_coincide
    last_match_at: float | None = None
    last_check_at: float = 0.0
    mismatches: int = 0
    similarity: float | None = None
    user_id: int | None = None


@dataclass
class _CacheEntry:
    loaded_at: float
    enrollments: list[dict] = field(default_factory=list)


class IdentityGuard:
    """Estado de verificación por sesión (en memoria, como el resto del estado vivo)."""

    def __init__(self, identifier=None):
        self.identifier = identifier or face_identifier
        self._lock = threading.RLock()
        self._sessions: dict[str, _SessionIdentity] = {}
        self._cache: dict[str, _CacheEntry] = {}

    # --- registro (lectura cacheada de la base) ---
    def enrollments(self, session_id: str) -> list[dict]:
        now = time.time()
        with self._lock:
            entry = self._cache.get(session_id)
            if entry and now - entry.loaded_at < ENROLLMENT_CACHE_SECONDS:
                return entry.enrollments
        rows = database.face_enrollments_for_session(session_id)
        with self._lock:
            self._cache[session_id] = _CacheEntry(now, rows)
        return rows

    def invalidate(self, session_id: str | None = None) -> None:
        """Olvida el registro cacheado y el estado (tras registrar, borrar o
        cambiar la sesión de un usuario)."""
        with self._lock:
            if session_id is None:
                self._cache.clear()
                self._sessions.clear()
            else:
                self._cache.pop(session_id, None)
                self._sessions.pop(session_id, None)

    def _state(self, session_id: str) -> _SessionIdentity:
        return self._sessions.setdefault(session_id, _SessionIdentity())

    # --- comparación ---
    def _record(self, st: _SessionIdentity, sim: float, user_id: int | None, now: float) -> bool:
        st.last_check_at = now
        st.similarity = round(sim, 4)
        if sim >= MATCH_THRESHOLD:
            st.status, st.last_match_at, st.mismatches, st.user_id = "verificado", now, 0, user_id
            return True
        st.mismatches += 1
        if st.mismatches >= MISMATCHES_TO_REJECT:
            st.status = "no_coincide"
        return False

    def mark_verified(self, session_id: str, user_id: int | None = None, sim: float = 1.0) -> None:
        with self._lock:
            self._record(self._state(session_id), sim, user_id, time.time())

    def verify_image(self, session_id: str, image_bgr: np.ndarray) -> dict:
        """Verificación explícita (al entrar en la app). IdentityError si la foto
        no sirve. Una sola comparación fallida aquí ya marca "no_coincide"."""
        enrollments = self.enrollments(session_id)
        if not enrollments:
            raise IdentityError("Esta sesión no tiene un rostro registrado.")
        emb = single_face_embedding(self.identifier, image_bgr)
        sim, user_id = best_similarity(emb, enrollments)
        with self._lock:
            st = self._state(session_id)
            ok = self._record(st, sim, user_id, time.time())
            if not ok:
                st.status = "no_coincide"
        return {"coincide": ok, "similitud": round(sim, 4), **self.status(session_id)}

    def check_frame(self, session_id: str, image_bgr: np.ndarray) -> bool:
        """Comprobación continua sobre un frame de monitoreo (con intervalo).
        Devuelve si los datos de este frame pueden usarse."""
        if not self.identifier.available or not self.enrollments(session_id):
            return True
        now = time.time()
        with self._lock:
            st = self._state(session_id)
            interval = CHECK_INTERVAL_VERIFIED if st.status == "verificado" else CHECK_INTERVAL_UNVERIFIED
            due = now - st.last_check_at >= interval
        if due:
            faces = self.identifier.faces(image_bgr)
            if faces:
                # Con varios rostros, basta que el conductor esté entre ellos
                # (p. ej. un acompañante al fondo); la fusión usa el mayor.
                best = max((best_similarity(f.embedding, self.enrollments(session_id)) for f in faces),
                           key=lambda x: x[0])
                with self._lock:
                    self._record(self._state(session_id), best[0], best[1], now)
            else:
                with self._lock:
                    self._state(session_id).last_check_at = now
        return self.allows_data(session_id)

    def allows_data(self, session_id: str) -> bool:
        if not self.identifier.available or not self.enrollments(session_id):
            return True
        now = time.time()
        with self._lock:
            st = self._state(session_id)
            return (st.status == "verificado" and st.last_match_at is not None
                    and now - st.last_match_at <= VALID_SECONDS)

    def status(self, session_id: str) -> dict:
        """Estado para /estado y la app: deshabilitada | sin_registro | pendiente |
        verificado | no_coincide (y "vencida" si la última coincidencia expiró)."""
        if not self.identifier.available:
            return {"estado": "deshabilitada", "acepta_datos": True, "similitud": None, "hace_seg": None}
        if not self.enrollments(session_id):
            return {"estado": "sin_registro", "acepta_datos": True, "similitud": None, "hace_seg": None}
        now = time.time()
        with self._lock:
            st = self._state(session_id)
            estado = st.status
            if estado == "verificado" and (st.last_match_at is None or now - st.last_match_at > VALID_SECONDS):
                estado = "vencida"
            return {
                "estado": estado,
                "acepta_datos": estado == "verificado",
                "similitud": st.similarity,
                "hace_seg": round(now - st.last_match_at, 1) if st.last_match_at else None,
            }


identity_guard = IdentityGuard()
