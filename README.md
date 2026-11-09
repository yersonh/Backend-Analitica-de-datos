# SIDFAM — Backend en la nube

Backend en FastAPI que recibe frames del ESP32-CAM y lecturas de pulso
del ESP32, los analiza (MediaPipe Face Mesh para visión, análisis de
BPM/variabilidad para el pulso), aplica la lógica de fusión
multimodal, y expone un dashboard con el historial de episodios de
fatiga.

## 1. Instalación

```bash
cd sidfam-backend
python3 -m venv venv
source venv/bin/activate        # En Windows: venv\Scripts\activate
pip install -r requirements.txt
```

> **Importante:** `requirements.txt` fija `mediapipe==0.10.13`. Versiones
> más nuevas de `mediapipe` (0.10.18+) eliminaron la API clásica
> `mp.solutions.face_mesh` en favor de la nueva "Tasks API". Si en el
> futuro quieren migrar a esa API para usar una versión más reciente,
> el único archivo que hay que tocar es `app/vision.py`.

## 2. Ejecutar el servidor

```bash
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

- Dashboard: http://localhost:8000/
- Docs interactivas (Swagger, útil para probar sin hardware):
  http://localhost:8000/docs

Para que los ESP32 (en la misma red WiFi) puedan llegar al backend,
usa la IP local de tu computador (ej. `192.168.1.100`) en vez de
`localhost` al correr uvicorn con `--host 0.0.0.0`, y configura esa
misma IP en `SERVER_URL` (cámara) / `SERVER_HOST` (pulso) dentro del firmware.

### Acceso: login y roles

El panel exige iniciar sesión. Al arrancar por primera vez (tabla `users`
vacía) se crea el usuario **`admin`** con una **contraseña temporal que se
imprime en la consola** de uvicorn; al entrar se pide cambiarla. Desde el
menú de usuario → *Usuarios y roles* (`/usuarios`) el administrador crea
las demás cuentas.

| Rol | Qué puede hacer |
|---|---|
| **Administrador** | Todo lo del supervisor + gestionar usuarios (crear, cambiar rol/sesión, desactivar, restablecer contraseña) |
| **Supervisor** | Ver la flota y todas las sesiones en vivo (con cámara), el historial y la analítica, y comparar conductores; hacer sonar el buzzer de un conductor; exportar CSV; registrar KSS. Lo mismo en la web y en la app |
| **Conductor** | Ver **solo su sesión asignada** (el `SESSION_ID` de sus ESP32) en vivo, su historial y la analítica CRISP-DM de **sus** datos; registrar su KSS |

Los permisos y roles están definidos en `app/auth.py` (`PERMISOS`, `ROLES`).
Contraseñas con PBKDF2-SHA256, cookie de sesión firmada (HttpOnly,
SameSite=Lax, 12 h), bloqueo de 5 min tras 5 intentos fallidos. Cambiar la
contraseña, el rol o desactivar una cuenta cierra sus sesiones abiertas.

Los ESP32 no hacen login: se autentican con la cabecera `X-Device-Key`.

Variables de entorno (en Railway, en *Variables* del servicio):

| Variable | Para qué |
|---|---|
| `SECRET_KEY` | Firma las cookies. **Obligatoria en producción**; sin ella las sesiones se cierran en cada reinicio. Genera una con `python -c "import secrets; print(secrets.token_hex(32))"` |
| `DEVICE_API_KEY` | Clave que deben enviar los ESP32 en `X-Device-Key`. Si no se define, `/frame` y `/pulso` aceptan datos de cualquiera (solo para desarrollo local; si falta en producción, con `DATABASE_URL` definida, el arranque lo registra como error). Pon el mismo valor en `DEVICE_API_KEY` de los dos `.ino` |
| `ADMIN_USERNAME` / `ADMIN_PASSWORD` | Opcional: credenciales del primer administrador en lugar de la contraseña temporal generada |

### Verificación facial del conductor

Para que los datos de una sesión sean solo de su conductor, SIDFAM compara
el rostro frente a la cámara con el registrado por el dueño de la sesión
(`app/identity.py`, modelos YuNet + SFace de OpenCV):

1. **Registro (una vez):** en la app (se pide al entrar) o en la web, desde
   el menú de perfil → **Mi rostro** (`/cuenta/rostro`, con la cámara del
   computador; requiere HTTPS o localhost). El conductor acepta el
   tratamiento de sus datos biométricos y se toma 3 fotos guiadas. Sirve para
   conductores que ya existen: no hay que crear cuentas nuevas. Solo se
   guardan vectores numéricos del rostro (tabla `face_enrollments`), nunca
   las fotos, junto con la fecha del consentimiento.
2. **Al entrar:** la app pide una foto y la compara con el registro (en la
   web, *Mi rostro* → *Verificar ahora*).
3. **Durante el monitoreo:** cada frame (ESP32-CAM o celular) se revisa
   cada 5 s (cada 1 s mientras no esté verificada).

Si la sesión tiene conductor registrado y **la cara no coincide** (dos
comparaciones fallidas seguidas) o no se le ha reconocido en los últimos
5 min, **los frames y el pulso de esa sesión se descartan**: no se guardan
ni entran a la fusión. El buzzer manual del supervisor sigue funcionando, y
el supervisor ve el video con el aviso *IDENTIDAD NO VERIFICADA*. Sesiones
sin conductor registrado funcionan como antes (estado `sin_registro`).

El estado está en `/estado` → `identidad` (`verificado`, `pendiente`,
`vencida`, `no_coincide`, `sin_registro`, `deshabilitada`) y se ve en el
panel y en la app. El conductor puede rehacer o **borrar** su registro desde
*Mi rostro* (app o web); el administrador, desde *Usuarios y roles*.

**Modelos:** el Dockerfile los descarga al construir (~40 MB, no van en git).
En local: `python scripts/descargar_modelos.py`. Sin ellos, la verificación
queda `deshabilitada` y todo se acepta como antes (el arranque lo avisa).

**Ley 1581 de 2012:** los datos biométricos son sensibles. El registro exige
consentimiento explícito y se pueden borrar en cualquier momento. Limitación
del prototipo: no hay detección de vida, así que una foto del conductor
mostrada a la cámara podría pasar la verificación.

### App móvil (Flutter)

La carpeta `mobile/` tiene una app Flutter (Android/iOS) que replica el panel
web: login con los mismos roles, estado en vivo, historial, analítica CRISP-DM,
autoreporte KSS y gestión de usuarios. **No reemplaza al backend**: los ESP32
siguen enviando a `/frame` y `/pulso` y el análisis sigue en el servidor; la
app solo consume la API. Instrucciones en [`mobile/README.md`](mobile/README.md).

Para ella el backend expone una API JSON con token Bearer (el mismo token
firmado de la cookie): `POST /api/login`, `POST /api/cuenta/clave` y
`GET /api/config` (umbrales y roles).

### Analítica de datos (CRISP-DM)

`app/analytics.py` sigue las 6 fases de CRISP-DM, y el panel web y la app
las muestran en orden con su nombre:

1. **Comprensión del negocio**: objetivo y criterios de éxito (recall ≥ 0,80,
   precisión ≥ 0,70; `CRITERIO_RECALL` / `CRITERIO_PRECISION`).
2. **Comprensión de los datos**: calidad de las lecturas (`preprocess`).
3. **Preparación de los datos**: limpieza, ventanas de tiempo y análisis
   descriptivo (`build_windows`, `describe`).
4. **Modelado**: 4a K-Means, 4b árbol de decisión, 4c Isolation Forest,
   4d **regresión** logística o lineal.
5. **Evaluación**: métricas de cada modelo y veredicto de si cumple los
   criterios de la fase 1 (`evaluate_criteria`).
6. **Despliegue**: reglas de `fusion.py` en tiempo real, panel web y app.

El reporte (`GET /analitica/reporte`) devuelve todo eso en JSON (la fase 5 en
`evaluacion`). Cada modelo se muestra cuando hay datos suficientes para
calcularlo; mientras tanto, la tarjeta *Modelos pendientes* dice qué falta.

**Regresión logística o lineal** (`regression()`): se elige según la variable
objetivo disponible.

- **Lineal**, si hay suficientes ventanas con autoreporte KSS y este toma al
  menos 3 niveles: la escala 1-9 es numérica, así que se estima el nivel de
  somnolencia (R², MAE, RMSE frente a un modelo base). Solo se elige si
  explica algo (R² ≥ `MIN_R2_LINEAL`).
- **Logística**, si el objetivo es binario (fatiga sí/no: KSS ≥ 7 o, sin KSS,
  el estado de la fusión): modela la probabilidad de fatiga (precisión,
  recall, F1, AUC-ROC, odds ratio por variable).

Cuando se pueden las dos se calculan ambas y `modelo_elegido` + `motivo`
explican la elección.

`GET /analitica/usuarios` (administrador y supervisor) resume a cada persona
monitoreada para compararlas: episodios por hora, % del tiempo en alerta, BPM
y basal, PERCLOS, KSS y un nivel de riesgo; incluye a los conductores que aún
no envían datos. El conductor tiene el permiso `analitica_propia`: ve la
analítica de su sesión y nada más.

## 3. Probar sin hardware (mientras el prototipo físico se arma)

```bash
# Simular una lectura de pulso (añade -H "X-Device-Key: <clave>" si DEVICE_API_KEY está definida)
curl -X POST http://localhost:8000/pulso -F "bpm=72" -F "session_id=default"

