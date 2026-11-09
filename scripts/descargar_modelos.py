"""Descarga los modelos de rostro de OpenCV Zoo que usa app/identity.py.

    python scripts/descargar_modelos.py

Los usa la verificación facial del conductor (YuNet para detectar, SFace para
reconocer). No se suben al repositorio (~40 MB): el Dockerfile los descarga al
construir la imagen, y en desarrollo local se descargan con este script. Sin
ellos el backend funciona igual, pero con la verificación facial deshabilitada.
"""

import sys
import urllib.request
from pathlib import Path

DEST = Path(__file__).resolve().parents[1] / "app" / "models"
BASE = "https://github.com/opencv/opencv_zoo/raw/main/models"
MODELS = {
    "face_detection_yunet_2023mar.onnx": f"{BASE}/face_detection_yunet/face_detection_yunet_2023mar.onnx",
    "face_recognition_sface_2021dec.onnx": f"{BASE}/face_recognition_sface/face_recognition_sface_2021dec.onnx",
}
MIN_BYTES = 100_000   # menos que esto es un error o un puntero de Git LFS, no el modelo


def main() -> int:
    DEST.mkdir(parents=True, exist_ok=True)
    for name, url in MODELS.items():
        target = DEST / name
        if target.exists() and target.stat().st_size >= MIN_BYTES:
            print(f"ya existe: {target}")
            continue
        print(f"descargando {name} ...")
        tmp = target.with_suffix(".part")
        urllib.request.urlretrieve(url, tmp)
        size = tmp.stat().st_size
        if size < MIN_BYTES or tmp.read_bytes()[:30].startswith(b"version https://git-lfs"):
            tmp.unlink(missing_ok=True)
            print(f"ERROR: {name} llegó incompleto ({size} bytes) desde {url}", file=sys.stderr)
            return 1
        tmp.replace(target)
        print(f"  ok ({size / 1e6:.1f} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
