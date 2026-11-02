"""
SIDFAM - Backend en la nube.

Endpoints:
  POST /frame     -> recibe una imagen JPEG del ESP32-CAM, la analiza
                      con MediaPipe y actualiza el estado de fusión.
  POST /pulso     -> recibe una lectura de BPM del ESP32 con el sensor
                      de pulso y actualiza el estado de fusión.
  GET  /eventos    -> historial de eventos de fatiga en JSON.
  GET  /estado     -> estado actual de la fusión en tiempo real (JSON).
  GET  /api/flota  -> todos los conductores con su estado, para supervisores (JSON).
  GET  /api/camara -> último frame de la cámara con la vista del modelo (JPEG).
  GET  /api/camara/stream -> la misma cámara como video en vivo (MJPEG), para el panel web.
  POST /api/camara/dispositivo -> foto de la cámara del computador o del celular (con login).
  POST /api/buzzer -> un supervisor hace sonar el buzzer del conductor.
  GET  /            -> dashboard HTML (RF09, RF10).

Analítica de datos (ver app/analytics.py):
  GET  /sesiones               -> sesiones con lecturas guardadas.
  GET  /lecturas               -> lecturas crudas recientes (JSON).
  GET  /lecturas.csv           -> todas las lecturas crudas de la sesión (CSV).
  GET  /analitica/dataset.csv  -> dataset transformado: una fila por ventana (CSV).
  GET  /analitica/reporte      -> proceso CRISP-DM completo (calidad, descriptiva,
                                  K-Means, árbol de decisión, regresión
                                  logística/lineal, anomalías y resumen por fase).
  GET  /analitica/usuarios     -> indicadores de todos los usuarios / sesiones.
  POST /autoreporte            -> autoreporte de somnolencia KSS (1-9).
  GET  /analitica              -> redirige a la sección de analítica del panel (/).

Acceso (ver app/auth.py para los roles y permisos):
  GET/POST /login              -> inicio de sesión.
  POST /logout                 -> cierra la sesión.
  GET/POST /cuenta/clave       -> cambio de la contraseña propia.
  GET  /usuarios               -> gestión de usuarios (solo administrador).
  /api/usuarios...             -> API JSON de esa gestión.

App móvil (Flutter, carpeta mobile/): autenticación con token Bearer.
  POST /api/login              -> {token, user, must_change_password}.
  POST /api/cuenta/clave       -> cambia la contraseña y devuelve un token nuevo.
  GET  /api/config             -> umbrales, roles y parámetros del panel.

/frame y /pulso no usan login: se autentican con la cabecera X-Device-Key
(DEVICE_API_KEY). GET /estado acepta tanto sesión iniciada como esa cabecera. El resto exige sesión iniciada y el permiso del endpoint.

Ejecutar en desarrollo:
  uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
"""

import asyncio
import io
import time
from datetime import datetime
from pathlib import Path
from urllib.parse import quote

import cv2
import numpy as np
from fastapi import Depends, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from fastapi.requests import Request
from pydantic import BaseModel

from . import analytics, auth, database, overlay, pulse, vision
from .auth import User, require
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

# --- Cámara en vivo (solo en memoria, nunca en la base) ---
# Último frame de cada sesión ya anotado con la vista del modelo (JPEG, hora).
_live_frames: dict[str, tuple[bytes, float]] = {}
CAMERA_STALE_SECONDS = 10   # sin frames nuevos en este tiempo, la app muestra "sin video"

# --- Cámara del dispositivo (computador o celular) ---
# Mientras envíe, las fotos del ESP32-CAM de esa sesión se ignoran para no mezclar
# dos cámaras en la misma fusión. Si deja de enviar, el ESP32 retoma solo.
_device_camera_at: dict[str, float] = {}
DEVICE_CAMERA_PRIORITY_SECONDS = 5


def _device_camera_active(session_id: str) -> bool:
    return time.time() - _device_camera_at.get(session_id, 0.0) < DEVICE_CAMERA_PRIORITY_SECONDS

