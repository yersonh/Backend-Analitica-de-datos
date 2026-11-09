"""Verificación facial del conductor (app/identity.py) y su efecto en la ingesta.

Los modelos reales (YuNet + SFace) no se cargan aquí: un identificador simulado
decide la "persona" según el color de la imagen, así se prueba la lógica
(registro, verificación, descarte de datos) sin depender de fotos ni modelos.
"""

import cv2
import numpy as np
import pytest
from fastapi.testclient import TestClient

from app import database, identity
from app.identity import FaceSample, IdentityError, IdentityGuard

DEVICE = {"X-Device-Key": "clave-de-prueba"}

# Color de la imagen -> quién aparece en ella
SIN_CARA, ANA, BETO, DOS_CARAS = 0, 60, 120, 250


def _vec(person: int, jitter: float = 0.0) -> np.ndarray:
    v = np.zeros(128, np.float32)
    v[person % 128] = 1.0
    v[(person + 1) % 128] = jitter
    return v / np.linalg.norm(v)


class FakeIdentifier:
    available = True
    unavailable_reason = None

    def faces(self, image_bgr):
        value = int(image_bgr[0, 0, 0])
        jitter = image_bgr[0, 0, 1] / 255.0      # variación entre fotos de la misma persona
        if value == SIN_CARA:
            return []
        if value == DOS_CARAS:
            return [FaceSample(_vec(ANA), (0, 0, 80, 80)), FaceSample(_vec(BETO), (90, 0, 80, 80))]
        return [FaceSample(_vec(value, jitter), (0, 0, 100, 100))]


class NoModels:
    available = False
    unavailable_reason = "sin modelos"

    def faces(self, image_bgr):
        return []


def img(person: int, jitter: int = 0) -> np.ndarray:
    a = np.zeros((240, 320, 3), np.uint8)
    a[:, :, 0] = person
    a[:, :, 1] = jitter
    return a


def jpeg(person: int, jitter: int = 0) -> bytes:
    ok, buf = cv2.imencode(".png", img(person, jitter))   # PNG: sin pérdidas, conserva el "color"
    assert ok
    return buf.tobytes()


# ---------------------------------------------------------------------------
# Lógica pura
# ---------------------------------------------------------------------------

def test_registro_valida_fotos():
    f = FakeIdentifier()
    emb = identity.build_enrollment(f, [img(ANA, j) for j in (0, 20, 40)])
    assert len(emb) == 3 and len(emb[0]) == 128
    with pytest.raises(IdentityError, match="entre"):
        identity.build_enrollment(f, [img(ANA)] * 2)
    with pytest.raises(IdentityError, match="Foto 2.*rostro claro"):
        identity.build_enrollment(f, [img(ANA), img(SIN_CARA), img(ANA)])
    with pytest.raises(IdentityError, match="más de un rostro"):
        identity.build_enrollment(f, [img(ANA), img(DOS_CARAS), img(ANA)])
    with pytest.raises(IdentityError, match="misma persona"):
        identity.build_enrollment(f, [img(ANA), img(BETO), img(ANA)])


@pytest.fixture
def guard(monkeypatch, clock):
    g = IdentityGuard(FakeIdentifier())
    enrollments = {"s1": [{"user_id": 7, "embeddings": [_vec(ANA).tolist()]}]}
    monkeypatch.setattr(database, "face_enrollments_for_session", lambda sid: enrollments.get(sid, []))
    return g


def test_sesion_sin_registro_acepta_datos(guard):
    assert guard.check_frame("otra", img(BETO))
    assert guard.status("otra")["estado"] == "sin_registro"


def test_sin_modelos_acepta_y_marca_deshabilitada(monkeypatch):
    monkeypatch.setattr(database, "face_enrollments_for_session", lambda sid: [{"user_id": 1, "embeddings": []}])
    g = IdentityGuard(NoModels())
    assert g.check_frame("s1", img(BETO)) and g.status("s1")["estado"] == "deshabilitada"


def test_conductor_correcto_verifica_y_acepta(guard):
    assert guard.status("s1")["estado"] == "pendiente"
    assert guard.check_frame("s1", img(ANA))
    st = guard.status("s1")
    assert st["estado"] == "verificado" and st["acepta_datos"]


def test_otra_persona_se_rechaza_tras_dos_comparaciones(guard, clock):
    guard.check_frame("s1", img(ANA))
    clock.advance(identity.CHECK_INTERVAL_VERIFIED)
    # una sola comparación fallida no corta los datos (una foto mala pasa)
    assert guard.check_frame("s1", img(BETO))
    clock.advance(identity.CHECK_INTERVAL_VERIFIED)
    assert not guard.check_frame("s1", img(BETO))
    assert guard.status("s1")["estado"] == "no_coincide"
    # vuelve el conductor: se recupera con una coincidencia
    clock.advance(identity.CHECK_INTERVAL_UNVERIFIED)
    assert guard.check_frame("s1", img(ANA))


