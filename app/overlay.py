"""
Vista del modelo para la cámara en vivo.

Dibuja sobre el frame lo que "ve" MediaPipe: la malla de puntos, el contorno
de ojos y boca (verde = normal, rojo = señal), la línea de inclinación de la
cabeza, los valores EAR / MAR / grados y una franja superior con el estado de
la fusión. Devuelve un JPEG listo para la app. Solo se usa para mostrar: no
afecta la detección ni se guarda en la base.

cv2.putText solo admite ASCII: los textos van sin tildes.
"""

import cv2
import numpy as np

from .vision import (
    EAR_THRESHOLD, HEAD_TILT_THRESHOLD_DEG, LEFT_EYE, LEFT_EYE_OUTER, MAR_THRESHOLD,
    RIGHT_EYE, RIGHT_EYE_OUTER, VisionResult,
)

# Contorno exterior de los labios en Face Mesh (solo para dibujar; el MAR usa vision.MOUTH)
LIPS_OUTER = [61, 185, 40, 39, 37, 0, 267, 269, 270, 409, 291, 375, 321, 405, 314, 17, 84, 181, 91, 146]

JPEG_QUALITY = 70
DRAW_WIDTH = 640   # la ESP32-CAM manda 320x240: se amplía antes de dibujar para que el texto se lea

# Colores BGR
VERDE = (153, 211, 52)
ROJO = (133, 113, 251)
AMBAR = (36, 191, 251)
CIAN = (248, 189, 56)
VIOLETA = (252, 132, 192)
GRIS = (184, 163, 148)
BLANCO = (255, 255, 255)

_BANNER = {
    "normal": ("NORMAL - SIN FATIGA", VERDE),
    "vigilancia": ("VIGILANCIA - UN CANAL CON INDICIOS", CIAN),
    "alerta-medio": ("FATIGA DETECTADA - RIESGO MEDIO", AMBAR),
    "alerta-alto": ("RIESGO ALTO - FATIGA", ROJO),
    "advertencia_sensor": ("REVISAR SENSOR DE PULSO", VIOLETA),
}


def _status_key(status: dict) -> str:
    if status.get("status") == "alerta":
        return f"alerta-{status.get('risk_level') or 'medio'}"
    return status.get("status") or "normal"


def _poly(img, pts, idx, color, thick):
    arr = np.array([pts[i] for i in idx], dtype=np.int32)
    cv2.polylines(img, [arr], True, color, thick, cv2.LINE_AA)


def _label(img, text, org, scale, color, thick=1):
    """Texto con sombra para que se lea sobre cualquier fondo."""
    cv2.putText(img, text, (org[0] + 1, org[1] + 1), cv2.FONT_HERSHEY_SIMPLEX, scale, (0, 0, 0), thick + 1, cv2.LINE_AA)
    cv2.putText(img, text, org, cv2.FONT_HERSHEY_SIMPLEX, scale, color, thick, cv2.LINE_AA)


def annotate(image_bgr: np.ndarray, vision: VisionResult, status: dict) -> bytes:
    k = DRAW_WIDTH / image_bgr.shape[1] if image_bgr.shape[1] < DRAW_WIDTH else 1.0
    img = cv2.resize(image_bgr, None, fx=k, fy=k, interpolation=cv2.INTER_LINEAR) if k != 1.0 else image_bgr.copy()
    h, w = img.shape[:2]
    s = w / 640.0                          # escala de textos y trazos según la resolución
    thick = max(1, round(2 * s))

    if vision.face_detected and vision.landmarks:
        pts = [(int(x * k), int(y * k)) for x, y in vision.landmarks]
        # malla de puntos: muestra que el modelo encontró la cara
        mesh = img.copy()
        for p in pts:
            cv2.circle(mesh, p, max(1, round(1.3 * s)), CIAN, -1, cv2.LINE_AA)
        img = cv2.addWeighted(mesh, 0.55, img, 0.45, 0)

        eye_color = ROJO if vision.eyes_closed else VERDE
        _poly(img, pts, LEFT_EYE, eye_color, thick)
        _poly(img, pts, RIGHT_EYE, eye_color, thick)
        _poly(img, pts, LIPS_OUTER, ROJO if vision.yawning else VERDE, thick)
        cv2.line(img, pts[LEFT_EYE_OUTER], pts[RIGHT_EYE_OUTER], AMBAR if vision.head_tilted else GRIS, thick, cv2.LINE_AA)

        # señales activas junto a la cara
        signs = [t for t, on in (("OJOS CERRADOS", vision.eyes_closed), ("BOSTEZO", vision.yawning),
                                 ("CABEZA INCLINADA", vision.head_tilted)) if on]
        y = int(42 * s) + int(30 * s)
        for t in signs:
            _label(img, t, (int(10 * s), y), 0.6 * s, ROJO, thick)
            y += int(26 * s)

        # valores medidos frente a su umbral
        info = (f"EAR {vision.ear:.2f}/{EAR_THRESHOLD}  MAR {vision.mar:.2f}/{MAR_THRESHOLD}  "
                f"CABEZA {vision.head_tilt_deg:+.0f}/{HEAD_TILT_THRESHOLD_DEG} gr")
        cv2.rectangle(img, (0, h - int(30 * s)), (w, h), (0, 0, 0), -1)
        _label(img, info, (int(8 * s), h - int(10 * s)), 0.5 * s, BLANCO, max(1, round(s)))
    else:
        _label(img, "SIN ROSTRO", (int(w / 2 - 70 * s), int(h / 2)), 0.9 * s, AMBAR, thick)

    # franja superior con el estado de la fusión (visión + pulso)
    text, color = _BANNER.get(_status_key(status), ("ESTADO DESCONOCIDO", GRIS))
    band = img.copy()
    cv2.rectangle(band, (0, 0), (w, int(34 * s)), color, -1)
    img = cv2.addWeighted(band, 0.75, img, 0.25, 0)
    _label(img, text, (int(10 * s), int(23 * s)), 0.6 * s, BLANCO, thick)

    ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, JPEG_QUALITY])
    return buf.tobytes() if ok else b""
