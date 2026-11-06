"""
Persistencia de eventos de fatiga (RF07: fecha, hora, nivel de riesgo).

Soporta DOS motores según el entorno, sin que el resto de la app se entere:

  - Si existe la variable de entorno DATABASE_URL (Railway la inyecta al
    vincular un servicio de PostgreSQL), se usa PostgreSQL vía psycopg2.
    Así el historial NO se pierde entre deploys.
  - Si no existe (desarrollo local sin Postgres instalado), se cae
    automáticamente a SQLite en app/sidfam.db, con el mismo comportamiento
    de antes.

Las firmas de las funciones públicas (init_db, save_event, list_events,
event_counts_by_risk, increment_normal_reading, normal_reading_count,
save_reading, list_readings, save_self_report, list_self_reports,
list_sessions y las de usuarios) son idénticas en ambos casos: app/main.py no necesita cambiar.

Tablas:
  - fatigue_events   -> UNA fila por episodio de fatiga (o advertencia de sensor).
  - reading_stats    -> contador de lecturas normales por sesión.
  - sensor_readings  -> UNA fila por CADA lectura recibida (frame o pulso), con
                        las métricas crudas y el estado de la fusión en ese
                        instante. Es la tabla "de hechos" sobre la que se aplica
                        la minería de datos (ver app/analytics.py).
  - self_reports     -> autoreporte de somnolencia con la escala KSS
                        (Karolinska Sleepiness Scale, 1-9). Es la etiqueta
                        "real" (ground truth) para evaluar los modelos.
  - users            -> cuentas de acceso al panel con su rol (ver app/auth.py).

Es un proyecto de curso con tráfico bajo, así que se abre/cierra una
conexión por operación (patrón contextmanager) en vez de un pool.
"""

import os
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timedelta
from pathlib import Path

DATABASE_URL = os.environ.get("DATABASE_URL")
USE_POSTGRES = bool(DATABASE_URL)

# Ruta de la BD local (solo se usa en el fallback a SQLite).
DB_PATH = Path(__file__).parent / "sidfam.db"

if USE_POSTGRES:
    import psycopg2
    import psycopg2.extras

    # Railway/Heroku a veces entregan la URL con el esquema "postgres://";
    # normalizamos a "postgresql://" que es el que espera libpq/psycopg2.
    _PG_DSN = DATABASE_URL
    if _PG_DSN.startswith("postgres://"):
        _PG_DSN = "postgresql://" + _PG_DSN[len("postgres://"):]


_SCHEMA_SQLITE = """
CREATE TABLE IF NOT EXISTS fatigue_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    timestamp TEXT NOT NULL,
    risk_level TEXT NOT NULL,
    visual_signal INTEGER NOT NULL,
    physiological_signal INTEGER NOT NULL,
    detail TEXT,
    bpm REAL,
    ear REAL,
    sensor_warning INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS reading_stats (
    session_id TEXT PRIMARY KEY,
    normal_readings INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS sensor_readings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    timestamp TEXT NOT NULL,
    source TEXT NOT NULL,
    face_detected INTEGER,
    ear REAL,
    mar REAL,
    head_tilt_deg REAL,
    eyes_closed INTEGER,
    yawning INTEGER,
    head_tilted INTEGER,
    bpm REAL,
    bpm_mean REAL,
    bpm_std REAL,
    baseline_bpm REAL,
    implausible_reading INTEGER,
    fusion_status TEXT,
    risk_level TEXT
);
CREATE INDEX IF NOT EXISTS idx_readings_session_ts ON sensor_readings (session_id, timestamp);

CREATE TABLE IF NOT EXISTS self_reports (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    timestamp TEXT NOT NULL,
    kss INTEGER NOT NULL CHECK (kss BETWEEN 1 AND 9),
    note TEXT
);
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT NOT NULL UNIQUE,
    full_name TEXT,
    password_hash TEXT NOT NULL,
    role TEXT NOT NULL,
    session_id TEXT,
    active INTEGER NOT NULL DEFAULT 1,
    must_change_password INTEGER NOT NULL DEFAULT 0,
    session_version INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    last_login TEXT
);
"""

