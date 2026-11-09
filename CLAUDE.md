# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

SIDFAM is an academic prototype for driver/operator fatigue detection. A FastAPI
backend (`app/`) receives camera frames from an ESP32-CAM and heart-rate readings
from an ESP32, runs vision + pulse analysis, fuses the two signals into a risk
level, persists fatigue episodes to SQLite, and serves an HTML dashboard.
`firmware/` holds reference Arduino sketches for the two devices — they are not
built here, only kept in sync with the backend's HTTP contract. `mobile/` is a
Flutter app (Android/iOS) that mirrors the HTML dashboard as an API client; all
detection stays server-side.

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
  the same IP in `SERVER_URL` (camera sketch) / `SERVER_HOST` (pulse sketch).

Tests: `pip install -r requirements-dev.txt && python -m pytest -q` (`tests/`:
pulse rules, fusion rules incl. microsleep/calibration, ingest + recalibrate
endpoints; a fake `clock` fixture patches `time.time`, the API tests use a temp
SQLite). Python 3.11/3.12 (mediapipe 0.10.13 has no 3.13 wheels). Run them after
touching `pulse.py`, `fusion.py`, `vision.py` or the ingest endpoints; there is
no linter or build step. Exercise endpoints manually
(read endpoints need a login cookie; ingest needs `X-Device-Key` when
`DEVICE_API_KEY` is set):

