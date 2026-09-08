"""
Persistencia de eventos de fatiga en SQLite (RF07: fecha, hora, nivel
de riesgo). SQLite es suficiente para el prototipo académico; si el
proyecto avanza a producción real, este módulo es el punto de
reemplazo por Postgres u otro motor (ver notas de marco legal sobre
RNBD si se persiste con usuarios reales).
"""

import sqlite3
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path

DB_PATH = Path(__file__).parent / "sidfam.db"

_SCHEMA = """
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


@contextmanager
def get_connection():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.close()


def init_db() -> None:
    with get_connection() as conn:
        conn.executescript(_SCHEMA)
        # Migración no destructiva: agrega columnas que falten en bases de
        # datos anteriores sin borrar los eventos ya guardados.
        existing_cols = {row["name"] for row in conn.execute("PRAGMA table_info(fatigue_events)")}
        for col, ddl in (
            ("bpm", "REAL"),
            ("ear", "REAL"),
            ("sensor_warning", "INTEGER NOT NULL DEFAULT 0"),
        ):
            if col not in existing_cols:
                conn.execute(f"ALTER TABLE fatigue_events ADD COLUMN {col} {ddl}")
        conn.commit()


def save_event(session_id: str, timestamp: float, risk_level: str,
                visual_signal: bool, physiological_signal: bool, detail: str,
                bpm: float | None = None, ear: float | None = None,
                sensor_warning: bool = False) -> None:
    with get_connection() as conn:
        conn.execute(
            """
            INSERT INTO fatigue_events
                (session_id, timestamp, risk_level, visual_signal, physiological_signal,
                 detail, bpm, ear, sensor_warning)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                session_id,
                datetime.fromtimestamp(timestamp).isoformat(timespec="seconds"),
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
    query = "SELECT * FROM fatigue_events"
    params: tuple = ()
    if session_id:
        query += " WHERE session_id = ?"
        params = (session_id,)
    query += " ORDER BY id DESC LIMIT ?"
    params = params + (limit,)

    with get_connection() as conn:
        rows = conn.execute(query, params).fetchall()
        return [dict(row) for row in rows]


def increment_normal_reading(session_id: str) -> None:
    """Suma 1 al contador de lecturas normales (frame o pulso sin evento de
    fatiga) de la sesión. Persiste igual que los eventos de riesgo."""
    with get_connection() as conn:
        conn.execute(
            """
            INSERT INTO reading_stats (session_id, normal_readings)
            VALUES (?, 1)
            ON CONFLICT(session_id) DO UPDATE SET normal_readings = normal_readings + 1
            """,
            (session_id,),
        )
        conn.commit()


def normal_reading_count(session_id: str | None = None) -> int:
    query = "SELECT COALESCE(SUM(normal_readings), 0) AS total FROM reading_stats"
    params: tuple = ()
    if session_id:
        query += " WHERE session_id = ?"
        params = (session_id,)

    with get_connection() as conn:
        return conn.execute(query, params).fetchone()["total"]


def event_counts_by_risk(session_id: str | None = None) -> dict[str, int]:
    query = "SELECT risk_level, COUNT(*) as total FROM fatigue_events"
    params: tuple = ()
    if session_id:
        query += " WHERE session_id = ?"
        params = (session_id,)
    query += " GROUP BY risk_level"

    with get_connection() as conn:
        rows = conn.execute(query, params).fetchall()
        return {row["risk_level"]: row["total"] for row in rows}
