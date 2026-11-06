"""
Control de acceso de SIDFAM: login, roles y permisos.

Roles (de mayor a menor alcance):

  - administrador -> todo lo del supervisor + gestión de usuarios (crear,
                     cambiar rol/sesión, desactivar, restablecer contraseña).
  - supervisor    -> ve TODAS las sesiones en vivo, el historial y la
                     analítica (CRISP-DM), exporta CSV y registra KSS.
  - conductor     -> ve SOLO su sesión asignada (users.session_id) en vivo,
                     su historial y la analítica de SUS datos
                     (analitica_propia), y registra su propio KSS. Sin
                     exportación.

Los permisos son cadenas cortas (PERMISOS) y cada rol es un conjunto de ellas;
los endpoints piden permisos, nunca roles, así añadir un rol nuevo es solo
editar ROLES.

Personas -> cookie de sesión firmada con HMAC (SECRET_KEY). El token lleva
id de usuario, `session_version` y expiración; cambiar o restablecer la
contraseña, o desactivar al usuario, sube `session_version` e invalida todas
sus sesiones abiertas. Contraseñas con PBKDF2-SHA256 (librería estándar).

Dispositivos (ESP32) -> no pueden hacer login: envían la cabecera
`X-Device-Key` con el valor de DEVICE_API_KEY. Si esa variable no está
definida, /frame y /pulso quedan abiertos (cómodo en desarrollo local).

Variables de entorno:
  SECRET_KEY      clave para firmar cookies. Sin ella se genera una aleatoria
                  al arrancar y las sesiones se pierden en cada reinicio.
  DEVICE_API_KEY  clave compartida con el firmware.
  ADMIN_USERNAME / ADMIN_PASSWORD  primer administrador, creado solo si la
                  tabla users está vacía. Sin ADMIN_PASSWORD se genera una
                  contraseña temporal que se imprime en el log.
"""

import hashlib
import hmac
import logging
import os
import re
import secrets
import time
from dataclasses import dataclass, field
from urllib.parse import urlparse

from fastapi import Request

from . import database

log = logging.getLogger("uvicorn.error")

COOKIE_NAME = "sidfam_sesion"
SESSION_TTL_SECONDS = 12 * 3600       # duración de un login
PBKDF2_ITERATIONS = 240_000
MIN_PASSWORD_LENGTH = 8
MAX_FAILED_LOGINS = 5                 # intentos fallidos antes de bloquear...
LOCKOUT_SECONDS = 300                 # ...durante este tiempo

USERNAME_RE = re.compile(r"^[a-z0-9._-]{3,32}$")
SESSION_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")

PERMISOS = {
    "panel": "Ver el panel en vivo y el historial de episodios",
    "todas_sesiones": "Ver cualquier sesión (no solo la propia)",
    "analitica": "Ver la analítica de datos (CRISP-DM) de cualquier sesión",
    "analitica_propia": "Ver la analítica de datos (CRISP-DM) de su propia sesión",
    "exportar": "Descargar lecturas y datasets en CSV",
    "autoreporte": "Registrar el autoreporte de somnolencia (KSS)",
    "usuarios": "Gestionar usuarios y roles",
}

ROLES = {
    "administrador": {
        "label": "Administrador",
        "descripcion": "Control total: gestiona usuarios y roles, y accede a todas las sesiones y a la analítica.",
        "permisos": set(PERMISOS),
    },
    "supervisor": {
        "label": "Supervisor",
        "descripcion": "Monitorea todas las sesiones, consulta la analítica y exporta datos. No gestiona usuarios.",
        "permisos": {"panel", "todas_sesiones", "analitica", "analitica_propia", "exportar", "autoreporte"},
    },
    "conductor": {
        "label": "Conductor",
        "descripcion": "Ve únicamente su propia sesión en vivo, su historial y la analítica de sus datos, y registra su autoreporte KSS.",
        "permisos": {"panel", "autoreporte", "analitica_propia"},
    },
}

SECRET_KEY = os.environ.get("SECRET_KEY") or secrets.token_hex(32)
_SECRET_IS_EPHEMERAL = not os.environ.get("SECRET_KEY")
DEVICE_API_KEY = os.environ.get("DEVICE_API_KEY") or None


# ---------------------------------------------------------------------------
# Excepciones (main.py las traduce a redirección HTML o JSON 401/403)
# ---------------------------------------------------------------------------

class LoginRequired(Exception):
    """No hay sesión válida."""


class PasswordChangeRequired(Exception):
    """El usuario tiene una contraseña temporal y debe cambiarla antes de seguir."""


class Forbidden(Exception):
    def __init__(self, message: str = "No tienes permiso para esta acción"):
        super().__init__(message)
        self.message = message


# ---------------------------------------------------------------------------
# Contraseñas
# ---------------------------------------------------------------------------

def hash_password(password: str) -> str:
    salt = secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), PBKDF2_ITERATIONS)
    return f"pbkdf2_sha256${PBKDF2_ITERATIONS}${salt}${digest.hex()}"