# --- Buzzer del dispositivo del conductor ---
# Suena solo mientras haya alerta confirmada (RF06) o durante el tiempo que pida
# un supervisor. El ESP32 no puede recibir llamadas del servidor (está detrás del
# router), así que se entera en la respuesta de cada /pulso y /frame.
_buzzer_until: dict[str, float] = {}
BUZZER_DEFAULT_SECONDS = 5
BUZZER_MAX_SECONDS = 15


def _buzzer_state(session_id: str, status: dict) -> dict:
    manual = max(0.0, _buzzer_until.get(session_id, 0.0) - time.time())
    auto = status.get("status") == "alerta"
    return {"buzzer": auto or manual > 0, "buzzer_auto": auto, "buzzer_manual_seg": round(manual, 1)}


@app.on_event("startup")
def on_startup():
    database.init_db()
    auth.bootstrap()


# ---------------------------------------------------------------------------
# Errores de acceso: páginas HTML redirigen, la API responde JSON
# ---------------------------------------------------------------------------

def _wants_html(request: Request) -> bool:
    return request.method == "GET" and "text/html" in request.headers.get("accept", "")


@app.exception_handler(auth.LoginRequired)
def _login_required(request: Request, exc: auth.LoginRequired):
    if _wants_html(request):
        next_url = request.url.path + (f"?{request.url.query}" if request.url.query else "")
        return RedirectResponse(f"/login?next={quote(next_url)}", status_code=303)
    return JSONResponse({"detail": "Autenticación requerida"}, status_code=401)


@app.exception_handler(auth.PasswordChangeRequired)
def _password_change_required(request: Request, exc: auth.PasswordChangeRequired):
    if _wants_html(request):
        return RedirectResponse("/cuenta/clave", status_code=303)
    return JSONResponse({"detail": "Debes cambiar tu contraseña temporal antes de continuar"}, status_code=403)


@app.exception_handler(auth.Forbidden)
def _forbidden(request: Request, exc: auth.Forbidden):
    if _wants_html(request):
        return templates.TemplateResponse(
            request, "acceso.html",
            {"user": auth.get_current_user(request), "message": exc.message}, status_code=403)
    return JSONResponse({"detail": exc.message}, status_code=403)


def _persist(session_id: str, event) -> None:
    """Guarda el evento de fatiga (si lo hubo) o suma una lectura normal.
    Solo cuenta como normal el estado "normal": no la vigilancia ni las lecturas
    de una alerta que sigue abierta (esas no generan evento nuevo)."""
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
    elif fusion_engine.get_current_status(session_id)["status"] == "normal":
        database.increment_normal_reading(session_id)


def _process_frame(raw_bytes: bytes, session_id: str) -> dict:
    """Procesa un frame JPEG con MediaPipe, venga del ESP32-CAM o del dispositivo."""
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

    _live_frames[session_id] = (overlay.annotate(image_bgr, vision_result, status), time.time())

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
        "buzzer": _buzzer_state(session_id, status)["buzzer"],
    }


@app.post("/frame", dependencies=[Depends(auth.require_device)])
async def receive_frame(file: UploadFile = File(...), session_id: str = Form(DEFAULT_SESSION_ID)):
    """Recibe un frame JPEG del ESP32-CAM."""
    raw_bytes = await file.read()
    if _device_camera_active(session_id):
        status = fusion_engine.get_current_status(session_id)
        return {
            "ignorado": True,   # esta sesión usa la cámara del dispositivo
            "estado": status["status"],
            "alerta": status["status"] == "alerta",
            "nivel_riesgo": status["risk_level"],
            "buzzer": _buzzer_state(session_id, status)["buzzer"],
        }
    return _process_frame(raw_bytes, session_id)


@app.post("/api/camara/dispositivo")
async def receive_device_frame(file: UploadFile = File(...), session_id: str | None = Form(None),
                               user: User = Depends(require("panel"))):
    """Recibe un frame de la cámara del computador o del celular. Va por aparte de
    /frame: se autentica con el login del usuario y no con la clave del ESP32."""
    session_id = auth.resolve_session(user, session_id) or DEFAULT_SESSION_ID
    if session_id == analytics.TODAS:
        raise HTTPException(status_code=422, detail="Elige una sesión concreta para enviar la cámara")
    result = _process_frame(await file.read(), session_id)
    if "error" not in result:
        _device_camera_at[session_id] = time.time()
    return result