```bash
curl -X POST http://localhost:8000/pulso -F "bpm=72" -F "session_id=default"
curl -X POST http://localhost:8000/frame -F "file=@foto.jpg" -F "session_id=default"
curl -c c.txt -X POST http://localhost:8000/login -d "username=admin&password=..."
curl -b c.txt "http://localhost:8000/eventos?session_id=default"
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
   otherwise, only while the fusion status is `normal`,
   `database.increment_normal_reading()` bumps that session's normal counter
   (`reading_stats` table). `vigilancia` and open alerts do not count as normal.
4. The endpoint returns the raw metrics plus `fatigue_event` (the risk level, or null).

Each analysis module exposes a **single module-level singleton** instantiated at
import time (`face_analyzer`, `pulse_analyzer`, `fusion_engine`) — MediaPipe model
creation and the sliding buffers are expensive/stateful, so they are shared across
requests. This makes the app single-process (one uvicorn worker) and stateful in memory; the database
(Postgres in prod, SQLite locally — see `app/database.py`) is the only durable
store. Restarting uvicorn clears pulse buffers, the learned
per-session `baseline_bpm`, and fusion timers, but keeps everything persisted
(events + `reading_stats`).

The ingest endpoints (`/frame`, `/pulso`, `/api/camara/dispositivo`) are plain
`def`, not `async def`, so FastAPI runs them in its threadpool and the blocking
MediaPipe/OpenCV/DB work never stalls the event loop (MJPEG stream, login,
`/estado`). Therefore the singletons are **thread-safe by locks**:
`FaceAnalyzer._lock` around `FaceMesh.process` (not thread-safe),
`PulseAnalyzer._lock`, `FusionEngine._lock` (RLock; public methods take it,
`_`-prefixed internals assume it is held). Keep new ingest endpoints sync and new
state behind those locks. Frames over `MAX_FRAME_BYTES` (2 MB) get 413.

**`app/vision.py`** — stateless per call. MediaPipe Face Mesh (468 pretrained
landmarks, no training). Computes EAR (eye closure), MAR (yawn), head-tilt (roll)
angle and `pitch_ratio` (nose between eye line and chin; only meaningful against
its per-session baseline), and returns boolean flags against the **fixed**
`EAR_THRESHOLD` / `MAR_THRESHOLD` / `HEAD_TILT_THRESHOLD_DEG`. `fusion.py`
overrides `eyes_closed` / `head_tilted` in place once the session is calibrated. Landmark index arrays at the top of the file follow the
standard EAR/MAR point ordering — changing them breaks the ratio math.

**`app/pulse.py`** — stateful. Keeps a 60s sliding `deque` per `session_id`
(`WINDOW_SECONDS`), needs `MIN_SAMPLES_FOR_ANALYSIS` readings before it reports.
Drowsiness is judged **relative to the person's own baseline**, not absolute BPM:
after skipping `BASELINE_WARMUP_COUNT` readings, the median of the next
`BASELINE_SAMPLE_COUNT` plausible readings fixes `baseline_bpm` (not chased
during a trip; discarded after `IDLE_RESET_SECONDS` without readings or by
`reset()`); `relative_drop_signal` fires when the window
**median** falls `RELATIVE_DROP_THRESHOLD` (8%) below it. `bpm_median` is exposed
in `/estado` so the drop meters show that same measure. `low_variability` (std below
`LOW_VARIABILITY_STD`) never triggers on its own, because the ESP32 sends
already-averaged BPM: it only adds a reason in `fusion.py` once there is a drop.
The project's goal is collecting data, so that reason stays even if it makes
`alto` common: it keeps high-risk cases reachable in tests.
`physiological_drowsy_signal = relative_drop_signal`. A reading outside
`[PLAUSIBLE_BPM_MIN, PLAUSIBLE_BPM_MAX]` sets `implausible_reading` — a
**data-quality flag, kept separate from fatigue evidence** — and stays out of the
window. Assumes the ESP32
already sends computed BPM; raw IR/RED peak detection would go here.

**`app/fusion.py`** — stateful, the decision core (RF05–RF07). Holds a
`_SessionState` per `session_id` tracking *since when* eyes/head have been in a
bad state, so a signal only counts once sustained for `EYES_CLOSED_SUSTAIN_SECONDS`
/ `HEAD_TILT_SUSTAIN_SECONDS` / `YAWN_SUSTAIN_SECONDS`.
**Personal vision calibration**: the first `CALIBRATION_FRAMES` face frames fix
`ear_baseline` / `pitch_baseline` (medians); afterwards eyes closed =
EAR < `ear_threshold(baseline)` (`EAR_CLOSED_FRACTION`, clamped to
`[EAR_THRESHOLD_MIN, EAR_THRESHOLD_MAX]`) and head tilted also when pitch deviates
more than `PITCH_DEVIATION` from its baseline. Calibration resets after
`IDLE_RESET_SECONDS` without frames or via `reset()`. `POST
/api/sesiones/recalibrar` (permission `panel`, through `resolve_session`, not
`todas`) calls both `pulse_analyzer.reset` and `fusion_engine.reset`; the web
and app have a *Recalibrar* button on the meters card. **Microsleep**: eyes closed
≥ `MICROSLEEP_SECONDS` sets `microsueno` in the status, which turns the buzzer on
(`buzzer_auto`) **without** changing the status (stays `vigilancia`) or saving an
event — RF05 still governs persisted episodes. Only signals fresher than
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

**`app/identity.py`** — driver face verification so a session's data is only
its driver's. OpenCV YuNet (detect) + SFace (128-d embedding, cosine
`MATCH_THRESHOLD` 0.363); ONNX models in `app/models/` (gitignored, fetched by
`scripts/descargar_modelos.py`, run in the Dockerfile; missing models →
`face_identifier.available` False → verification `deshabilitada`, everything
accepted as before). Table `face_enrollments` (user_id, embeddings JSON, samples,
consent_at): **only vectors, never photos** (Ley 1581 biometric data; enrollment
requires `consentimiento=true`). `identity_guard` (singleton, RLock, in memory)
keeps per-session status `pendiente` / `verificado` / `no_coincide` (+ derived
`vencida`, `sin_registro`, `deshabilitada`), enrollments looked up by session via
`users.session_id` (active users), cached `ENROLLMENT_CACHE_SECONDS`; call
`identity_guard.invalidate(session_id)` whenever enrollment, a user's session or
active flag changes. `_process_frame` calls `check_frame` (throttled:
`CHECK_INTERVAL_VERIFIED`/`_UNVERIFIED`; `MISMATCHES_TO_REJECT` consecutive
misses → `no_coincide`; any face in frame matching is enough) **before**
MediaPipe; `/pulso` checks `allows_data`. Rejected data returns
`ignorado: true, motivo: "identidad"` with the usual estado/buzzer fields, is
neither fused nor stored, and the live frame gets an "IDENTIDAD NO VERIFICADA"
banner. Sessions without an enrolled driver behave as before. Endpoints:
`GET /api/identidad` (what the app must ask: `necesita` = `registro` /
`verificacion`), `POST/DELETE /api/identidad/registro`,
`POST /api/identidad/verificar`, admin `DELETE /api/usuarios/{id}/rostro`;
`/api/usuarios` rows carry `rostro_registrado`, `/estado` carries `identidad`.
App: `screens/identity_screen.dart` is shown by `_Gate` in `main.dart` while
`AppState.identityNeed` is set (not blocking: "Ahora no" → `identityPostponed`
until next login); "Mi rostro" in the account menu redoes/deletes it; live screen
`_IdentityCard`. Web: `identity-card` in the dashboard, face tag/action in
`usuarios.html`. Tests use a fake identifier (`tests/test_identity.py`).

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

**`app/analytics.py`** — offline data mining over `sensor_readings`, structured as
CRISP-DM. `full_report()` cleans readings, aggregates them into time windows
(`build_windows`, 8 `FEATURES`), then runs K-Means, a decision tree, `regression()`
and Isolation Forest. `regression()` picks **linear** (target = KSS 1-9) when enough varied KSS
self-reports exist and R² ≥ `MIN_R2_LINEAL`, else **logistic** (binary fatigue, via
`_binary_target`: KSS ≥ 7 or the fusion-rule label); both share `_split`/`_cv`
with the tree (split by person when ≥ 3 people). `users_overview()` feeds the
per-user comparison (`/analitica/usuarios`). Everything returns `_clean()`ed JSON
consumed by both the web dashboard JS and `mobile/lib/screens/analytics_screen.dart`.

**`app/auth.py`** — access control, stdlib only (PBKDF2 hashes, HMAC-signed
cookie `sidfam_sesion` carrying user id + `session_version` + expiry; bumping
`users.session_version` revokes every open login). Roles are sets of
permission strings in `ROLES` (`administrador` ⊃ `supervisor` ⊃ `conductor`;
`analitica_propia` = analytics of one's own session only, `auth.require_any(...)` for
endpoints that accept either of several permissions);
**endpoints depend on permissions, never on role names**: use
`Depends(require("<permiso>"))`. A `conductor` is bound to `users.session_id`;
always pass a requested `session_id` through `auth.resolve_session(user, ...)`
(403 on someone else's session). Auth failures raise `LoginRequired` /
`PasswordChangeRequired` / `Forbidden`, which `main.py` turns into a redirect
for HTML GETs and JSON 401/403 otherwise. `/frame` and `/pulso` use
`require_device` (header `X-Device-Key` = env `DEVICE_API_KEY`; open when unset).
First boot with an empty `users` table creates `admin` with a temporary
password printed to the uvicorn log. Env: `SECRET_KEY`, `DEVICE_API_KEY`,
`ADMIN_USERNAME`/`ADMIN_PASSWORD`. Login lockout state is in memory.

**Mobile look & feel**: `mobile/lib/widgets/brand.dart` holds the brand widgets
(`SidfamLogo` — animated eye whose lower lid is an ECG trace, `AuroraBackground`,
`ShimmerText`, `GradientButton`, `FadeSlideIn`). The aurora is painted once in
`MaterialApp.builder`, so Scaffolds stay transparent. The logo's source drawing is
`mobile/branding/logo.svg`; if it changes, update `SidfamLogo` to match and
regenerate the Android/iOS launcher PNGs.

**Sessions**: `session_id` (default `"default"`) is the multi-user seam — it keys
the pulse buffers, fusion state, and every DB query. The prototype runs one
session; keep new code session-scoped.

All tuning thresholds are module-level constants at the top of `vision.py`,
`pulse.py`, and `fusion.py` — they are placeholders to be calibrated with real
hardware and are the main thing that will change during testing.

## Mobile app (`mobile/`)

Flutter client of the same backend (`cd mobile && flutter analyze && flutter test`;
`flutter run` / `flutter build apk`). Auth: `POST /api/login` returns the same
HMAC token as the cookie; the app sends it as `Authorization: Bearer` and
`auth.get_current_user` accepts either (Bearer skips the CSRF origin check).
The APK is distributed from GitHub Releases (asset `app-release.apk`, never
committed): the public page `/app` (`descargar_app.html`, linked from the login)
shows a QR + download button for `APK_URL` (env, defaults to this repo's
`releases/latest/download/app-release.apk`; the release repo must be public).
`/api/cuenta/clave` returns a fresh token because changing the password bumps
`session_version`. `/api/config` supplies the thresholds the HTML gets inlined.
Everything else reuses the existing JSON endpoints, so **changing a JSON
response shape (`/estado`, `/eventos`, `/analitica/reporte`, `/api/usuarios`,
`/api/flota`) means updating the matching screen in `mobile/lib/screens/`**.
`/api/flota` (permission `todas_sesiones`): every conductor/session with live
status, last reading age and today's events, sorted by urgency; it backs the
supervisor's "Flota" tab (`fleet_screen.dart`, polled every 3 s by
`fleet_controller.dart`, which also alerts on new events from any session) and the
same section in the web dashboard (`pollFleet`, with a "Despertar" buzzer button per
driver). Supervisor features must exist on both web and app; the conductor's
main client is the app. Polling cadence
matches the web (1.5s status, 4s events) in `mobile/lib/live_controller.dart`.
`/eventos` also returns `normales` and `vigilancias` (`database.minute_summary`:
up to 20 recent minutes each, one row per minute with mean EAR/BPM; a minute with
any `vigilancia` reading is never `normal`, and minutes with an alert/sensor
warning are left out; cached `MINUTES_CACHE_SECONDS` per session in `main.py`);
the Historial on web and app merges them with the episodes. The app mirrors the web's
light pastel palette (`theme.dart`), shows the six CRISP-DM phases in order (phase 1 criteria, phase 5
`evaluacion` verdict from `analytics.evaluate_criteria`, phase 6 deployment) with a
phase conclusion box plus a "Qué muestra" note under each chart/table, all text from
`analytics.interpret()` (report key `interpretacion`: `faseN` lists, phase 6 = recommendations,
and `graficos[clave]` per chart, placed with `nota("clave")` on web and `ChartNote('clave')` in the
app, `widgets/model_sections.dart`), so web and app never write their own, hides the model
sections that are not `disponible` (a "Modelos pendientes" card says what is
missing, on web too), and shows the ESP32 video only with `todas_sesiones` (the
conductor is driving and has no use for it), though anyone can pick the phone camera.

## Firmware ↔ backend contract

`firmware/esp32cam_frame_sender` is the camera sketch actually flashed (QVGA, a
frame every ~333 ms for the live video, `SERVER_URL` http or https). Keep real
WiFi names, keys and production URLs out of the committed sketches (placeholders
only). It POSTs `multipart/form-data` to `/frame` with fields
`session_id` and `file` (JPEG). `firmware/esp32_pulse_sender` POSTs
`application/x-www-form-urlencoded` `bpm` + `session_id` to `/pulso` every ~2s
and drives an active buzzer on GPIO 25 from the response's `"buzzer"` field
(compact JSON, matched as the literal `"buzzer":true`; it switches off on its own
after 5 s without confirmation). All send `X-Device-Key` when their
`DEVICE_API_KEY` constant is non-empty. If you change endpoint paths, field names,
form vs. JSON encoding, or the `buzzer` field in `app/main.py`, update the
matching sketch.

**Device camera** (`POST /api/camara/dispositivo`, permission `panel`, multipart
`file` + `session_id`): the computer's or phone's camera, chosen in the web header or
the app's camera card, shares `_process_frame()` with `/frame` but never its auth.
It only feeds the user's **own** `users.session_id` (403 otherwise, and no picker
on web/app), so a supervisor/admin viewing a driver never mixes their face into
that driver's data.
While it keeps sending (`DEVICE_CAMERA_PRIORITY_SECONDS`), `/frame` skips analysis for
that session and answers `ignorado: true` with the same status/buzzer fields, so two
cameras never mix in one fusion; the ESP32 resumes by itself when it stops. Web:
`deviceLoop` in `dashboard.html`, which keeps the camera's aspect ratio (stretching
the face would change the EAR) and sends `malla=true` to get the landmarks back and
draw them over the smooth local video. App: `mobile/lib/widgets/device_camera.dart`.
Never change `/frame`, its `X-Device-Key` auth or the sketches for this feature.
`/estado` exposes `camara_fuente` (`dispositivo` / `esp32` / null), plus
`microsueno`, `pitch_ratio`, `ear_basal`, `ear_umbral` (personal threshold, used
by the web/app EAR meter and trend when not null) and `pitch_basal`.

**Live camera and buzzer** (`app/main.py`, in memory only): `/frame` stores the
last frame per session already annotated by `app/overlay.py` (mesh, eye/mouth
contours, EAR/MAR/tilt, fusion banner); `GET /api/camara` serves it as JPEG (204
when stale > `CAMERA_STALE_SECONDS`) and `GET /api/camara/stream` pushes each new
frame as MJPEG (`multipart/x-mixed-replace`, closes when stale). The web
dashboard shows that stream in the hero's eye scanner while `/estado`
reports `camara_activa`. `buzzer` is true while the fusion status is
`alerta`, during a microsleep (`microsueno`), or for the seconds a supervisor requested via `POST /api/buzzer`
(permission `todas_sesiones`); `/estado` exposes `buzzer`, `buzzer_auto`,
`buzzer_manual_seg` and `camara_activa`. A restart clears frames and pending
buzzer requests. In the app, `home_screen.dart` raises a drowsiness alarm when
the live status *changes to* `alerta` (red banner + repeated vibration + a system
notification on the `sidfam_somnolencia` channel); supervisors also get system
notifications of fleet events. `vigilancia` saves no event, so it is detected by
status transition, only when entering from a non-alert state and at most once per
session every 60 s (`FleetController.watchCooldown`): the conductor gets a system
notification and an amber banner (`_watchAlert`, hides after 20 s), supervisors a
system notification for any driver (`detectWatch` → `_fleetWatch`), and the web
dashboard a toast (any driver with `todas_sesiones`, else the own session). App
notifications go through `mobile/lib/notifications.dart`;
for every role an Android foreground service (type `dataSync`,
`android:stopWithTask="true"` in the manifest) keeps polling alive in the
background (conductor: `_live` at a slower pace) — do not set the plugin's own
`stopWithTask` option, it stops the service as soon as the app is hidden.
