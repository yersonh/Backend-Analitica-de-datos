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

Acceso (ver app/auth.py para los roles y permisos):
  GET/POST /login              -> inicio de sesión.
  POST /logout                 -> cierra la sesión.
  GET/POST /cuenta/clave       -> cambio de la contraseña propia.
  GET  /usuarios               -> gestión de usuarios (solo administrador).
  /api/usuarios...             -> API JSON de esa gestión.

/frame y /pulso no usan login: se autentican con la cabecera X-Device-Key
(DEVICE_API_KEY). El resto exige sesión iniciada y el permiso del endpoint.

Ejecutar en desarrollo:
  uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
"""

import io
import time
from pathlib import Path
from urllib.parse import quote

import cv2
import numpy as np
from fastapi import Depends, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from fastapi.requests import Request
from pydantic import BaseModel

from . import analytics, auth, database, pulse, vision
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


@app.post("/frame", dependencies=[Depends(auth.require_device)])
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
    }


@app.get("/eventos")
def get_events(session_id: str | None = None, limit: int = 200, user: User = Depends(require("panel"))):
    """Historial de eventos de fatiga (RF07, RF09)."""
    session_id = auth.resolve_session(user, session_id) or DEFAULT_SESSION_ID
    return {
        "events": database.list_events(session_id=session_id, limit=limit),
        "counts_by_risk": database.event_counts_by_risk(session_id=session_id),
    }


@app.get("/estado")
def get_status(session_id: str | None = None, user: User = Depends(require("panel"))):
    """Estado actual de la fusión en tiempo real (RF09, RF10)."""
    session_id = auth.resolve_session(user, session_id) or DEFAULT_SESSION_ID
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


@app.get("/analitica/reporte", dependencies=[Depends(require("analitica"))])
def analytics_report(session_id: str = DEFAULT_SESSION_ID, ventana: int = analytics.VENTANA_DEFECTO_S):
    """Proceso KDD completo. session_id="todas" analiza todas las sesiones y,
    con 3 o más personas, evalúa el árbol separando por persona."""
    return analytics.full_report(session_id, _check_window(ventana))


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


@app.post("/cuenta/clave", response_class=HTMLResponse)
def change_password(request: Request, actual: str = Form(...), nueva: str = Form(...), confirmar: str = Form(...),
                    user: User = Depends(require(allow_password_change=True))):
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
        return templates.TemplateResponse(request, "cambiar_clave.html", {
            "user": user, "error": error, "min_password": auth.MIN_PASSWORD_LENGTH}, status_code=400)
    new_version = user.session_version + 1   # cierra las demás sesiones abiertas
    database.update_user(user.id, password_hash=auth.hash_password(nueva),
                         must_change_password=False, session_version=new_version)
    response = RedirectResponse("/", status_code=303)
    auth.set_session_cookie(response, request, user.id, new_version)
    return response


@app.get("/api/yo")
def whoami(user: User = Depends(require(allow_password_change=True))):
    return user.public()


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
