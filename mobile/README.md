# SIDFAM móvil (Flutter)

App Android/iOS que replica el panel web de SIDFAM. Es un **cliente** del
backend FastAPI: los ESP32 siguen enviando frames y pulso al servidor, y la
detección (MediaPipe, pulso, fusión) y la base de datos siguen allí. La app
solo consulta y administra, igual que el navegador.

## Qué incluye

| Pestaña / pantalla | Equivale en el web a | Permiso |
|---|---|---|
| **Panel**: estado, canales, pulso con ECG, motor de fusión, medidores vs. umbral, tendencias EAR/BPM, KPI y dona | parte superior de `/` | `panel` |
| **Historial** de episodios con filtros (alto / medio / sensor) | "Historial de episodios" | `panel` |
| **Analítica** (admin/supervisor): panel de **todos los usuarios** (indicadores y nivel de riesgo por persona) y, al tocar uno, su análisis CRISP-DM | `GET /analitica/usuarios` | `analitica` + `todas_sesiones` |
| **Analítica CRISP-DM**: calidad, descriptiva, K-Means, árbol de decisión, regresión logística/lineal, anomalías; exportar CSV (compartir) | sección `#analitica` | `analitica` (CSV: `exportar`) |
| **Mi analítica** (conductor): lo mismo, solo con sus datos | sección `#analitica` | `analitica_propia` |
| **Usuarios** (pestaña del administrador): crear, editar, desactivar, restablecer contraseña | `/usuarios` | `usuarios` |
| **KSS** autoreporte 1-9 | formulario KSS | `autoreporte` |
| Cambiar contraseña / cerrar sesión | menú de usuario | — |

Las pestañas se muestran según el rol, igual que en el web. El estado se
consulta cada 1,5 s y el historial cada 4 s; los episodios nuevos muestran un
aviso y, con el sonido activado (icono de altavoz), suenan y vibran.

## Ejecutar

```bash
cd mobile
flutter pub get
flutter run                 # con un teléfono conectado o un emulador
flutter build apk           # APK en build/app/outputs/flutter-apk/
```

En la pantalla de login, en **Servidor**, escribe:

- en la red local: la IP del computador que corre
  `uvicorn app.main:app --host 0.0.0.0 --port 8000`, por ejemplo
  `192.168.1.100:8000` (el teléfono debe estar en la misma WiFi);
- en el emulador de Android, `10.0.2.2:8000` apunta al localhost del PC;
- en producción, la URL de Railway (`https://...up.railway.app`).

Los usuarios y contraseñas son los mismos del panel web.

La app permite HTTP sin TLS (`usesCleartextTraffic` en Android y
`NSAllowsArbitraryLoads` en iOS) para poder usar la IP local. Si solo se usará
contra Railway (HTTPS), se pueden quitar.

## Estructura

```
lib/
├── main.dart              # arranque y redirección login / cambio de clave / panel
├── api.dart               # cliente HTTP (token Bearer, errores del backend)
├── app_state.dart         # usuario, permisos, umbrales, sesión elegida
├── live_controller.dart   # sondeo de /estado y /eventos
├── theme.dart, util.dart  # colores, textos de estados y formato
├── widgets/               # tarjetas, medidores, ECG, tendencias, dona
└── screens/               # login, panel, historial, analítica, KSS, usuarios, clave
```

## Pruebas

```bash
flutter analyze
flutter test
```