def test_nunca_verificada_no_acepta(guard):
    assert not guard.check_frame("s1", img(SIN_CARA))
    assert guard.status("s1")["estado"] == "pendiente"
    assert not guard.allows_data("s1")


def test_sin_cara_mantiene_la_verificacion_hasta_vencer(guard, clock):
    guard.check_frame("s1", img(ANA))
    clock.advance(identity.VALID_SECONDS - 10)
    assert guard.check_frame("s1", img(SIN_CARA))
    clock.advance(20)
    assert not guard.check_frame("s1", img(SIN_CARA))
    assert guard.status("s1")["estado"] == "vencida"


def test_entre_comprobaciones_no_se_recalcula(guard, clock):
    guard.check_frame("s1", img(ANA))
    clock.advance(1)                               # antes de CHECK_INTERVAL_VERIFIED
    assert guard.check_frame("s1", img(BETO))      # aún no se compara
    assert guard.status("s1")["estado"] == "verificado"


def test_conductor_con_acompanante(guard):
    assert guard.check_frame("s1", img(DOS_CARAS))
    assert guard.status("s1")["estado"] == "verificado"


def test_verificacion_explicita_falla_de_una(guard):
    r = guard.verify_image("s1", img(BETO))
    assert r["coincide"] is False and r["estado"] == "no_coincide"
    assert guard.verify_image("s1", img(ANA))["coincide"] is True
    with pytest.raises(IdentityError):
        guard.verify_image("sin_registro", img(ANA))


# ---------------------------------------------------------------------------
# Endpoints e ingesta
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def client(tmp_path_factory):
    database.DB_PATH = tmp_path_factory.mktemp("db") / "sidfam_identidad.db"
    mp = pytest.MonkeyPatch()
    fake = FakeIdentifier()
    mp.setattr(identity, "face_identifier", fake)
    from app.main import app, identity_guard
    mp.setattr(identity_guard, "identifier", fake)
    identity_guard.invalidate()
    with TestClient(app) as c:
        yield c
    mp.undo()


@pytest.fixture(scope="module")
def admin(client):
    r = client.post("/api/login", json={"username": "admin", "password": "Admin-prueba-123"})
    return {"Authorization": "Bearer " + r.json()["token"]}


@pytest.fixture(scope="module")
def conductor(client, admin):
    r = client.post("/api/usuarios", headers=admin,
                    json={"username": "ana", "role": "conductor", "session_id": "ruta_ana", "password": "Conductora-123"})
    assert r.status_code == 201, r.text
    tok = client.post("/api/login", json={"username": "ana", "password": "Conductora-123"}).json()["token"]
    r = client.post("/api/cuenta/clave", headers={"Authorization": "Bearer " + tok},
                    json={"actual": "Conductora-123", "nueva": "Conductora-456", "confirmar": "Conductora-456"})
    assert r.status_code == 200, r.text
    return {"Authorization": "Bearer " + r.json()["token"]}


def frame(client, person, session="ruta_ana"):
    return client.post("/frame", headers=DEVICE, files={"file": ("f.png", jpeg(person), "image/png")},
                       data={"session_id": session})


def readings(session):
    return database.list_readings(session)


def test_sin_registro_pide_registro_y_acepta_datos(client, conductor):
    r = client.get("/api/identidad", headers=conductor).json()
    assert r["aplica"] and r["habilitada"] and not r["registrado"] and r["necesita"] == "registro"
    assert frame(client, BETO).json().get("ignorado") is None


def test_registro_exige_consentimiento(client, conductor):
    files = [("files", (f"{i}.png", jpeg(ANA, i * 10), "image/png")) for i in range(3)]
    r = client.post("/api/identidad/registro", headers=conductor, files=files)
    assert r.status_code == 422 and "biométricos" in r.json()["detail"]