@app.post("/pulso", dependencies=[Depends(auth.require_device)])
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
        # el ESP32 de pulso hace sonar el buzzer mientras esto sea true
        "buzzer": _buzzer_state(session_id, status)["buzzer"],
    }


# El resumen por minuto revisa hasta 24 h de lecturas y cambia despacio, pero
# /eventos se consulta cada 4 s: se recalcula como mucho una vez por este intervalo.
MINUTES_CACHE_SECONDS = 30
_minutes_cache: dict[str, tuple[float, dict]] = {}


def _minute_summary(session_id: str) -> dict:
    cached = _minutes_cache.get(session_id)
    if cached and time.time() - cached[0] < MINUTES_CACHE_SECONDS:
        return cached[1]
    summary = database.minute_summary(session_id)
    _minutes_cache[session_id] = (time.time(), summary)
    return summary


@app.get("/eventos")
def get_events(session_id: str | None = None, limit: int = 200, user: User = Depends(require("panel"))):
    """Historial de eventos de fatiga (RF07, RF09)."""
    session_id = auth.resolve_session(user, session_id) or DEFAULT_SESSION_ID
    return {
        "events": database.list_events(session_id=session_id, limit=limit),
        "counts_by_risk": database.event_counts_by_risk(session_id=session_id),
        # minutos recientes ya resumidos: "normales" y "vigilancias" (máximo 20 de cada uno)
        **_minute_summary(session_id),
    }


@app.get("/estado")
def get_status(request: Request, session_id: str | None = None):
    """Estado actual de la fusión en tiempo real (RF09, RF10).

    Acepta sesión iniciada (panel) o la cabecera X-Device-Key (ESP32 del pulso,
    que consulta aquí si debe activar la alerta)."""
    if auth.is_device(request):
        session_id = session_id or DEFAULT_SESSION_ID
    else:
        user = require("panel")(request)
        session_id = auth.resolve_session(user, session_id) or DEFAULT_SESSION_ID
    status = fusion_engine.get_current_status(session_id)
    status["normal_count"] = database.normal_reading_count(session_id=session_id)
    # Tras reiniciar el servidor la memoria está vacía: se envía lo último guardado
    # (cámara y pulso por separado) para que el panel no aparezca vacío.
    status["ultima_guardada"] = None if status["has_any_data"] else database.last_readings(session_id)
    status.update(_buzzer_state(session_id, status))
    frame = _live_frames.get(session_id)
    status["camara_activa"] = bool(frame and time.time() - frame[1] <= CAMERA_STALE_SECONDS)
    status["camara_fuente"] = ("dispositivo" if _device_camera_active(session_id)
                               else "esp32" if status["camara_activa"] else None)
    return status


@app.get("/api/camara")
def get_camera_frame(session_id: str | None = None, user: User = Depends(require("panel"))):
    """Último frame de la cámara con la vista del modelo dibujada (image/jpeg).
    204 si no llegan frames de esa sesión hace más de CAMERA_STALE_SECONDS."""
    session_id = auth.resolve_session(user, session_id) or DEFAULT_SESSION_ID
    frame = _live_frames.get(session_id)
    if not frame or time.time() - frame[1] > CAMERA_STALE_SECONDS:
        return Response(status_code=204)
    return Response(frame[0], media_type="image/jpeg", headers={
        "Cache-Control": "no-store",
        "X-Frame-Age": f"{time.time() - frame[1]:.1f}",
    })


