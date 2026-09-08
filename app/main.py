"""
SIDFAM - Backend en la nube.

Endpoints:
  POST /frame     -> recibe una imagen JPEG del ESP32-CAM, la analiza
                      con MediaPipe y actualiza el estado de fusión.
  POST /pulso     -> recibe una lectura de BPM del ESP32 con el sensor
                      de pulso y actualiza el estado de fusión.
  GET  /eventos    -> historial de eventos de fatiga en JSON.
  GET  /estado     -> estado actual de la fusión en tiempo real (JSON).
  GET  /            -> dashboard HTML (RF09, RF10).

Ejecutar en desarrollo:
  uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
"""

from pathlib import Path

import cv2
import numpy as np
from fastapi import FastAPI, File, Form, UploadFile
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
from fastapi.requests import Request

from . import database
from .fusion import fusion_engine
from .pulse import pulse_analyzer
from .vision import face_analyzer

app = FastAPI(title="SIDFAM Backend")

templates = Jinja2Templates(directory=str(Path(__file__).parent / "templates"))

DEFAULT_SESSION_ID = "default"


@app.on_event("startup")
def on_startup():
    database.init_db()


@app.post("/frame")
async def receive_frame(file: UploadFile = File(...), session_id: str = Form(DEFAULT_SESSION_ID)):
    """Recibe un frame JPEG del ESP32-CAM y lo procesa con MediaPipe."""
    raw_bytes = await file.read()
    np_arr = np.frombuffer(raw_bytes, dtype=np.uint8)
    image_bgr = cv2.imdecode(np_arr, cv2.IMREAD_COLOR)

    if image_bgr is None:
        return {"error": "No se pudo decodificar la imagen recibida"}

    vision_result = face_analyzer.analyze(image_bgr)
    event = fusion_engine.update_vision(session_id, vision_result)

    if event:
        database.save_event(
            session_id=event.session_id,
            timestamp=event.timestamp,
            risk_level=event.risk_level,
            visual_signal=event.visual_signal,
            physiological_signal=event.physiological_signal,
            detail=event.detail,
            bpm=event.bpm,
            ear=event.ear,
            sensor_warning=event.sensor_warning,
        )
    else:
        database.increment_normal_reading(session_id)

    return {
        "face_detected": vision_result.face_detected,
        "ear": vision_result.ear,
        "mar": vision_result.mar,
        "head_tilt_deg": vision_result.head_tilt_deg,
        "eyes_closed": vision_result.eyes_closed,
        "yawning": vision_result.yawning,
        "fatigue_event": event.risk_level if event else None,
    }


@app.post("/pulso")
async def receive_pulse(bpm: float = Form(...), session_id: str = Form(DEFAULT_SESSION_ID)):
    """Recibe una lectura de BPM del ESP32 con el sensor de pulso."""
    pulse_result = pulse_analyzer.add_reading(session_id, bpm)
    event = fusion_engine.update_pulse(session_id, pulse_result)

    if event:
        database.save_event(
            session_id=event.session_id,
            timestamp=event.timestamp,
            risk_level=event.risk_level,
            visual_signal=event.visual_signal,
            physiological_signal=event.physiological_signal,
            detail=event.detail,
            bpm=event.bpm,
            ear=event.ear,
            sensor_warning=event.sensor_warning,
        )
    else:
        database.increment_normal_reading(session_id)

    return {
        "bpm_current": pulse_result.bpm_current,
        "bpm_mean": pulse_result.bpm_mean,
        "bpm_std": pulse_result.bpm_std,
        "baseline_bpm": pulse_result.baseline_bpm,
        "relative_drop_signal": pulse_result.relative_drop_signal,
        "low_variability": pulse_result.low_variability,
        "physiological_drowsy_signal": pulse_result.physiological_drowsy_signal,
        "implausible_reading": pulse_result.implausible_reading,
        "fatigue_event": event.risk_level if event else None,
    }


@app.get("/eventos")
def get_events(session_id: str = DEFAULT_SESSION_ID, limit: int = 200):
    """Historial de eventos de fatiga (RF07, RF09)."""
    return {
        "events": database.list_events(session_id=session_id, limit=limit),
        "counts_by_risk": database.event_counts_by_risk(session_id=session_id),
    }


@app.get("/estado")
def get_status(session_id: str = DEFAULT_SESSION_ID):
    """Estado actual de la fusión en tiempo real (RF09, RF10)."""
    status = fusion_engine.get_current_status(session_id)
    status["normal_count"] = database.normal_reading_count(session_id=session_id)
    return status


@app.get("/", response_class=HTMLResponse)
def dashboard(request: Request, session_id: str = DEFAULT_SESSION_ID):
    """Dashboard simple con historial y frecuencia de eventos (RF09, RF10)."""
    events = database.list_events(session_id=session_id, limit=100)
    counts = database.event_counts_by_risk(session_id=session_id)
    normal_count = database.normal_reading_count(session_id=session_id)
    current_status = fusion_engine.get_current_status(session_id)
    return templates.TemplateResponse(
        request,
        "dashboard.html",
        {
            "events": events,
            "counts": counts,
            "normal_count": normal_count,
            "current_status": current_status,
            "session_id": session_id,
        },
    )
