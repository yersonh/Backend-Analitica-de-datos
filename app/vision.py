"""
Módulo de visión artificial para SIDFAM.

Usa MediaPipe Face Mesh (468 landmarks, modelo preentrenado, sin
entrenamiento propio) para calcular:
  - EAR (Eye Aspect Ratio)  -> detecta parpadeo prolongado / cierre de ojos
  - MAR (Mouth Aspect Ratio) -> detecta bostezos
  - Inclinación de cabeza (roll aproximado) -> cabeceo

Referencia clásica para EAR/MAR: Soukupová & Čech (2016),
"Real-Time Eye Blink Detection using Facial Landmarks".
"""

from dataclasses import dataclass, field
import math

import cv2
import mediapipe as mp
import numpy as np

# --- Índices de landmarks de MediaPipe Face Mesh que necesitamos ---
# Ojo izquierdo (desde el punto de vista de la imagen, no del sujeto)
LEFT_EYE = [33, 160, 158, 133, 153, 144]
# Ojo derecho
RIGHT_EYE = [362, 385, 387, 263, 373, 380]
# Boca (para MAR): comisuras + puntos verticales interiores
MOUTH = [61, 291, 39, 181, 0, 17, 269, 405]
# Puntos de referencia para inclinación de cabeza
NOSE_TIP = 1
LEFT_EYE_OUTER = 33
RIGHT_EYE_OUTER = 263

# --- Umbrales (ajustables según calibración con los compañeros) ---
EAR_THRESHOLD = 0.21          # por debajo de esto, ojo considerado "cerrado"
MAR_THRESHOLD = 0.6           # por encima de esto, boca considerada "abierta" (bostezo)
HEAD_TILT_THRESHOLD_DEG = 15  # inclinación de cabeza considerada relevante


@dataclass
class VisionResult:
    face_detected: bool
    ear: float | None = None
    mar: float | None = None
    head_tilt_deg: float | None = None
    eyes_closed: bool = False
    yawning: bool = False
    head_tilted: bool = False
    # Los 468 puntos en píxeles, solo para dibujar la vista del modelo (app/overlay.py);
    # no se guardan ni se envían en el JSON.
    landmarks: list[tuple[float, float]] | None = field(default=None, repr=False)


def _euclidean(p1, p2) -> float:
    return math.dist(p1, p2)


def _eye_aspect_ratio(landmarks, eye_idx) -> float:
    p = [landmarks[i] for i in eye_idx]
    # p = [p1..p6] siguiendo la convención estándar de EAR
    vertical_1 = _euclidean(p[1], p[5])
    vertical_2 = _euclidean(p[2], p[4])
    horizontal = _euclidean(p[0], p[3])
    if horizontal == 0:
        return 0.0
    return (vertical_1 + vertical_2) / (2.0 * horizontal)


def _mouth_aspect_ratio(landmarks, mouth_idx) -> float:
    p = [landmarks[i] for i in mouth_idx]
    # Distancias verticales internas / distancia horizontal (comisuras)
    vertical_1 = _euclidean(p[2], p[3])
    vertical_2 = _euclidean(p[4], p[5])
    vertical_3 = _euclidean(p[6], p[7])
    horizontal = _euclidean(p[0], p[1])
    if horizontal == 0:
        return 0.0
    return (vertical_1 + vertical_2 + vertical_3) / (3.0 * horizontal)


def _head_tilt_degrees(landmarks) -> float:
    left = landmarks[LEFT_EYE_OUTER]
    right = landmarks[RIGHT_EYE_OUTER]
    dy = right[1] - left[1]
    dx = right[0] - left[0]
    angle = math.degrees(math.atan2(dy, dx))
    return angle


class FaceAnalyzer:
    """Envoltorio sobre MediaPipe Face Mesh, pensado para reutilizar
    una sola instancia del modelo entre requests (es costoso crearlo
    cada vez)."""

    def __init__(self):
        self._mp_face_mesh = mp.solutions.face_mesh
        self._face_mesh = self._mp_face_mesh.FaceMesh(
            static_image_mode=True,
            max_num_faces=1,
            refine_landmarks=False,
            min_detection_confidence=0.5,
        )

    def analyze(self, image_bgr: np.ndarray) -> VisionResult:
        image_rgb = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2RGB)
        results = self._face_mesh.process(image_rgb)

        if not results.multi_face_landmarks:
            return VisionResult(face_detected=False)

        h, w = image_bgr.shape[:2]
        raw_landmarks = results.multi_face_landmarks[0].landmark
        landmarks = [(lm.x * w, lm.y * h) for lm in raw_landmarks]

        ear_left = _eye_aspect_ratio(landmarks, LEFT_EYE)
        ear_right = _eye_aspect_ratio(landmarks, RIGHT_EYE)
        ear = (ear_left + ear_right) / 2.0

        mar = _mouth_aspect_ratio(landmarks, MOUTH)
        tilt = _head_tilt_degrees(landmarks)

        return VisionResult(
            face_detected=True,
            ear=round(ear, 4),
            mar=round(mar, 4),
            head_tilt_deg=round(tilt, 2),
            eyes_closed=ear < EAR_THRESHOLD,
            yawning=mar > MAR_THRESHOLD,
            head_tilted=abs(tilt) > HEAD_TILT_THRESHOLD_DEG,
            landmarks=landmarks,
        )

    def close(self):
        self._face_mesh.close()


# Instancia única reutilizada por toda la app (ver app/main.py)
face_analyzer = FaceAnalyzer()