@app.get("/api/camara/stream")
async def stream_camera(request: Request, session_id: str | None = None, user: User = Depends(require("panel"))):
    """Cámara en vivo como video MJPEG (multipart/x-mixed-replace): una sola
    conexión por la que se empuja cada frame nuevo apenas llega del ESP32-CAM.
    El navegador lo reproduce como video en un <img>. La fluidez la marca el
    ritmo de envío del ESP32 (~3 fps). El stream se cierra si deja de haber
    frames durante CAMERA_STALE_SECONDS; el panel lo vuelve a abrir solo."""
    session_id = auth.resolve_session(user, session_id) or DEFAULT_SESSION_ID

    async def frames():
        last_ts = 0.0
        while not await request.is_disconnected():
            frame = _live_frames.get(session_id)
            if not frame or time.time() - frame[1] > CAMERA_STALE_SECONDS:
                break
            if frame[1] != last_ts:
                last_ts = frame[1]
                yield (b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: "
                       + str(len(frame[0])).encode() + b"\r\n\r\n" + frame[0] + b"\r\n")
            await asyncio.sleep(0.05)

    return StreamingResponse(frames(), media_type="multipart/x-mixed-replace; boundary=frame", headers={
        "Cache-Control": "no-store",
        "X-Accel-Buffering": "no",   # que ningún proxy acumule los frames
    })


class BuzzerIn(BaseModel):
    session_id: str
    segundos: int = BUZZER_DEFAULT_SECONDS


@app.post("/api/buzzer", dependencies=[Depends(require("todas_sesiones"))])
def trigger_buzzer(body: BuzzerIn):
    """Un supervisor hace sonar el buzzer del conductor durante unos segundos.
    El dispositivo lo recibe en su siguiente envío (cada ~2 s)."""
    segundos = max(1, min(BUZZER_MAX_SECONDS, body.segundos))
    _buzzer_until[body.session_id] = time.time() + segundos
    return {"session_id": body.session_id, "segundos": segundos}


# Orden de la vista de flota: lo más urgente primero
_FLEET_ORDER = ["alerta-alto", "alerta-medio", "advertencia_sensor", "vigilancia", "normal", "sindatos"]


@app.get("/api/flota", dependencies=[Depends(require("todas_sesiones"))])
def get_fleet():
    """Vista de flota para supervisores: cada conductor (o sesión con lecturas)
    con su estado actual, último pulso/EAR, antigüedad de la última lectura y
    eventos de hoy, ordenados por urgencia."""
    sesiones = {s["session_id"]: s for s in database.list_sessions()}
    conductores = {
        u["session_id"]: u for u in database.list_users()
        if u["role"] == "conductor" and u.get("session_id") and u.get("active")
    }
    eventos = database.fleet_event_summary()
    now = datetime.now()
    items = []
    for sid in set(sesiones) | set(conductores):
        st = fusion_engine.get_current_status(sid)
        u, s, ev = conductores.get(sid), sesiones.get(sid), eventos.get(sid, {})
        if not st["has_any_data"]:
            estado = "sindatos"
        elif st["status"] == "alerta":
            estado = f"alerta-{st['risk_level'] or 'medio'}"
        else:
            estado = st["status"]
        guardada = None if st["has_any_data"] else database.last_readings(sid)
        bpm = st["bpm"] if st["has_any_data"] else ((guardada or {}).get("pulso") or {}).get("bpm")
        ear = st["ear"] if st["has_any_data"] else ((guardada or {}).get("frame") or {}).get("ear")
        edad = None
        if s and s.get("hasta"):
            edad = max(0, round((now - datetime.fromisoformat(str(s["hasta"]))).total_seconds()))
        items.append({
            "session_id": sid,
            "conductor": (u.get("full_name") or u["username"]) if u else None,
            "username": u["username"] if u else None,
            "estado": estado,
            "en_vivo": bool(st["data_is_fresh"]),
            "detail": st["detail"],
            "bpm": bpm,
            "ear": ear,
            "baseline_bpm": st["baseline_bpm"],
            "lecturas": int(s["lecturas"]) if s else 0,
            "ultima_lectura_seg": edad,
            "eventos_hoy": ev.get("hoy", {}),
            "ultimo_evento": ev.get("ultimo"),
        })
    items.sort(key=lambda i: (_FLEET_ORDER.index(i["estado"]) if i["estado"] in _FLEET_ORDER else 9,
                              i["ultima_lectura_seg"] if i["ultima_lectura_seg"] is not None else 10**9))
    resumen = {k: sum(1 for i in items if i["estado"] == k) for k in _FLEET_ORDER}
    return {"conductores": items, "resumen": resumen}


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


