"""Utilidades compartidas por las pruebas de SIDFAM.

`clock` reemplaza time.time() por un reloj controlado: las reglas de pulso y
fusión dependen de ventanas y tiempos sostenidos, y así se prueban sin esperar.
"""

import os
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

# Antes de importar app.*: auth lee estas variables al importarse.
os.environ.setdefault("DEVICE_API_KEY", "clave-de-prueba")
os.environ.setdefault("SECRET_KEY", "secreto-de-prueba")
os.environ.setdefault("ADMIN_USERNAME", "admin")
os.environ.setdefault("ADMIN_PASSWORD", "Admin-prueba-123")
os.environ.pop("DATABASE_URL", None)


class Clock:
    def __init__(self, start: float = 1_000_000.0):
        self.now = start

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


@pytest.fixture
def clock(monkeypatch):
    c = Clock()
    monkeypatch.setattr("time.time", c)
    return c
