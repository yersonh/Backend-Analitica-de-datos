"""Pruebas de los endpoints tocados en la revisión: ingesta y recalibración."""

import cv2
import numpy as np
import pytest
from fastapi.testclient import TestClient

from app import database

DEVICE = {"X-Device-Key": "clave-de-prueba"}


@pytest.fixture(scope="module")
def client(tmp_path_factory):
    database.DB_PATH = tmp_path_factory.mktemp("db") / "sidfam_test.db"
    from app.main import app
    with TestClient(app) as c:
        yield c


@pytest.fixture(scope="module")
def token(client):
    r = client.post("/api/login", json={"username": "admin", "password": "Admin-prueba-123"})
    assert r.status_code == 200, r.text
    return {"Authorization": "Bearer " + r.json()["token"]}


def jpeg() -> bytes:
    ok, buf = cv2.imencode(".jpg", np.full((240, 320, 3), 128, np.uint8))
    assert ok
    return buf.tobytes()


def test_frame_exige_clave_de_dispositivo(client):
    r = client.post("/frame", files={"file": ("f.jpg", jpeg(), "image/jpeg")}, data={"session_id": "t1"})
    assert r.status_code == 401


def test_frame_sin_cara(client):
    r = client.post("/frame", headers=DEVICE, files={"file": ("f.jpg", jpeg(), "image/jpeg")},
                    data={"session_id": "t1"})
    assert r.status_code == 200
    body = r.json()
    assert body["face_detected"] is False and "buzzer" in body


def test_frame_demasiado_grande(client):
    from app.main import MAX_FRAME_BYTES
    r = client.post("/frame", headers=DEVICE,
                    files={"file": ("f.jpg", b"\xff" * (MAX_FRAME_BYTES + 10), "image/jpeg")},
                    data={"session_id": "t1"})
    assert r.status_code == 413


def test_pulso(client):
    r = client.post("/pulso", headers=DEVICE, data={"bpm": "72", "session_id": "t1"})
    assert r.status_code == 200
    assert r.json()["bpm_current"] == 72


def test_recalibrar(client, token):
    for _ in range(30):
        client.post("/pulso", headers=DEVICE, data={"bpm": "72", "session_id": "t2"})
    st = client.get("/estado?session_id=t2", headers=token).json()
    assert st["baseline_bpm"] == 72
    r = client.post("/api/sesiones/recalibrar", headers=token, json={"session_id": "t2"})
    assert r.status_code == 200 and r.json()["recalibrada"]
    r = client.post("/pulso", headers=DEVICE, data={"bpm": "72", "session_id": "t2"})
    assert r.json()["baseline_bpm"] is None


def test_recalibrar_requiere_sesion_y_login(client, token):
    assert client.post("/api/sesiones/recalibrar", json={"session_id": "t2"}).status_code == 401
    assert client.post("/api/sesiones/recalibrar", headers=token, json={}).status_code == 422


def test_estado_expone_campos_nuevos(client, token):
    st = client.get("/estado?session_id=t1", headers=token).json()
    for k in ("microsueno", "ear_basal", "ear_umbral", "pitch_basal", "pitch_ratio"):
        assert k in st