@app.get("/sesiones", dependencies=[Depends(require("todas_sesiones"))])
def get_sessions():
    """Sesiones de monitoreo con lecturas guardadas."""
    return {"sesiones": database.list_sessions()}


@app.get("/lecturas", dependencies=[Depends(require("analitica"))])
def get_readings(session_id: str = DEFAULT_SESSION_ID, limit: int = 200):
    """Lecturas crudas más recientes (frames y pulso)."""
    return {"lecturas": database.list_readings(session_id=session_id, limit=limit, newest_first=True)}


@app.get("/lecturas.csv", dependencies=[Depends(require("exportar"))])
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


@app.get("/analitica/dataset.csv", dependencies=[Depends(require("exportar"))])
def export_dataset(session_id: str = DEFAULT_SESSION_ID, ventana: int = analytics.VENTANA_DEFECTO_S):
    """Exporta el dataset ya preprocesado y transformado (una fila por ventana).
    session_id="todas" exporta todas las sesiones."""
    df = analytics.windows_dataframe(session_id, _check_window(ventana))
    return _csv_response(df, f"dataset_ventanas_{session_id}_{ventana}s.csv")


@app.get("/analitica/reporte")
def analytics_report(session_id: str | None = None, ventana: int = analytics.VENTANA_DEFECTO_S,
                     user: User = Depends(auth.require_any("analitica", "analitica_propia"))):
    """Proceso CRISP-DM completo. session_id="todas" analiza todas las sesiones y,
    con 3 o más personas, evalúa los modelos separando por persona. Con solo
    "analitica_propia" (conductor) se analiza siempre la sesión propia."""
    session_id = auth.resolve_session(user, session_id) or DEFAULT_SESSION_ID
    return analytics.full_report(session_id, _check_window(ventana))


@app.get("/analitica/usuarios", dependencies=[Depends(require("analitica")), Depends(require("todas_sesiones"))])
def analytics_users():
    """Panel de todos los usuarios: indicadores por persona / sesión para compararlas."""
    return analytics.users_overview()


@app.post("/autoreporte")
def self_report(kss: int = Form(...), session_id: str | None = Form(None),
                note: str | None = Form(None), user: User = Depends(require("autoreporte"))):
    """Autoreporte de somnolencia con la escala KSS (1 = muy alerta ... 9 = muy
    somnoliento). Es la etiqueta real para evaluar los modelos supervisados.
    Un conductor solo puede registrarlo en su propia sesión."""
    session_id = auth.resolve_session(user, session_id) or DEFAULT_SESSION_ID
    if session_id == analytics.TODAS:
        raise HTTPException(status_code=422, detail="Elige una sesión concreta para registrar el KSS")
    if not 1 <= kss <= 9:
        raise HTTPException(status_code=422, detail="kss debe estar entre 1 y 9")
    database.save_self_report(session_id, time.time(), kss, note)
    return {"ok": True, "session_id": session_id, "kss": kss}


@app.get("/analitica", dependencies=[Depends(require("analitica"))])
def analytics_page(session_id: str = DEFAULT_SESSION_ID):
    """La analítica ahora está en la misma página del panel: redirige a esa sección."""
    return RedirectResponse(url=f"/?session_id={quote(session_id)}#analitica")


@app.get("/", response_class=HTMLResponse)
def dashboard(request: Request, session_id: str | None = None, user: User = Depends(require("panel"))):
    """Panel único: estado en vivo, historial (RF09, RF10) y analítica de datos.

    Si la URL no trae ?session_id=..., se muestra la sesión que recibió
    lecturas más recientemente (así el enlace de Railway abre directo la prueba
    en curso). Un conductor siempre ve su propia sesión."""
    session_id = auth.resolve_session(user, session_id)
    if session_id == analytics.TODAS and not user.can("analitica"):
        raise auth.Forbidden()
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
            "user": user,
            "perms": sorted(user.permisos),
            # Umbrales reales para marcar el límite en las barras del dashboard
            "thresholds": {
                "ear": vision.EAR_THRESHOLD,
                "mar": vision.MAR_THRESHOLD,
                "head_tilt_deg": vision.HEAD_TILT_THRESHOLD_DEG,
                "relative_drop": pulse.RELATIVE_DROP_THRESHOLD,
                "low_variability_std": pulse.LOW_VARIABILITY_STD,
            },
        },
    )