_SCHEMA_POSTGRES = """
CREATE TABLE IF NOT EXISTS fatigue_events (
    id SERIAL PRIMARY KEY,
    session_id TEXT NOT NULL,
    timestamp TIMESTAMP NOT NULL,
    risk_level TEXT NOT NULL,
    visual_signal INTEGER NOT NULL,
    physiological_signal INTEGER NOT NULL,
    detail TEXT,
    bpm REAL,
    ear REAL,
    sensor_warning INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS reading_stats (
    session_id TEXT PRIMARY KEY,
    normal_readings INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS sensor_readings (
    id SERIAL PRIMARY KEY,
    session_id TEXT NOT NULL,
    timestamp TIMESTAMP NOT NULL,
    source TEXT NOT NULL,
    face_detected INTEGER,
    ear REAL,
    mar REAL,
    head_tilt_deg REAL,
    eyes_closed INTEGER,
    yawning INTEGER,
    head_tilted INTEGER,
    bpm REAL,
    bpm_mean REAL,
    bpm_std REAL,
    baseline_bpm REAL,
    implausible_reading INTEGER,
    fusion_status TEXT,
    risk_level TEXT
);
CREATE INDEX IF NOT EXISTS idx_readings_session_ts ON sensor_readings (session_id, timestamp);

CREATE TABLE IF NOT EXISTS self_reports (
    id SERIAL PRIMARY KEY,
    session_id TEXT NOT NULL,
    timestamp TIMESTAMP NOT NULL,
    kss INTEGER NOT NULL CHECK (kss BETWEEN 1 AND 9),
    note TEXT
);
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    full_name TEXT,
    password_hash TEXT NOT NULL,
    role TEXT NOT NULL,
    session_id TEXT,
    active INTEGER NOT NULL DEFAULT 1,
    must_change_password INTEGER NOT NULL DEFAULT 0,
    session_version INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMP NOT NULL,
    last_login TIMESTAMP
);
"""


@contextmanager
def get_connection():
    """Abre una conexión al motor activo y la cierra al salir del bloque."""
    if USE_POSTGRES:
        conn = psycopg2.connect(_PG_DSN, cursor_factory=psycopg2.extras.RealDictCursor)
    else:
        conn = sqlite3.connect(DB_PATH)
        conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.close()


def _ph(sql: str) -> str:
    """Traduce los placeholders '?' (estilo sqlite3) a '%s' (estilo psycopg2)."""
    return sql.replace("?", "%s") if USE_POSTGRES else sql


def init_db() -> None:
    """Crea las tablas si no existen (en cualquiera de los dos motores)."""
    with get_connection() as conn:
        cur = conn.cursor()
        if USE_POSTGRES:
            cur.execute(_SCHEMA_POSTGRES)
        else:
            cur.executescript(_SCHEMA_SQLITE)
        conn.commit()