def verify_password(password: str, stored: str) -> bool:
    try:
        algo, iterations, salt, expected = stored.split("$")
    except ValueError:
        return False
    if algo != "pbkdf2_sha256":
        return False
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), int(iterations))
    return hmac.compare_digest(digest.hex(), expected)


# Se usa cuando el usuario no existe, para que la respuesta tarde lo mismo
# y no revele qué nombres de usuario son válidos.
_DUMMY_HASH = hash_password(secrets.token_hex(8))


def password_problem(password: str) -> str | None:
    """Devuelve el motivo por el que una contraseña no sirve, o None si es válida."""
    if len(password) < MIN_PASSWORD_LENGTH:
        return f"La contraseña debe tener al menos {MIN_PASSWORD_LENGTH} caracteres"
    if password.isdigit() or password.isalpha():
        return "La contraseña debe combinar letras y números o símbolos"
    return None


def generate_temp_password() -> str:
    return secrets.token_urlsafe(9)


# ---------------------------------------------------------------------------
# Usuario autenticado
# ---------------------------------------------------------------------------

@dataclass
class User:
    id: int
    username: str
    full_name: str | None
    role: str
    session_id: str | None
    must_change_password: bool
    session_version: int
    permisos: set = field(default_factory=set)

    @classmethod
    def from_row(cls, row: dict) -> "User":
        return cls(
            id=row["id"], username=row["username"], full_name=row.get("full_name"),
            role=row["role"], session_id=row.get("session_id"),
            must_change_password=bool(row.get("must_change_password")),
            session_version=int(row.get("session_version") or 0),
            permisos=set(ROLES.get(row["role"], {}).get("permisos", ())),
        )

    def can(self, permiso: str) -> bool:
        return permiso in self.permisos

    @property
    def display_name(self) -> str:
        return self.full_name or self.username

    @property
    def role_label(self) -> str:
        return ROLES.get(self.role, {}).get("label", self.role)

    def public(self) -> dict:
        return {
            "id": self.id, "username": self.username, "full_name": self.full_name,
            "role": self.role, "role_label": self.role_label, "session_id": self.session_id,
            "permisos": sorted(self.permisos),
            "must_change_password": self.must_change_password,
        }


# ---------------------------------------------------------------------------
# Token de sesión (cookie)
# ---------------------------------------------------------------------------

def _sign(payload: str) -> str:
    return hmac.new(SECRET_KEY.encode(), payload.encode(), hashlib.sha256).hexdigest()


def issue_token(user_id: int, session_version: int) -> str:
    payload = f"{user_id}.{session_version}.{int(time.time()) + SESSION_TTL_SECONDS}"
    return f"{payload}.{_sign(payload)}"


def _read_token(token: str) -> tuple[int, int] | None:
    try:
        user_id, version, expires, signature = token.split(".")
    except ValueError:
        return None
    if not hmac.compare_digest(_sign(f"{user_id}.{version}.{expires}"), signature):
        return None
    if int(expires) < time.time():
        return None
    return int(user_id), int(version)


def is_https(request: Request) -> bool:
    # Railway termina TLS en su proxy y reenvía por HTTP con esta cabecera.
    return request.headers.get("x-forwarded-proto", request.url.scheme) == "https"


def set_session_cookie(response, request: Request, user_id: int, session_version: int) -> None:
    response.set_cookie(
        COOKIE_NAME, issue_token(user_id, session_version),
        max_age=SESSION_TTL_SECONDS, httponly=True, samesite="lax",
        secure=is_https(request), path="/",
    )


def clear_session_cookie(response) -> None:
    response.delete_cookie(COOKIE_NAME, path="/")


def _request_token(request: Request) -> str:
    """Token de la cabecera `Authorization: Bearer ...` (app móvil) o, si no
    viene, de la cookie (panel web). Es el mismo token firmado en ambos casos."""
    header = request.headers.get("authorization", "")
    if header[:7].lower() == "bearer ":
        return header[7:].strip()
    return request.cookies.get(COOKIE_NAME, "")


def get_current_user(request: Request) -> User | None:
    """Usuario del token (cookie o Bearer), o None. Comprueba en BD que siga
    activo y que la sesión no haya sido invalidada (session_version)."""
    if hasattr(request.state, "user"):
        return request.state.user
    user = None
    data = _read_token(_request_token(request))
    if data:
        row = database.get_user(data[0])
        if row and row["active"] and int(row["session_version"]) == data[1] and row["role"] in ROLES:
            user = User.from_row(row)
    request.state.user = user
    return user


def _check_same_origin(request: Request) -> None:
    """Defensa CSRF adicional a SameSite=Lax: una petición que modifica datos
    con la cookie debe venir de esta misma web."""
    if request.method in ("GET", "HEAD", "OPTIONS"):
        return
    # Con Bearer el navegador no adjunta la credencial solo: no hay CSRF posible.
    if request.headers.get("authorization", "")[:7].lower() == "bearer ":
        return
    origin = request.headers.get("origin") or request.headers.get("referer")
    if origin and urlparse(origin).netloc != request.headers.get("host"):
        raise Forbidden("Origen de la petición no permitido")


