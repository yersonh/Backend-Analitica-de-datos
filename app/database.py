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
event_counts_by_risk, increment_normal_reading, normal_reading_count) son
idénticas en ambos casos: app/main.py no necesita cambiar.

Es un proyecto de curso con tráfico bajo, así que se abre/cierra una
conexión por operación (patrón contextmanager) en vez de un pool.
"""

import os
import sqlite3
from contextlib import contextmanager
from datetime import datetime
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
    return events


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