# ---------------------------------------------------------------------------
# Login, logout y contraseña propia
# ---------------------------------------------------------------------------

def _safe_next(next_url: str | None) -> str:
    """Solo rutas internas, para que ?next= no sirva de redirección abierta."""
    if next_url and next_url.startswith("/") and not next_url.startswith("//") and "\\" not in next_url:
        return next_url
    return "/"


@app.get("/login", response_class=HTMLResponse)
def login_page(request: Request, next: str | None = None):
    if auth.get_current_user(request):
        return RedirectResponse(_safe_next(next), status_code=303)
    return templates.TemplateResponse(request, "login.html", {"next": _safe_next(next), "error": None, "username": ""})


@app.post("/login", response_class=HTMLResponse)
def login(request: Request, username: str = Form(...), password: str = Form(...), next: str = Form("/")):
    username = username.strip().lower()
    ctx = {"next": _safe_next(next), "username": username}
    locked = auth.seconds_locked(request, username)
    if locked:
        ctx["error"] = f"Demasiados intentos fallidos. Espera {max(1, round(locked / 60))} min e inténtalo de nuevo."
        return templates.TemplateResponse(request, "login.html", ctx, status_code=429)
    row = auth.authenticate(request, username, password)
    if row is None:
        ctx["error"] = "Usuario o contraseña incorrectos"
        return templates.TemplateResponse(request, "login.html", ctx, status_code=401)
    target = "/cuenta/clave" if row["must_change_password"] else ctx["next"]
    response = RedirectResponse(target, status_code=303)
    auth.set_session_cookie(response, request, row["id"], int(row["session_version"]))
    return response


@app.post("/logout")
def logout():
    response = RedirectResponse("/login", status_code=303)
    auth.clear_session_cookie(response)
    return response


@app.get("/cuenta/clave", response_class=HTMLResponse)
def password_page(request: Request, user: User = Depends(require(allow_password_change=True))):
    return templates.TemplateResponse(request, "cambiar_clave.html", {
        "user": user, "error": None, "min_password": auth.MIN_PASSWORD_LENGTH})


def _apply_password_change(user: User, actual: str, nueva: str, confirmar: str) -> tuple[str | None, int]:
    """Valida y guarda la nueva contraseña. Devuelve (error, nueva session_version)."""
    row = database.get_user(user.id)
    if not auth.verify_password(actual, row["password_hash"]):
        error = "La contraseña actual no es correcta"
    elif nueva != confirmar:
        error = "La nueva contraseña y su confirmación no coinciden"
    elif nueva == actual:
        error = "La nueva contraseña debe ser distinta de la actual"
    else:
        error = auth.password_problem(nueva)
    if error:
        return error, user.session_version
    new_version = user.session_version + 1   # cierra las demás sesiones abiertas
    database.update_user(user.id, password_hash=auth.hash_password(nueva),
                         must_change_password=False, session_version=new_version)
    return None, new_version


@app.post("/cuenta/clave", response_class=HTMLResponse)
def change_password(request: Request, actual: str = Form(...), nueva: str = Form(...), confirmar: str = Form(...),
                    user: User = Depends(require(allow_password_change=True))):
    error, new_version = _apply_password_change(user, actual, nueva, confirmar)
    if error:
        return templates.TemplateResponse(request, "cambiar_clave.html", {
            "user": user, "error": error, "min_password": auth.MIN_PASSWORD_LENGTH}, status_code=400)
    response = RedirectResponse("/", status_code=303)
    auth.set_session_cookie(response, request, user.id, new_version)
    return response


@app.get("/api/yo")
def whoami(user: User = Depends(require(allow_password_change=True))):
    return user.public()