# Simular un frame (con cualquier imagen con un rostro)
curl -X POST http://localhost:8000/frame -F "file=@ruta/a/una/foto.jpg" -F "session_id=default"

# Ver el historial de eventos (requiere sesión iniciada: guarda la cookie del login)
curl -c cookies.txt -X POST http://localhost:8000/login -d "username=admin&password=<tu-clave>"
curl -b cookies.txt "http://localhost:8000/eventos?session_id=default"

# Olvidar los basales (pulso, EAR, cabeceo) de una sesión y volver a aprenderlos
curl -b cookies.txt -H "Origin: http://localhost:8000" -H "Content-Type: application/json" \
     -X POST http://localhost:8000/api/sesiones/recalibrar -d '{"session_id": "default"}'
```

### Pruebas automáticas

La lógica de decisión (pulso y fusión) y los endpoints de ingesta tienen
pruebas con `pytest` (usan SQLite temporal, no tocan `app/sidfam.db`):

```bash
pip install -r requirements-dev.txt
python -m pytest -q
```

## 4. Estructura del proyecto

```
sidfam-backend/
├── app/
│   ├── main.py          # Endpoints FastAPI (/frame, /pulso, /eventos, /, login, usuarios)
│   ├── auth.py           # Login, roles, permisos y clave de dispositivo
│   ├── vision.py         # MediaPipe Face Mesh: EAR, MAR, inclinación de cabeza
│   ├── pulse.py           # Buffer y análisis de BPM/variabilidad
│   ├── fusion.py          # Lógica de fusión multimodal + nivel de riesgo
│   ├── identity.py        # Verificación facial del conductor (YuNet + SFace)
│   ├── models/            # Modelos ONNX de rostro (descargados, no van en git)
│   ├── database.py        # Persistencia (PostgreSQL o SQLite)
│   └── templates/
│       ├── dashboard.html # Panel en vivo + historial + analítica
│       ├── login.html, cambiar_clave.html, acceso.html, usuarios.html
│       └── _base.html     # Base visual de las páginas de acceso
├── firmware/
│   ├── esp32cam_frame_sender/    # .ino del ESP32-CAM (QVGA, ~3 fps, http o https)
│   └── esp32_pulse_sender/        # .ino de ejemplo para el ESP32 + sensor de pulso
├── mobile/                        # App Flutter (cliente móvil del panel)
├── scripts/descargar_modelos.py   # Descarga los modelos de rostro
├── tests/                         # Pruebas pytest (pulso, fusión, identidad, endpoints)
├── requirements.txt
├── requirements-dev.txt
└── README.md
```

## 5. Cómo funciona la detección (resumen para el marco teórico)

- **EAR (Eye Aspect Ratio):** relación entre distancias verticales y
  horizontales de los landmarks del ojo. Baja cuando el ojo está
  cerrado, sostenido ≥ 2s (`EYES_CLOSED_SUSTAIN_SECONDS`). El umbral es
  **personal**: los primeros 30 frames con cara de la sesión
  (`CALIBRATION_FRAMES`, ~10 s) fijan un EAR basal (mediana, robusta a
  parpadeos) y "ojo cerrado" pasa a ser EAR < 75 % del basal
  (`EAR_CLOSED_FRACTION`, acotado entre 0.15 y 0.25). Mientras se calibra
  se usa el fijo `EAR_THRESHOLD = 0.21`. Así una persona con ojos más
  pequeños no queda "con los ojos cerrados" todo el tiempo.
- **MAR (Mouth Aspect Ratio):** análogo para la boca, detecta
  bostezos. Umbral: `MAR_THRESHOLD = 0.6`, sostenido ≥ 1.5 s
  (`YAWN_SUSTAIN_SECONDS`) para que hablar o cantar no cuente.
- **Cabeceo:** lateral (*roll*, ángulo entre los ojos externos,
  > 15°) o frontal (*pitch*: posición de la nariz entre la línea de los
  ojos y el mentón, comparada con su basal de calibración; cuenta si se
  aleja más de un 20 %, `PITCH_DEVIATION`). El cabeceo de sueño real es
  sobre todo frontal. Ambos deben sostenerse ≥ 2 s.
- **Pulso:** se mantiene una ventana deslizante de 60s por sesión y
  se evalúa con al menos 15 lecturas (~30s). La somnolencia se juzga
  **frente al basal de la propia persona**, no con un BPM absoluto: la
  mediana de 20 lecturas plausibles fija el basal (se descartan las 5
  primeras, `BASELINE_WARMUP_COUNT`, porque al sentarse y ponerse el
  sensor el pulso suele estar alto), y hay
  señal cuando la **mediana** de la ventana cae un 8 % o más por debajo
  (`RELATIVE_DROP_THRESHOLD`). La mediana resiste los picos de ruido.
  La **baja variabilidad** no dispara nada por sí sola, porque el ESP32
  envía BPM ya promediados: solo suma como razón extra si ya hay caída.
  Una lectura fuera de rango fisiológico es un problema del sensor, no
  fatiga, y no entra a la ventana.
- **Recalibración:** los basales (pulso, EAR, pitch) se descartan y se
  vuelven a aprender si la sesión pasa 10 min sin datos (otro trayecto u
  otro día, `IDLE_RESET_SECONDS`) o si alguien pulsa **Recalibrar** en la
  tarjeta de indicadores (web y app; `POST /api/sesiones/recalibrar`).
  Úsalo si cambia el conductor del equipo, si se movió la cámara o si el
  basal se tomó con el pulso agitado.
- **Fusión:** un episodio de fatiga exige señal visual **y** fisiológica
  al mismo tiempo (RF05). El riesgo depende de cuántas razones concretas
  se acumulan: 2 → **medio**, 3 o más → **alto**. No existe riesgo "bajo".
  Con **un solo canal** el estado es **vigilancia**: no guarda episodio,
  pero no cuenta como normal. La app avisa con una notificación al
  conductor y al supervisor, el panel web muestra un aviso, y el
  historial de ambos marca esos minutos como *Vigilancia*.
- **Cámara:** por defecto la ESP32-CAM; en la web y en la app se puede elegir
  *Este dispositivo* para usar la cámara del computador o del celular
  (requiere HTTPS o `localhost`). Mientras esa cámara envía, el servidor
  ignora las fotos del ESP32 de esa sesión, y el ESP32 retoma solo a los 5 s.
- **Microsueño:** si los ojos siguen cerrados más de 3 s
  (`MICROSLEEP_SECONDS`), el buzzer suena **aunque el pulso no confirme**.
  El pulso cambia en minutos y un microsueño al volante dura segundos.
  RF05 se mantiene para el registro: el estado sigue siendo *vigilancia*
  y no se guarda episodio de fatiga; `/estado` lo indica con
  `microsueno: true`.
- **Buzzer:** suena mientras el estado es **alerta**, durante un
  **microsueño**, y cuando un supervisor pulsa *Despertar* (hasta 15 s,
  5 s por defecto).

Todos los umbrales están centralizados como constantes al inicio de
`vision.py`, `pulse.py` y `fusion.py` — ajústenlos con datos reales
una vez tengan el prototipo armado y puedan calibrar con ustedes
mismos como sujetos de prueba.

### Limitaciones conocidas del prototipo

- **El estado en vivo vive en memoria del proceso:** fusión, basales,
  calibración visual, bloqueo de login, último frame de cámara y buzzer
  manual. Un redeploy o reinicio de Railway los borra (los episodios y
  lecturas guardados en la base no se pierden; el basal se vuelve a
  aprender solo). Por lo mismo, el backend debe correr con **un solo
  worker** de uvicorn: con varios, cada proceso tendría su propio estado
  (RNF05). Para escalar habría que mover ese estado a Redis o a la base.
- Los endpoints de ingesta corren en el threadpool de FastAPI y los
  módulos de análisis usan locks; MediaPipe procesa un frame a la vez.
- Los umbrales de pitch, microsueño y calibración son valores de partida:
  hay que ajustarlos con datos reales.

## 6. Siguientes pasos sugeridos

1. Conectar el ESP32-CAM real y validar que los frames capturados
   dan buena detección de rostro (probar distintas distancias/luz).
2. Conectar el sensor de pulso real y ajustar `pulse.py` si el
   sensor entrega valores crudos en vez de BPM ya calculado.
3. Calibrar umbrales (`EAR_CLOSED_FRACTION`, `MAR_THRESHOLD`,
   `PITCH_DEVIATION`, `MICROSLEEP_SECONDS`, `RELATIVE_DROP_THRESHOLD`,
   etc.) con pruebas propias.
4. Desplegar el backend en un servicio en la nube (Render, Railway,
   una VM gratuita de Oracle Cloud, etc.) para dejar de depender de
   la red local — en ese punto conviene revisar el marco legal sobre
   transferencia internacional de datos si el proveedor aloja fuera
   de Colombia.
5. Actualizar el documento del proyecto: Modelado UML (sección 4.5,
   aún pendiente) y ajustar RF03/RF04/RNF01 para reflejar que la
   inferencia ya no es local sino en la nube.