def save_event(session_id: str, timestamp: float, risk_level: str,
                visual_signal: bool, physiological_signal: bool, detail: str,
                bpm: float | None = None, ear: float | None = None,
                sensor_warning: bool = False) -> None:
    ts = datetime.fromtimestamp(timestamp)
    # PostgreSQL: columna TIMESTAMP -> psycopg2 adapta el datetime.
    # SQLite: columna TEXT -> se guarda la cadena ISO como antes.
    ts_value = ts if USE_POSTGRES else ts.isoformat(timespec="seconds")

    sql = _ph(
        """
        INSERT INTO fatigue_events
            (session_id, timestamp, risk_level, visual_signal, physiological_signal,
             detail, bpm, ear, sensor_warning)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
    )
    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute(
            sql,
            (
                session_id,
                ts_value,
                risk_level,
                int(visual_signal),
                int(physiological_signal),
                detail,
                bpm,
                ear,
                int(sensor_warning),
            ),
        )
        conn.commit()


def list_events(session_id: str | None = None, limit: int = 200) -> list[dict]:
    sql = "SELECT * FROM fatigue_events"
    params: list = []
    if session_id:
        sql += " WHERE session_id = ?"
        params.append(session_id)
    sql += " ORDER BY id DESC LIMIT ?"
    params.append(limit)

    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute(_ph(sql), tuple(params))
        rows = cur.fetchall()

    events = [dict(row) for row in rows]
    # Homogeneiza el timestamp a cadena ISO (en PostgreSQL vuelve como datetime).
    for e in events:
        if isinstance(e.get("timestamp"), datetime):
            e["timestamp"] = e["timestamp"].isoformat(timespec="seconds")
        e["detail"] = _clean_detail(e.get("detail"))
    return events


def _clean_detail(detail: str | None) -> str | None:
    """Quita el prefijo 'SIMULADO: ' de los eventos de prueba al mostrarlos."""
    if detail and detail.upper().startswith("SIMULADO:"):
        return detail[len("SIMULADO:"):].lstrip()
    return detail


def increment_normal_reading(session_id: str) -> None:
    """Suma 1 al contador de lecturas normales (frame o pulso sin evento de
    fatiga) de la sesión. Persiste igual que los eventos de riesgo.

    El UPSERT cualifica la columna con la tabla (`reading_stats.normal_readings`)
    porque PostgreSQL la considera ambigua frente a `EXCLUDED` si va sin prefijo;
    la forma cualificada es válida también en SQLite (>= 3.24).
    """
    sql = _ph(
        """
        INSERT INTO reading_stats (session_id, normal_readings)
        VALUES (?, 1)
        ON CONFLICT (session_id) DO UPDATE SET normal_readings = reading_stats.normal_readings + 1
        """
    )
    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute(sql, (session_id,))
        conn.commit()


def add_normal_readings(session_id: str, n: int) -> None:
    """Suma n lecturas normales de una vez (la usa el generador de datos sintéticos)."""
    if n <= 0:
        return
    sql = _ph(
        """
        INSERT INTO reading_stats (session_id, normal_readings)
        VALUES (?, ?)
        ON CONFLICT (session_id) DO UPDATE SET normal_readings = reading_stats.normal_readings + EXCLUDED.normal_readings
        """
    )
    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute(sql, (session_id, int(n)))
        conn.commit()


def normal_reading_count(session_id: str | None = None) -> int:
    sql = "SELECT COALESCE(SUM(normal_readings), 0) AS total FROM reading_stats"
    params: list = []
    if session_id:
        sql += " WHERE session_id = ?"
        params.append(session_id)

    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute(_ph(sql), tuple(params))
        row = cur.fetchone()
    return int(row["total"])


def event_counts_by_risk(session_id: str | None = None) -> dict[str, int]:
    sql = "SELECT risk_level, COUNT(*) AS total FROM fatigue_events"
    params: list = []
    if session_id:
        sql += " WHERE session_id = ?"
        params.append(session_id)
    sql += " GROUP BY risk_level"

    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute(_ph(sql), tuple(params))
        rows = cur.fetchall()
    return {row["risk_level"]: int(row["total"]) for row in rows}


# ---------------------------------------------------------------------------
# Lecturas crudas (tabla de hechos para la analítica)
# ---------------------------------------------------------------------------

_READING_COLUMNS = (
    "session_id", "timestamp", "source", "face_detected", "ear", "mar",
    "head_tilt_deg", "eyes_closed", "yawning", "head_tilted", "bpm",
    "bpm_mean", "bpm_std", "baseline_bpm", "implausible_reading",
    "fusion_status", "risk_level",
)


def _ts_value(timestamp: float):
    ts = datetime.fromtimestamp(timestamp)
    return ts if USE_POSTGRES else ts.isoformat(timespec="milliseconds")


def _bool_or_none(v):
    return None if v is None else int(bool(v))


def save_reading(session_id: str, timestamp: float, source: str, *,
                 face_detected=None, ear=None, mar=None, head_tilt_deg=None,
                 eyes_closed=None, yawning=None, head_tilted=None,
                 bpm=None, bpm_mean=None, bpm_std=None, baseline_bpm=None,
                 implausible_reading=None, fusion_status=None,
                 risk_level=None) -> None:
    """Guarda una lectura individual (source = "frame" o "pulso")."""
    values = (
        session_id, _ts_value(timestamp), source, _bool_or_none(face_detected),
        ear, mar, head_tilt_deg, _bool_or_none(eyes_closed), _bool_or_none(yawning),
        _bool_or_none(head_tilted), bpm, bpm_mean, bpm_std, baseline_bpm,
        _bool_or_none(implausible_reading), fusion_status, risk_level,
    )
    placeholders = ", ".join("?" for _ in _READING_COLUMNS)
    sql = _ph(f"INSERT INTO sensor_readings ({', '.join(_READING_COLUMNS)}) VALUES ({placeholders})")
    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute(sql, values)
        conn.commit()


def save_readings_bulk(rows: list[dict]) -> None:
    """Inserción masiva (la usa el generador de datos sintéticos)."""
    if not rows:
        return
    placeholders = ", ".join("?" for _ in _READING_COLUMNS)
    sql = _ph(f"INSERT INTO sensor_readings ({', '.join(_READING_COLUMNS)}) VALUES ({placeholders})")
    data = []
    for r in rows:
        data.append(tuple(
            _ts_value(r["timestamp"]) if c == "timestamp"
            else _bool_or_none(r.get(c)) if c in ("face_detected", "eyes_closed", "yawning",
                                                  "head_tilted", "implausible_reading")
            else r.get(c)
            for c in _READING_COLUMNS
        ))
    with get_connection() as conn:
        cur = conn.cursor()
        cur.executemany(sql, data)
        conn.commit()


def _iso_rows(rows) -> list[dict]:
    out = [dict(r) for r in rows]
    for r in out:
        if isinstance(r.get("timestamp"), datetime):
            r["timestamp"] = r["timestamp"].isoformat(timespec="milliseconds")
    return out


def list_readings(session_id: str | None = None, limit: int | None = None,
                  newest_first: bool = False) -> list[dict]:
    sql = "SELECT * FROM sensor_readings"
    params: list = []
    if session_id:
        sql += " WHERE session_id = ?"
        params.append(session_id)
    sql += " ORDER BY timestamp DESC, id DESC" if newest_first else " ORDER BY timestamp ASC, id ASC"
    if limit:
        sql += " LIMIT ?"
        params.append(limit)
    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute(_ph(sql), tuple(params))
        return _iso_rows(cur.fetchall())


def last_readings(session_id: str) -> dict:
    """Última lectura guardada de cada fuente ("frame" y "pulso") de la sesión.

    El estado en vivo vive en memoria y se pierde al reiniciar el servidor;
    esto permite al panel mostrar lo último conocido mientras no llegan datos.
    """
    sql = _ph("SELECT * FROM sensor_readings WHERE session_id = ? AND source = ? "
              "ORDER BY timestamp DESC, id DESC LIMIT 1")
    out = {}
    with get_connection() as conn:
        cur = conn.cursor()
        for source in ("frame", "pulso"):
            cur.execute(sql, (session_id, source))
            rows = _iso_rows(cur.fetchall())
            out[source] = rows[0] if rows else None
            if rows:
                # la hora se guarda sin zona (hora local del servidor): la antigüedad se
                # calcula aquí para que el cliente no dependa de su propia zona horaria
                ts = datetime.fromisoformat(rows[0]["timestamp"])
                rows[0]["age_seconds"] = max(0, round((datetime.now() - ts).total_seconds()))
    return out


def fleet_event_summary() -> dict[str, dict]:
    """Por sesión: eventos de hoy por nivel y el último evento (vista de flota).

    La antigüedad se calcula aquí porque las horas se guardan sin zona horaria.
    """
    today = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
    since = today if USE_POSTGRES else today.isoformat(timespec="seconds")
    out: dict[str, dict] = {}
    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute(_ph("SELECT session_id, risk_level, COUNT(*) AS n FROM fatigue_events "
                        "WHERE timestamp >= ? GROUP BY session_id, risk_level"), (since,))
        for r in cur.fetchall():
            out.setdefault(r["session_id"], {"hoy": {}, "ultimo": None})["hoy"][r["risk_level"]] = int(r["n"])
        cur.execute("SELECT * FROM fatigue_events e WHERE id = "
                    "(SELECT MAX(id) FROM fatigue_events WHERE session_id = e.session_id)")
        for r in _iso_rows(cur.fetchall()):
            ts = datetime.fromisoformat(r["timestamp"]) if isinstance(r["timestamp"], str) else r["timestamp"]
            out.setdefault(r["session_id"], {"hoy": {}, "ultimo": None})["ultimo"] = {
                "id": r["id"], "risk_level": r["risk_level"], "detail": _clean_detail(r["detail"]),
                "age_seconds": max(0, round((datetime.now() - ts).total_seconds())),
            }
    return out


def list_sessions() -> list[dict]:
    """Sesiones que tienen lecturas, con su cantidad y rango de fechas."""
    sql = """
        SELECT session_id, COUNT(*) AS lecturas,
               MIN(timestamp) AS desde, MAX(timestamp) AS hasta
        FROM sensor_readings GROUP BY session_id ORDER BY MAX(timestamp) DESC
    """
    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute(sql)
        rows = [dict(r) for r in cur.fetchall()]
    for r in rows:
        for k in ("desde", "hasta"):
            if isinstance(r.get(k), datetime):
                r[k] = r[k].isoformat(timespec="seconds")
        r["lecturas"] = int(r["lecturas"])
    return rows


def minute_summary(session_id: str | None, limit: int = 20, hours: int = 24) -> dict:
    """Minutos recientes sin episodio guardado, uno por fila, con el EAR y el BPM
    medios. Resume las lecturas para el historial sin mandar cada frame (serían
    miles por hora). Un minuto con alguna lectura en vigilancia NO es normal:
    va aparte, para que un cabeceo sin confirmar por el pulso no salga en verde.
    Devuelve {"normales": [...], "vigilancias": [...]}, cada lista con máximo
    `limit` filas. Los minutos con alerta o advertencia de sensor se omiten.
    Con session_id=None se resumen todas las sesiones: un minuto por sesión,
    con su session_id, para no mezclar lecturas de conductores distintos."""
    minute = ("to_char(timestamp, 'YYYY-MM-DD\"T\"HH24:MI')" if USE_POSTGRES
              else "substr(timestamp, 1, 16)")
    since = datetime.now() - timedelta(hours=hours)
    since = since if USE_POSTGRES else since.isoformat(timespec="seconds")
    where = "session_id = ? AND timestamp >= ?" if session_id else "timestamp >= ?"
    params = (session_id, since) if session_id else (since,)
    sql = f"""
        SELECT session_id, {minute} AS minuto, COUNT(*) AS lecturas,
               AVG(CASE WHEN source = 'frame' AND face_detected = 1 THEN ear END) AS ear,
               AVG(CASE WHEN source = 'pulso' THEN bpm END) AS bpm,
               SUM(CASE WHEN fusion_status = 'vigilancia' THEN 1 ELSE 0 END) AS en_vigilancia
        FROM sensor_readings
        WHERE {where}
        GROUP BY session_id, {minute}
        HAVING SUM(CASE WHEN fusion_status IN ('alerta', 'advertencia_sensor') THEN 1 ELSE 0 END) = 0
        ORDER BY minuto DESC
    """
    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute(_ph(sql), params)
        rows = [dict(r) for r in cur.fetchall()]

    def fila(r: dict) -> dict:
        return {
            "session_id": r["session_id"],
            "timestamp": r["minuto"],
            "lecturas": int(r["lecturas"]),
            "ear": round(float(r["ear"]), 3) if r["ear"] is not None else None,
            "bpm": round(float(r["bpm"]), 1) if r["bpm"] is not None else None,
        }

    return {
        "normales": [fila(r) for r in rows if not r["en_vigilancia"]][:limit],
        "vigilancias": [fila(r) for r in rows if r["en_vigilancia"]][:limit],
    }


# ---------------------------------------------------------------------------
# Autoreporte KSS (etiqueta real para evaluar modelos supervisados)
# ---------------------------------------------------------------------------

def save_self_report(session_id: str, timestamp: float, kss: int, note: str | None = None) -> None:
    sql = _ph("INSERT INTO self_reports (session_id, timestamp, kss, note) VALUES (?, ?, ?, ?)")
    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute(sql, (session_id, _ts_value(timestamp), int(kss), note))
        conn.commit()


def list_self_reports(session_id: str | None = None) -> list[dict]:
    sql = "SELECT * FROM self_reports"
    params: list = []
    if session_id:
        sql += " WHERE session_id = ?"
        params.append(session_id)
    sql += " ORDER BY timestamp ASC"
    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute(_ph(sql), tuple(params))
        return _iso_rows(cur.fetchall())


# ---------------------------------------------------------------------------
# Usuarios del panel (control de acceso, ver app/auth.py)
# ---------------------------------------------------------------------------

# Columnas que update_user() acepta; el resto (id, created_at...) no se toca.
_USER_UPDATABLE = ("full_name", "password_hash", "role", "session_id", "active",
                   "must_change_password", "session_version")


def _user_row(row) -> dict | None:
    if row is None:
        return None
    u = dict(row)
    for k in ("created_at", "last_login"):
        if isinstance(u.get(k), datetime):
            u[k] = u[k].isoformat(timespec="seconds")
    for k in ("active", "must_change_password"):
        u[k] = bool(u[k])
    return u


def count_users(role: str | None = None, only_active: bool = False) -> int:
    sql = "SELECT COUNT(*) AS total FROM users WHERE 1 = 1"
    params: list = []
    if role:
        sql += " AND role = ?"
        params.append(role)
    if only_active:
        sql += " AND active = 1"
    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute(_ph(sql), tuple(params))
        return int(cur.fetchone()["total"])


def create_user(username: str, password_hash: str, role: str, full_name: str | None = None,
                session_id: str | None = None, must_change_password: bool = False) -> int:
    now = datetime.now()
    values = (username, full_name, password_hash, role, session_id, int(must_change_password),
              now if USE_POSTGRES else now.isoformat(timespec="seconds"))
    sql = """
        INSERT INTO users (username, full_name, password_hash, role, session_id,
                           must_change_password, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    """
    with get_connection() as conn:
        cur = conn.cursor()
        if USE_POSTGRES:
            cur.execute(_ph(sql + " RETURNING id"), values)
            new_id = cur.fetchone()["id"]
        else:
            cur.execute(sql, values)
            new_id = cur.lastrowid
        conn.commit()
    return int(new_id)


def get_user(user_id: int) -> dict | None:
    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute(_ph("SELECT * FROM users WHERE id = ?"), (user_id,))
        return _user_row(cur.fetchone())


def get_user_by_username(username: str) -> dict | None:
    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute(_ph("SELECT * FROM users WHERE username = ?"), (username,))
        return _user_row(cur.fetchone())


def list_users() -> list[dict]:
    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute("SELECT * FROM users ORDER BY role, username")
        return [_user_row(r) for r in cur.fetchall()]


def update_user(user_id: int, **fields) -> None:
    fields = {k: v for k, v in fields.items() if k in _USER_UPDATABLE}
    if not fields:
        return
    for k in ("active", "must_change_password"):
        if k in fields:
            fields[k] = int(bool(fields[k]))
    assignments = ", ".join(f"{k} = ?" for k in fields)
    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute(_ph(f"UPDATE users SET {assignments} WHERE id = ?"), (*fields.values(), user_id))
        conn.commit()


def record_login(user_id: int) -> None:
    now = datetime.now()
    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute(_ph("UPDATE users SET last_login = ? WHERE id = ?"),
                    (now if USE_POSTGRES else now.isoformat(timespec="seconds"), user_id))
        conn.commit()