# ---------------------------------------------------------------------------
# API JSON para la app móvil (Flutter, carpeta mobile/)
#
# Mismo token firmado que la cookie, pero entregado en el cuerpo y enviado
# después en `Authorization: Bearer <token>`. El resto de endpoints JSON
# (/estado, /eventos, /analitica/..., /api/usuarios...) se usan tal cual.
# ---------------------------------------------------------------------------

class LoginIn(BaseModel):
    username: str
    password: str


class PasswordChangeIn(BaseModel):
    actual: str
    nueva: str
    confirmar: str


def _token_payload(user_row: dict, session_version: int) -> dict:
    user = auth.User.from_row({**user_row, "session_version": session_version})
    return {
        "token": auth.issue_token(user.id, session_version),
        "expires_in": auth.SESSION_TTL_SECONDS,
        "must_change_password": user.must_change_password,
        "user": user.public(),
    }


@app.post("/api/login")
def api_login(request: Request, data: LoginIn):
    username = data.username.strip().lower()
    locked = auth.seconds_locked(request, username)
    if locked:
        raise HTTPException(status_code=429, detail=f"Demasiados intentos fallidos. Espera {max(1, round(locked / 60))} min e inténtalo de nuevo.")
    row = auth.authenticate(request, username, data.password)
    if row is None:
        raise HTTPException(status_code=401, detail="Usuario o contraseña incorrectos")
    return _token_payload(row, int(row["session_version"]))


@app.post("/api/cuenta/clave")
def api_change_password(data: PasswordChangeIn, user: User = Depends(require(allow_password_change=True))):
    error, new_version = _apply_password_change(user, data.actual, data.nueva, data.confirmar)
    if error:
        raise HTTPException(status_code=400, detail=error)
    # El token anterior queda revocado (session_version subió): se entrega uno nuevo.
    return _token_payload(database.get_user(user.id), new_version)


@app.get("/api/config")
def api_config(user: User = Depends(require(allow_password_change=True))):
    """Umbrales y catálogo de roles que el panel web recibe incrustados en el HTML."""
    return {
        "thresholds": {
            "ear": vision.EAR_THRESHOLD,
            "mar": vision.MAR_THRESHOLD,
            "head_tilt_deg": vision.HEAD_TILT_THRESHOLD_DEG,
            "relative_drop": pulse.RELATIVE_DROP_THRESHOLD,
            "low_variability_std": pulse.LOW_VARIABILITY_STD,
        },
        "roles": {k: {"label": v["label"], "descripcion": v["descripcion"], "permisos": sorted(v["permisos"])}
                  for k, v in auth.ROLES.items()},
        "permisos": auth.PERMISOS,
        "min_password": auth.MIN_PASSWORD_LENGTH,
        "ventana_defecto": analytics.VENTANA_DEFECTO_S,
    }


# ---------------------------------------------------------------------------
# Gestión de usuarios (permiso "usuarios": solo administrador)
# ---------------------------------------------------------------------------

class UserCreate(BaseModel):
    username: str
    full_name: str | None = None
    role: str
    session_id: str | None = None
    password: str | None = None      # vacía -> se genera una temporal


class UserUpdate(BaseModel):
    full_name: str | None = None
    role: str | None = None
    session_id: str | None = None
    active: bool | None = None


class PasswordReset(BaseModel):
    password: str | None = None      # vacía -> se genera una temporal


def _public_user(row: dict) -> dict:
    row = dict(row)
    row.pop("password_hash", None)
    row.pop("session_version", None)
    row["role_label"] = auth.ROLES.get(row["role"], {}).get("label", row["role"])
    return row


def _validate_role_session(role: str, session_id: str | None) -> str | None:
    if role not in auth.ROLES:
        raise HTTPException(status_code=422, detail="Rol no válido")
    session_id = (session_id or "").strip() or None
    if session_id and not auth.SESSION_ID_RE.match(session_id):
        raise HTTPException(status_code=422, detail="La sesión solo admite letras, números, punto, guion y guion bajo")
    if role == "conductor" and not session_id:
        raise HTTPException(status_code=422, detail="Un conductor necesita una sesión asignada (el session_id de sus dispositivos)")
    return session_id


