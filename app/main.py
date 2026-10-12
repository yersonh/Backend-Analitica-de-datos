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

Analítica de datos (ver app/analytics.py):
  GET  /sesiones               -> sesiones con lecturas guardadas.
  GET  /lecturas               -> lecturas crudas recientes (JSON).
  GET  /lecturas.csv           -> todas las lecturas crudas de la sesión (CSV).
  GET  /analitica/dataset.csv  -> dataset transformado: una fila por ventana (CSV).
  GET  /analitica/reporte      -> proceso KDD completo (calidad, descriptiva,
                                  K-Means, árbol de decisión, anomalías).
  POST /autoreporte            -> autoreporte de somnolencia KSS (1-9).
  GET  /analitica              -> redirige a la sección de analítica del panel (/).

Ejecutar en desarrollo:
  uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
"""

import io
import time
from pathlib import Path
from urllib.parse import quote

import cv2
import numpy as np
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import HTMLResponse, RedirectResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from fastapi.requests import Request

from . import analytics, database
from .fusion import fusion_engine
from .pulse import pulse_analyzer
from .vision import face_analyzer

app = FastAPI(title="SIDFAM Backend")

templates = Jinja2Templates(directory=str(Path(__file__).parent / "templates"))

# Recursos estáticos del dashboard (imagen de fondo, etc.)
app.mount(
    "/imagenes",
    StaticFiles(directory=str(Path(__file__).parent / "Imagenes")),
    name="imagenes",
)

DEFAULT_SESSION_ID = "default"


@app.on_event("startup")
def on_startup():
    database.init_db()


def _persist(session_id: str, event) -> None:
    """Guarda el evento de fatiga (si lo hubo) o suma una lectura normal."""
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
    _persist(session_id, event)

    # Lectura cruda para la analítica (una fila por frame)
    status = fusion_engine.get_current_status(session_id)
    database.save_reading(
        session_id, time.time(), "frame",
        face_detected=vision_result.face_detected,
        ear=vision_result.ear,
        mar=vision_result.mar,
        head_tilt_deg=vision_result.head_tilt_deg,
        eyes_closed=vision_result.eyes_closed if vision_result.face_detected else None,
        yawning=vision_result.yawning if vision_result.face_detected else None,
        head_tilted=vision_result.head_tilted if vision_result.face_detected else None,
        fusion_status=status["status"],
        risk_level=status["risk_level"],
    )

    return {
        "face_detected": vision_result.face_detected,
        "ear": vision_result.ear,
        "mar": vision_result.mar,
        "head_tilt_deg": vision_result.head_tilt_deg,
        "eyes_closed": vision_result.eyes_closed,
        "yawning": vision_result.yawning,
        "fatigue_event": event.risk_level if event else None,
        # Para el firmware (RF06): mientras "alerta" sea true, buzzer/LED encendidos
        "estado": status["status"],
        "alerta": status["status"] == "alerta",
        "nivel_riesgo": status["risk_level"],
    }


@app.post("/pulso")
async def receive_pulse(bpm: float = Form(...), session_id: str = Form(DEFAULT_SESSION_ID)):
    """Recibe una lectura de BPM del ESP32 con el sensor de pulso."""
    pulse_result = pulse_analyzer.add_reading(session_id, bpm)
    event = fusion_engine.update_pulse(session_id, pulse_result)
    _persist(session_id, event)

    # Lectura cruda para la analítica (una fila por lectura de pulso)
    status = fusion_engine.get_current_status(session_id)
    database.save_reading(
        session_id, time.time(), "pulso",
        bpm=pulse_result.bpm_current,
        bpm_mean=pulse_result.bpm_mean,
        bpm_std=pulse_result.bpm_std,
        baseline_bpm=pulse_result.baseline_bpm,
        implausible_reading=pulse_result.implausible_reading,
        fusion_status=status["status"],
        risk_level=status["risk_level"],
    )

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
        "estado": status["status"],
        "alerta": status["status"] == "alerta",
        "nivel_riesgo": status["risk_level"],
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


# ---------------------------------------------------------------------------
# Analítica de datos
# ---------------------------------------------------------------------------

def _csv_response(df, filename: str) -> StreamingResponse:
    buf = io.StringIO()
    df.to_csv(buf, index=False)
    buf.seek(0)
    return StreamingResponse(
        iter([buf.getvalue()]),
        media_type="text/csv",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


@app.get("/sesiones")
def get_sessions():
    """Sesiones de monitoreo con lecturas guardadas."""
    return {"sesiones": database.list_sessions()}


@app.get("/lecturas")
def get_readings(session_id: str = DEFAULT_SESSION_ID, limit: int = 200):
    """Lecturas crudas más recientes (frames y pulso)."""
    return {"lecturas": database.list_readings(session_id=session_id, limit=limit, newest_first=True)}


@app.get("/lecturas.csv")
def export_readings(session_id: str = DEFAULT_SESSION_ID):
    """Exporta TODAS las lecturas crudas de la sesión (para Excel, Weka, Python...)."""
    import pandas as pd
    df = pd.DataFrame(database.list_readings(
        session_id=None if session_id == analytics.TODAS else session_id))
    for c in ("face_detected", "eyes_closed", "yawning", "head_tilted", "implausible_reading"):
        if c in df:
            df[c] = df[c].astype("Int64")   # 0/1 sin el ".0" que deja pandas por los nulos
    return _csv_response(df, f"lecturas_{session_id}.csv")


def _check_window(ventana: int) -> int:
    if not 5 <= ventana <= 600:
        raise HTTPException(status_code=422, detail="ventana debe estar entre 5 y 600 segundos")
    return ventana


@app.get("/analitica/dataset.csv")
def export_dataset(session_id: str = DEFAULT_SESSION_ID, ventana: int = analytics.VENTANA_DEFECTO_S):
    """Exporta el dataset ya preprocesado y transformado (una fila por ventana).
    session_id="todas" exporta todas las sesiones."""
    df = analytics.windows_dataframe(session_id, _check_window(ventana))
    return _csv_response(df, f"dataset_ventanas_{session_id}_{ventana}s.csv")


@app.get("/analitica/reporte")
def analytics_report(session_id: str = DEFAULT_SESSION_ID, ventana: int = analytics.VENTANA_DEFECTO_S):
    """Proceso KDD completo. session_id="todas" analiza todas las sesiones y,
    con 3 o más personas, evalúa el árbol separando por persona."""
    return analytics.full_report(session_id, _check_window(ventana))


@app.post("/autoreporte")
def self_report(kss: int = Form(...), session_id: str = Form(DEFAULT_SESSION_ID),
                note: str | None = Form(None)):
    """Autoreporte de somnolencia con la escala KSS (1 = muy alerta ... 9 = muy
    somnoliento). Es la etiqueta real para evaluar los modelos supervisados."""
    if not 1 <= kss <= 9:
        raise HTTPException(status_code=422, detail="kss debe estar entre 1 y 9")
    database.save_self_report(session_id, time.time(), kss, note)
    return {"ok": True, "session_id": session_id, "kss": kss}


@app.get("/analitica")
def analytics_page(session_id: str = DEFAULT_SESSION_ID):
    """La analítica ahora está en la misma página del panel: redirige a esa sección."""
    return RedirectResponse(url=f"/?session_id={quote(session_id)}#analitica")


@app.get("/", response_class=HTMLResponse)
def dashboard(request: Request, session_id: str | None = None):
    """Panel único: estado en vivo, historial (RF09, RF10) y analítica de datos.

    Si la URL no trae ?session_id=..., se muestra la sesión que recibió
    lecturas más recientemente (así el enlace de Railway abre directo la prueba
    en curso)."""
    if not session_id:
        sesiones = database.list_sessions()
        session_id = sesiones[0]["session_id"] if sesiones else DEFAULT_SESSION_ID
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