def require(permiso: str | None = None, allow_password_change: bool = False):
    """Dependencia de FastAPI: exige sesión iniciada y, opcionalmente, un permiso.

        @app.get("/x")
        def x(user: User = Depends(require("analitica"))): ...
    """
    def dependency(request: Request) -> User:
        user = get_current_user(request)
        if user is None:
            raise LoginRequired()
        _check_same_origin(request)
        if user.must_change_password and not allow_password_change:
            raise PasswordChangeRequired()
        if permiso and not user.can(permiso):
            raise Forbidden()
        return user
    return dependency


def require_any(*permisos: str):
    """Como require(), pero basta con tener UNO de los permisos."""
    base = require()

    def dependency(request: Request) -> User:
        user = base(request)
        if not any(user.can(p) for p in permisos):
            raise Forbidden()
        return user
    return dependency


def resolve_session(user: User, requested: str | None) -> str | None:
    """Sesión que el usuario puede consultar. Supervisor/administrador: la pedida
    (o None, y el endpoint elige una por defecto). Conductor: siempre la suya;
    pedir otra es un 403."""
    if user.can("todas_sesiones"):
        return requested or None
    if not user.session_id:
        raise Forbidden("Tu cuenta no tiene una sesión asignada. Pide a un administrador que te asigne una.")
    if requested and requested != user.session_id:
        raise Forbidden("Solo puedes consultar tu propia sesión")
    return user.session_id


# ---------------------------------------------------------------------------
# Dispositivos (ESP32)
# ---------------------------------------------------------------------------

def require_device(request: Request) -> None:
    """Dependencia para /frame y /pulso: valida la cabecera X-Device-Key."""
    if DEVICE_API_KEY is None:
        return
    key = request.headers.get("x-device-key", "")
    if not hmac.compare_digest(key.encode(), DEVICE_API_KEY.encode()):
        raise LoginRequired()


def is_device(request: Request) -> bool:
    """True si la petición trae una X-Device-Key válida (usado por GET /estado,
    para que el ESP32 del pulso pueda consultar la alerta sin iniciar sesión)."""
    if DEVICE_API_KEY is None:
        return False
    key = request.headers.get("x-device-key", "")
    return bool(key) and hmac.compare_digest(key.encode(), DEVICE_API_KEY.encode())


# ---------------------------------------------------------------------------
# Login con bloqueo por intentos fallidos (en memoria, como el resto del estado)
# ---------------------------------------------------------------------------

_failed_logins: dict[str, list[float]] = {}


def _throttle_key(request: Request, username: str) -> str:
    ip = (request.headers.get("x-forwarded-for") or (request.client.host if request.client else "")).split(",")[0].strip()
    return f"{ip}|{username}"


def seconds_locked(request: Request, username: str) -> int:
    now = time.time()
    attempts = [t for t in _failed_logins.get(_throttle_key(request, username), []) if now - t < LOCKOUT_SECONDS]
    if len(attempts) >= MAX_FAILED_LOGINS:
        return int(LOCKOUT_SECONDS - (now - attempts[0])) + 1
    return 0


def authenticate(request: Request, username: str, password: str) -> dict | None:
    """Devuelve la fila del usuario si las credenciales son correctas."""
    key = _throttle_key(request, username)
    row = database.get_user_by_username(username)
    ok = verify_password(password, row["password_hash"] if row else _DUMMY_HASH)
    if row and ok and row["active"]:
        _failed_logins.pop(key, None)
        database.record_login(row["id"])
        return row
    now = time.time()
    _failed_logins[key] = [t for t in _failed_logins.get(key, []) if now - t < LOCKOUT_SECONDS] + [now]
    return None


# ---------------------------------------------------------------------------
# Arranque
# ---------------------------------------------------------------------------

def bootstrap() -> None:
    """Crea el primer administrador si no hay usuarios y avisa de la configuración insegura."""
    if _SECRET_IS_EPHEMERAL:
        log.warning("SIDFAM: SECRET_KEY no está definida; se usa una aleatoria y las sesiones "
                    "se cerrarán en cada reinicio. Defínela en producción.")
    if DEVICE_API_KEY is None:
        log.warning("SIDFAM: DEVICE_API_KEY no está definida; /frame y /pulso aceptan datos de "
                    "cualquiera. Defínela en producción (y en el firmware).")

    if database.count_users() > 0:
        return
    username = (os.environ.get("ADMIN_USERNAME") or "admin").strip().lower()
    password = os.environ.get("ADMIN_PASSWORD")
    generated = not password
    if generated:
        password = generate_temp_password()
    database.create_user(username, hash_password(password), "administrador",
                         full_name="Administrador", must_change_password=generated)
    if generated:
        log.warning("=" * 64)
        log.warning("SIDFAM: se creó el administrador inicial")
        log.warning("  usuario:    %s", username)
        log.warning("  contraseña: %s   (temporal: se pedirá cambiarla al entrar)", password)
        log.warning("=" * 64)
    else:
        log.info("SIDFAM: administrador inicial '%s' creado desde ADMIN_PASSWORD", username)