def test_registro_y_filtrado(client, conductor, admin):
    files = [("files", (f"{i}.png", jpeg(ANA, i * 10), "image/png")) for i in range(3)]
    r = client.post("/api/identidad/registro", headers=conductor, files=files, data={"consentimiento": "true"})
    assert r.status_code == 200, r.text
    assert r.json()["estado"]["estado"] == "verificado"

    users = client.get("/api/usuarios", headers=admin).json()["usuarios"]
    assert next(u for u in users if u["username"] == "ana")["rostro_registrado"] is True

    antes = len(readings("ruta_ana"))
    assert frame(client, ANA).json().get("ignorado") is None
    assert len(readings("ruta_ana")) == antes + 1

    # Otra persona frente a la cámara: verificación explícita falla y se descarta todo
    r = client.post("/api/identidad/verificar", headers=conductor,
                    files={"file": ("f.png", jpeg(BETO), "image/png")}).json()
    assert r["coincide"] is False
    antes = len(readings("ruta_ana"))
    rf = frame(client, BETO).json()
    assert rf["ignorado"] and rf["motivo"] == "identidad" and "buzzer" in rf
    rp = client.post("/pulso", headers=DEVICE, data={"bpm": "70", "session_id": "ruta_ana"}).json()
    assert rp["ignorado"] and rp["motivo"] == "identidad"
    assert len(readings("ruta_ana")) == antes

    st = client.get("/estado?session_id=ruta_ana", headers=conductor).json()
    assert st["identidad"]["estado"] == "no_coincide"
    assert client.get("/api/identidad", headers=conductor).json()["necesita"] == "verificacion"

    # Vuelve la conductora: se verifica y los datos se aceptan de nuevo
    r = client.post("/api/identidad/verificar", headers=conductor,
                    files={"file": ("f.png", jpeg(ANA), "image/png")}).json()
    assert r["coincide"] is True
    assert client.post("/pulso", headers=DEVICE, data={"bpm": "70", "session_id": "ruta_ana"}).json().get("ignorado") is None


def test_foto_sin_rostro_al_verificar(client, conductor):
    r = client.post("/api/identidad/verificar", headers=conductor,
                    files={"file": ("f.png", jpeg(SIN_CARA), "image/png")})
    assert r.status_code == 422


def test_admin_y_conductor_pueden_borrar(client, conductor, admin):
    users = client.get("/api/usuarios", headers=admin).json()["usuarios"]
    ana = next(u for u in users if u["username"] == "ana")
    assert client.delete(f"/api/usuarios/{ana['id']}/rostro", headers=admin).json()["borrado"] is True
    assert frame(client, BETO).json().get("ignorado") is None     # sin registro: vuelve a aceptar
    files = [("files", (f"{i}.png", jpeg(ANA, i * 10), "image/png")) for i in range(3)]
    client.post("/api/identidad/registro", headers=conductor, files=files, data={"consentimiento": "true"})
    assert client.delete("/api/identidad/registro", headers=conductor).json()["borrado"] is True
    assert client.get("/api/identidad", headers=conductor).json()["registrado"] is False


def test_supervisor_sin_sesion_propia(client, admin):
    assert client.get("/api/identidad", headers=admin).json() == {"aplica": False}
    r = client.post("/api/identidad/verificar", headers=admin, files={"file": ("f.png", jpeg(ANA), "image/png")})
    assert r.status_code == 403


# ---------------------------------------------------------------------------
# Web: Perfil > Mi rostro (/cuenta/rostro), con la cookie de sesión
# ---------------------------------------------------------------------------

def web_login(client, username, password):
    c = TestClient(client.app, base_url="http://testserver")
    r = c.post("/login", data={"username": username, "password": password}, follow_redirects=False)
    assert r.status_code == 303, r.text
    return c


def test_web_pagina_mi_rostro(client, conductor):
    web = web_login(client, "ana", "Conductora-456")
    r = web.get("/cuenta/rostro", headers={"Accept": "text/html"})
    assert r.status_code == 200 and "Mi rostro" in r.text and "ruta_ana" in r.text
    # el menú de perfil del panel enlaza la página
    assert '<a href="/cuenta/rostro" role="menuitem"' in web.get("/", headers={"Accept": "text/html"}).text


def test_web_registro_con_cookie_mismo_origen(client, conductor):
    web = web_login(client, "ana", "Conductora-456")
    files = [("files", (f"{i}.jpg", jpeg(ANA, i * 10), "image/jpeg")) for i in range(3)]
    # el navegador envía Origin del mismo sitio: la defensa CSRF lo deja pasar
    r = web.post("/api/identidad/registro", files=files, data={"consentimiento": "true"},
                 headers={"Origin": "http://testserver"})
    assert r.status_code == 200, r.text
    # desde otro origen se rechaza
    r = web.post("/api/identidad/registro", files=files, data={"consentimiento": "true"},
                 headers={"Origin": "http://otro-sitio.example"})
    assert r.status_code == 403
    assert web.delete("/api/identidad/registro", headers={"Origin": "http://testserver"}).json()["borrado"] is True


def test_web_mi_rostro_sin_sesion_propia(client, admin):
    web = web_login(client, "admin", "Admin-prueba-123")
    r = web.get("/cuenta/rostro", headers={"Accept": "text/html"})
    assert r.status_code == 200 and "sesión propia" in r.text
    assert '<a href="/cuenta/rostro" role="menuitem"' not in web.get("/", headers={"Accept": "text/html"}).text
