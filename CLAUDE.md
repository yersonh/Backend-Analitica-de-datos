# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

SIDFAM is an academic prototype for driver/operator fatigue detection. A FastAPI
backend (`app/`) receives camera frames from an ESP32-CAM and heart-rate readings
from an ESP32, runs vision + pulse analysis, fuses the two signals into a risk
level, persists fatigue episodes to SQLite, and serves an HTML dashboard.
`firmware/` holds reference Arduino sketches for the two devices — they are not
built here, only kept in sync with the backend's HTTP contract.

Code, comments, docstrings and the README are written in Spanish; match that when
editing. `README.md` also carries the theoretical background (EAR/MAR definitions,
threshold rationale) and the project's pending next steps.

## Commands

```bash
python -m venv venv && venv\Scripts\activate      # Windows (source venv/bin/activate on Unix)
pip install -r requirements.txt

uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

- Dashboard: http://localhost:8000/ — Swagger: http://localhost:8000/docs
- Use `--host 0.0.0.0` and the machine's LAN IP so the ESP32s can reach it; set
  the same IP in `SERVER_HOST` in the firmware sketches.

There is no test suite, linter, or build step. Exercise endpoints manually:

```bash
curl -X POST http://localhost:8000/pulso -F "bpm=72" -F "session_id=default"
curl -X POST http://localhost:8000/frame -F "file=@foto.jpg" -F "session_id=default"
curl "http://localhost:8000/eventos?session_id=default"
```

`mediapipe` is pinned to `0.10.13` on purpose: 0.10.18+ removed the classic
`mp.solutions.face_mesh` API used in `app/vision.py`. Migrating to the new Tasks
API means rewriting only that file.

## Architecture

Request flow for both ingest endpoints (`app/main.py`):

1. `/frame` decodes the JPEG with OpenCV → `face_analyzer.analyze()` → `VisionResult`.
   `/pulso` appends the BPM → `pulse_analyzer.add_reading()` → `PulseResult`.
2. The result is pushed into `fusion_engine.update_vision()` / `update_pulse()`,
   which updates per-session state and re-evaluates fusion.
3. If evaluation yields a `FatigueEvent`, `database.save_event()` writes a row;
   otherwise `database.increment_normal_reading()` bumps that session's normal
   counter (`reading_stats` table).
4. The endpoint returns the raw metrics plus `fatigue_event` (the risk level, or null).

Each analysis module exposes a **single module-level singleton** instantiated at
import time (`face_analyzer`, `pulse_analyzer`, `fusion_engine`) — MediaPipe model
creation and the sliding buffers are expensive/stateful, so they are shared across
requests. This makes the app single-process and stateful in memory; the database
(Postgres in prod, SQLite locally — see `app/database.py`) is the only durable
store. Restarting uvicorn clears pulse buffers, the learned
per-session `baseline_bpm`, and fusion timers, but keeps everything persisted
(events + `reading_stats`).

**`app/vision.py`** — stateless per call. MediaPipe Face Mesh (468 pretrained
landmarks, no training). Computes EAR (eye closure), MAR (yawn), head-tilt angle,
and returns boolean flags against `EAR_THRESHOLD` / `MAR_THRESHOLD` /
`HEAD_TILT_THRESHOLD_DEG`. Landmark index arrays at the top of the file follow the
standard EAR/MAR point ordering — changing them breaks the ratio math.

**`app/pulse.py`** — stateful. Keeps a 60s sliding `deque` per `session_id`
(`WINDOW_SECONDS`), needs `MIN_SAMPLES_FOR_ANALYSIS` readings before it reports.
Drowsiness is judged **relative to the person's own baseline**, not absolute BPM:
the first `BASELINE_SAMPLE_COUNT` plausible readings fix `baseline_bpm` (never
recalculated); `relative_drop_signal` fires when the window mean falls
`RELATIVE_DROP_THRESHOLD` (8%) below it. `low_variability` (std below
`LOW_VARIABILITY_STD`) is an additional drowsiness cue.
`physiological_drowsy_signal = relative_drop_signal or low_variability`. A reading
outside `[PLAUSIBLE_BPM_MIN, PLAUSIBLE_BPM_MAX]` sets `implausible_reading` — a
**data-quality flag, kept separate from fatigue evidence**. Assumes the ESP32
already sends computed BPM; raw IR/RED peak detection would go here.

**`app/fusion.py`** — stateful, the decision core (RF05–RF07). Holds a
`_SessionState` per `session_id` tracking *since when* eyes/head have been in a
bad state, so a signal only counts once sustained for `EYES_CLOSED_SUSTAIN_SECONDS`
/ `HEAD_TILT_SUSTAIN_SECONDS` (yawn counts immediately). Only signals fresher than
`SIGNAL_FRESHNESS_SECONDS` (10s) count. **RF05: a fatigue event requires BOTH a
visual signal AND `physiological_drowsy_signal` at the same time.** `risk_level`
is by count of concrete `reasons`: 2 → `"medio"`, 3+ → `"alto"` (no `"bajo"`). A
fresh `implausible_reading` produces a `sensor_warning` event with
`risk_level="advertencia_sensor"` instead — a sensor problem, not driver fatigue.
`get_current_status()` mirrors this for the dashboard: `normal` / `vigilancia`
(one channel only, unconfirmed) / `alerta` / `advertencia_sensor` — reported for as
long as the condition holds. `_evaluate()` instead persists **one row per
episode** (`_SessionState.in_fatigue_episode` / `in_sensor_warning_episode`): the
event fires when the episode opens, again only if risk escalates `medio`→`alto`
(`detail` prefixed `"Escalada: "`), and the flag clears when the status leaves
`alerta` / `advertencia_sensor` so the next occurrence counts as new.

**`app/database.py`** — dual backend, chosen at import time: **PostgreSQL** (via
`psycopg2`) when `DATABASE_URL` is set (Railway injects it), else **SQLite** at
`app/sidfam.db` for local dev. Same public signatures for both; `main.py` is
backend-agnostic. `_ph()` swaps `?`→`%s` for the Postgres branch; Postgres uses
`SERIAL` + `TIMESTAMP`, SQLite keeps `AUTOINCREMENT` + ISO-string timestamps
(`list_events()` normalizes the value back to an ISO string either way). Tables:
`fatigue_events` (one row per event, `sensor_warning` flags the sensor kind) +
`reading_stats` (per-session normal-reading counter). `init_db()` only
`CREATE TABLE IF NOT EXISTS` — no migrations. On Railway the SQLite file is
ephemeral (and `.dockerignore`d); Postgres is what survives deploys.

**Sessions**: `session_id` (default `"default"`) is the multi-user seam — it keys
the pulse buffers, fusion state, and every DB query. The prototype runs one
session; keep new code session-scoped.

All tuning thresholds are module-level constants at the top of `vision.py`,
`pulse.py`, and `fusion.py` — they are placeholders to be calibrated with real
hardware and are the main thing that will change during testing.

## Firmware ↔ backend contract

`firmware/esp32cam_frame_sender` POSTs `multipart/form-data` to `/frame` every
~1.5s with fields `session_id` and `file` (JPEG). `firmware/esp32_pulse_sender`
POSTs `application/x-www-form-urlencoded` `bpm` + `session_id` to `/pulso` every
~2s. If you change endpoint paths, field names, or form vs. JSON
encoding in `app/main.py`, update the matching `.ino` sketch.