def _would_leave_without_admin(target: dict, new_role: str | None, new_active: bool | None) -> bool:
    if target["role"] != "administrador" or not target["active"]:
        return False
    loses_admin = (new_role is not None and new_role != "administrador") or new_active is False
    return loses_admin and database.count_users(role="administrador", only_active=True) <= 1


@app.get("/usuarios", response_class=HTMLResponse)
def users_page(request: Request, user: User = Depends(require("usuarios"))):
    roles = {k: {**v, "permisos": sorted(v["permisos"])} for k, v in auth.ROLES.items()}
    return templates.TemplateResponse(request, "usuarios.html", {
        "user": user, "roles": roles, "permisos": auth.PERMISOS,
        "min_password": auth.MIN_PASSWORD_LENGTH,
    })


@app.get("/api/usuarios", dependencies=[Depends(require("usuarios"))])
def api_list_users():
    return {"usuarios": [_public_user(u) for u in database.list_users()]}


@app.post("/api/usuarios", status_code=201, dependencies=[Depends(require("usuarios"))])
def api_create_user(data: UserCreate):
    username = data.username.strip().lower()
    if not auth.USERNAME_RE.match(username):
        raise HTTPException(status_code=422, detail="Usuario: 3-32 caracteres en minúscula (letras, números, . _ -)")
    if database.get_user_by_username(username):
        raise HTTPException(status_code=409, detail="Ya existe un usuario con ese nombre")
    session_id = _validate_role_session(data.role, data.session_id)
    temp = not data.password
    password = data.password or auth.generate_temp_password()
    if not temp and (problem := auth.password_problem(password)):
        raise HTTPException(status_code=422, detail=problem)
    # Siempre se pide cambiarla en el primer login: quien crea la cuenta no debe
    # conocer la contraseña definitiva de nadie.
    new_id = database.create_user(username, auth.hash_password(password), data.role,
                                  full_name=(data.full_name or "").strip() or None,
                                  session_id=session_id, must_change_password=True)
    return {"usuario": _public_user(database.get_user(new_id)),
            "password_temporal": password if temp else None}


@app.patch("/api/usuarios/{user_id}")
def api_update_user(user_id: int, data: UserUpdate, user: User = Depends(require("usuarios"))):
    target = database.get_user(user_id)
    if not target:
        raise HTTPException(status_code=404, detail="Usuario no encontrado")
    if user_id == user.id and (data.active is False or (data.role and data.role != user.role)):
        raise HTTPException(status_code=422, detail="No puedes desactivarte ni cambiarte el rol a ti mismo")
    if _would_leave_without_admin(target, data.role, data.active):
        raise HTTPException(status_code=422, detail="Debe quedar al menos un administrador activo")

    role = data.role or target["role"]
    session_id = data.session_id if data.session_id is not None else target["session_id"]
    changes = {"role": role, "session_id": _validate_role_session(role, session_id)}
    if data.full_name is not None:
        changes["full_name"] = data.full_name.strip() or None
    if data.active is not None:
        changes["active"] = data.active
    # Cambiar el rol o la sesión, o desactivar, cierra sus sesiones abiertas.
    if (changes["role"] != target["role"] or changes["session_id"] != target["session_id"]
            or (data.active is not None and data.active != target["active"])):
        changes["session_version"] = int(target["session_version"]) + 1
    database.update_user(user_id, **changes)
    return {"usuario": _public_user(database.get_user(user_id))}


@app.post("/api/usuarios/{user_id}/clave", dependencies=[Depends(require("usuarios"))])
def api_reset_password(user_id: int, data: PasswordReset):
    target = database.get_user(user_id)
    if not target:
        raise HTTPException(status_code=404, detail="Usuario no encontrado")
    temp = not data.password
    password = data.password or auth.generate_temp_password()
    if not temp and (problem := auth.password_problem(password)):
        raise HTTPException(status_code=422, detail=problem)
    database.update_user(user_id, password_hash=auth.hash_password(password), must_change_password=True,
                         session_version=int(target["session_version"]) + 1)
    return {"ok": True, "password_temporal": password if temp else None}
