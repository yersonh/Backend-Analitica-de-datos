"""
Analítica / minería de datos para SIDFAM.

Sigue la metodología CRISP-DM sobre la tabla `sensor_readings`, que guarda
CADA lectura recibida de los ESP32:

  1. Comprensión del negocio -> objetivo y criterios de éxito
                                (CRITERIO_RECALL / CRITERIO_PRECISION).
  2. Comprensión de los datos -> lecturas de una sesión (load_readings),
                                calidad y análisis descriptivo (describe).
  3. Preparación de los datos -> duplicados, nulos, lecturas implausibles,
                                inconsistencias y atípicos (preprocess);
                                integración visión + pulso en ventanas de
                                tiempo (1 minuto por defecto) y extracción de
                                características (build_windows).
  4. Modelado                -> clustering K-Means (cluster), árbol de
                                decisión + comparación de modelos (classify),
                                regresión logística o lineal según la variable
                                objetivo disponible (regression) y detección
                                de anomalías con Isolation Forest (anomalies).
  5. Evaluación              -> silueta, matriz de confusión, precisión,
                                recall, F1, AUC, R², MAE, validación cruzada y
                                comparación contra modelos base.
  6. Despliegue              -> reglas de fusion.py en tiempo real, panel web
                                y app móvil; recomendaciones derivadas de los
                                resultados.

users_overview() resume cada usuario / sesión para el panel del administrador.

Sesiones y personas: el session_id se escribe como "persona_prueba"
(p. ej. "lauren_1", "lauren_2"). La parte antes del primer "_" identifica a
la persona. Con session_id="todas" se analizan todas las sesiones juntas y,
si hay al menos 3 personas, la evaluación del árbol separa por PERSONA
(ninguna persona aparece a la vez en entrenamiento y prueba), como exige la
metodología para evitar una evaluación demasiado optimista.

Todas las funciones devuelven estructuras JSON-serializables para que
app/main.py las exponga tal cual en los endpoints /analitica/*.

Etiqueta (variable objetivo) para el modelo supervisado:
  - Si hay suficientes autoreportes KSS (tabla self_reports), se usa
    KSS >= 7 ("somnoliento") como etiqueta REAL.
  - Si no, se usa el estado de la fusión por reglas (status "alerta").
    En ese caso el árbol "reaprende" las reglas de fusion.py: sirve para
    ver qué variables pesan más y obtener reglas legibles, pero NO es una
    validación independiente del sistema. La respuesta lo indica con
    `fuente_etiqueta`.
"""

from __future__ import annotations

import math
from datetime import timedelta

import numpy as np
import pandas as pd
from sklearn.cluster import KMeans
from sklearn.decomposition import PCA
from sklearn.dummy import DummyClassifier
from sklearn.ensemble import IsolationForest, RandomForestClassifier
from sklearn.linear_model import LinearRegression, LogisticRegression
from sklearn.metrics import (
    accuracy_score, adjusted_rand_score, confusion_matrix, f1_score,
    mean_absolute_error, mean_squared_error, precision_score, r2_score,
    recall_score, roc_auc_score, roc_curve, silhouette_score,
)
from sklearn.model_selection import (
    GroupKFold, GroupShuffleSplit, KFold, StratifiedKFold, cross_val_score, train_test_split,
)
from sklearn.naive_bayes import GaussianNB
from sklearn.neighbors import KNeighborsClassifier
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.tree import DecisionTreeClassifier, export_text

from . import database

# --- Parámetros del pipeline (ajustables) ---
VENTANA_DEFECTO_S = 60         # ventana de agregación: 1 minuto (metodología del documento)
TODAS = "todas"                # session_id especial: analizar todas las sesiones juntas
MIN_READINGS = 30              # mínimo de lecturas para correr la analítica
MIN_WINDOWS_CLUSTER = 10
MIN_WINDOWS_CLASSIFY = 20
MIN_PERSONAS_GRUPOS = 3        # personas necesarias para separar entrenamiento/prueba por persona
GAP_COMUNICACION_S = 10        # sin lecturas de una fuente por más de esto = pérdida de comunicación
GAP_FIN_SESION_S = 600         # huecos más largos se consideran pausas entre pruebas, no pérdidas
KSS_SOMNOLIENTO = 7            # KSS >= 7 -> somnoliento (Åkerstedt & Gillberg, 1990)
KSS_MAX_AGE = timedelta(minutes=10)  # un autoreporte etiqueta las ventanas de los 10 min siguientes
PLAUSIBLE_BPM = (30, 220)      # mismo rango que pulse.py
IQR_K = 3.0                    # factor IQR para atípicos (3 = solo atípicos extremos)
RANDOM_STATE = 42
# Criterios de éxito (CRISP-DM fase 1). Propuestos para un sistema de
# seguridad: perder fatiga real es peor que una falsa alarma, por eso se exige
# más recall que precisión. Ajústenlos con el documento del proyecto.
CRITERIO_RECALL = 0.80
CRITERIO_PRECISION = 0.70
MIN_KSS_NIVELES_LINEAL = 3     # valores distintos de KSS para tratarlo como variable continua
MIN_R2_LINEAL = 0.10           # por debajo, la regresión lineal no explica lo suficiente

FEATURES = [
    "ear_mean",       # apertura media del ojo
    "perclos",        # % de frames con ojos cerrados (PERCLOS)
    "mar_max",        # apertura máxima de la boca
    "yawn_count",     # frames con bostezo en la ventana
    "tilt_abs_mean",  # inclinación media de la cabeza (valor absoluto, grados)
    "bpm_mean",       # pulso medio
    "bpm_std",        # variabilidad del pulso en la ventana
    "bpm_drop_pct",   # caída del pulso respecto al basal de la persona (%)
]

FEATURE_LABELS = {
    "ear_mean": "EAR medio",
    "perclos": "PERCLOS (%)",
    "mar_max": "MAR máximo",
    "yawn_count": "Bostezos",
    "tilt_abs_mean": "Inclinación (°)",
    "bpm_mean": "BPM medio",
    "bpm_std": "Desv. BPM",
    "bpm_drop_pct": "Caída BPM vs basal (%)",
}

_STATUS_PRIORITY = {"advertencia_sensor": 0, "normal": 1, "vigilancia": 2, "alerta": 3}


# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------

def _clean(obj):
    """Convierte tipos numpy/pandas a tipos nativos y NaN -> None."""
    if isinstance(obj, dict):
        return {str(k): _clean(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [_clean(v) for v in obj]
    if isinstance(obj, (np.integer,)):
        return int(obj)
    if isinstance(obj, (np.floating, float)):
        v = float(obj)
        return None if math.isnan(v) or math.isinf(v) else round(v, 4)
    if isinstance(obj, (np.bool_,)):
        return bool(obj)
    if isinstance(obj, (pd.Timestamp,)):
        return obj.isoformat(timespec="seconds")
    if obj is pd.NaT:
        return None
    return obj


def persona_de(session_id: str) -> str:
    """'lauren_2' -> 'lauren'. Sin '_' la sesión completa es la persona."""
    return str(session_id).split("_", 1)[0]


def _insufficient(msg: str, **extra) -> dict:
    return {"disponible": False, "mensaje": msg, **extra}


# ---------------------------------------------------------------------------
# 1. Selección
# ---------------------------------------------------------------------------

def load_readings(session_id: str) -> pd.DataFrame:
    rows = database.list_readings(session_id=None if session_id == TODAS else session_id)
    df = pd.DataFrame(rows)
    if df.empty:
        return df
    df["timestamp"] = pd.to_datetime(df["timestamp"], format="ISO8601")
    return df


# ---------------------------------------------------------------------------
# 2. Preprocesamiento
# ---------------------------------------------------------------------------

def preprocess(df: pd.DataFrame) -> tuple[pd.DataFrame, dict]:
    """Limpia el dataset y devuelve (df_limpio, reporte_de_calidad)."""
    report: dict = {"registros_iniciales": int(len(df))}
    df = df.copy()

    # Duplicados: misma sesión, mismo instante y misma fuente
    before = len(df)
    df = df.drop_duplicates(subset=["session_id", "timestamp", "source"])
    report["duplicados_eliminados"] = int(before - len(df))

    frames = df["source"] == "frame"
    pulses = df["source"] == "pulso"
    report["lecturas_frame"] = int(frames.sum())
    report["lecturas_pulso"] = int(pulses.sum())

    # Faltantes: frames donde no se detectó rostro (no aportan EAR/MAR)
    no_face = frames & (df["face_detected"].fillna(0) == 0)
    report["frames_sin_rostro"] = int(no_face.sum())
    report["pct_frames_sin_rostro"] = round(100 * no_face.sum() / max(frames.sum(), 1), 2)
    df.loc[no_face, ["ear", "mar", "head_tilt_deg"]] = np.nan

    # Lecturas de pulso implausibles (error de sensor, no fatiga)
    implausible = pulses & ((df["bpm"] < PLAUSIBLE_BPM[0]) | (df["bpm"] > PLAUSIBLE_BPM[1]))
    report["bpm_implausibles"] = int(implausible.sum())
    df.loc[implausible, "bpm"] = np.nan

    # Inconsistencias: valores imposibles por definición de la métrica
    bad_ear = df["ear"].notna() & ((df["ear"] < 0) | (df["ear"] > 1))
    bad_mar = df["mar"].notna() & ((df["mar"] < 0) | (df["mar"] > 2))
    report["valores_inconsistentes"] = int(bad_ear.sum() + bad_mar.sum())
    df.loc[bad_ear, "ear"] = np.nan
    df.loc[bad_mar, "mar"] = np.nan

    # Ruido / atípicos extremos por rango intercuartílico. Solo sobre el BPM:
    # en EAR y MAR los valores extremos (ojos cerrados, bostezos) son
    # justamente la señal de fatiga, así que NO se tratan como ruido; para
    # ellos basta el control de inconsistencias de arriba.
    outliers = {}
    for col in ("bpm",):
        s = df[col].dropna()
        if len(s) < 10:
            outliers[col] = 0
            continue
        q1, q3 = s.quantile([0.25, 0.75])
        iqr = q3 - q1
        lo, hi = q1 - IQR_K * iqr, q3 + IQR_K * iqr
        mask = df[col].notna() & ((df[col] < lo) | (df[col] > hi))
        outliers[col] = int(mask.sum())
        df.loc[mask, col] = np.nan
    report["atipicos_eliminados"] = outliers

    # Pérdidas de comunicación: huecos sin lecturas de una fuente (caso de uso 3,
    # flujo alterno). Se distinguen de la ausencia de fatiga.
    gaps_n, gaps_s = 0, 0.0
    for (_, _), g in df.sort_values("timestamp").groupby(["session_id", "source"]):
        d = g["timestamp"].diff().dt.total_seconds()
        hole = d[(d > GAP_COMUNICACION_S) & (d <= GAP_FIN_SESION_S)]
        gaps_n += int(len(hole))
        gaps_s += float(hole.sum())
    report["perdidas_comunicacion"] = gaps_n
    report["segundos_sin_comunicacion"] = round(gaps_s, 1)

    report["nulos_por_variable"] = {
        c: int(df.loc[frames if c in ("ear", "mar", "head_tilt_deg") else pulses, c].isna().sum())
        for c in ("ear", "mar", "head_tilt_deg", "bpm")
    }
    report["registros_finales"] = int(len(df))
    return df, report


# ---------------------------------------------------------------------------
# 3. Transformación: integración visión + pulso en ventanas
# ---------------------------------------------------------------------------

def _worst_status(s: pd.Series):
    s = s.dropna()
    if s.empty:
        return None
    return max(s, key=lambda v: _STATUS_PRIORITY.get(v, 1))


def build_windows(df: pd.DataFrame, ventana_s: int = VENTANA_DEFECTO_S) -> pd.DataFrame:
    """Agrega las lecturas en ventanas de `ventana_s` segundos, sesión por
    sesión, y calcula las características."""
    if df.empty:
        return pd.DataFrame()
    parts = [_session_windows(g, sid, f"{int(ventana_s)}s") for sid, g in df.groupby("session_id")]
    parts = [p for p in parts if not p.empty]
    if not parts:
        return pd.DataFrame()
    w = pd.concat(parts, ignore_index=True).sort_values(["timestamp", "session_id"]).reset_index(drop=True)
    first = ["timestamp", "session_id", "persona"] + FEATURES
    return w[first + [c for c in w.columns if c not in first]]


def _session_windows(df: pd.DataFrame, session_id: str, regla: str) -> pd.DataFrame:
    df = df.set_index("timestamp").sort_index()
    frames = df[df["source"] == "frame"]
    pulses = df[df["source"] == "pulso"]

    vis = pd.DataFrame(index=pd.DatetimeIndex([], name="timestamp"))
    if not frames.empty:
        face = frames[frames["face_detected"].fillna(0) == 1]
        g = face.resample(regla)
        vis = pd.DataFrame({
            "ear_mean": g["ear"].mean(),
            "ear_min": g["ear"].min(),
            "perclos": g["eyes_closed"].mean() * 100,
            "mar_max": g["mar"].max(),
            "yawn_count": g["yawning"].sum(min_count=1),
            "tilt_abs_mean": g["head_tilt_deg"].apply(lambda s: s.abs().mean()),
        })
        all_frames = frames.resample(regla)["face_detected"]
        vis = vis.join((all_frames.mean() * 100).rename("pct_rostro"), how="outer")

    pul = pd.DataFrame(index=pd.DatetimeIndex([], name="timestamp"))
    if not pulses.empty:
        g = pulses.resample(regla)
        pul = pd.DataFrame({
            "bpm_mean": g["bpm"].mean(),
            "bpm_std": g["bpm"].std(ddof=0),
            "baseline_bpm": g["baseline_bpm"].last(),
        })
        # El basal es fijo por sesión: se propaga hacia adelante
        pul["baseline_bpm"] = pul["baseline_bpm"].ffill()
        pul["bpm_drop_pct"] = (pul["baseline_bpm"] - pul["bpm_mean"]) / pul["baseline_bpm"] * 100

    status = df.resample(regla)["fusion_status"].apply(_worst_status).rename("estado_fusion")
    risk = df.resample(regla)["risk_level"].apply(
        lambda s: "alto" if (s == "alto").any() else ("medio" if (s == "medio").any() else None)
    ).rename("riesgo")
    n = df.resample(regla)["source"].count().rename("n_lecturas")

    w = vis.join(pul, how="outer").join(status, how="outer").join(risk, how="outer").join(n, how="outer")
    w = w[w["n_lecturas"] > 0]
    # Pulso llega cada ~2 s: si una ventana quedó sin pulso se toma el de la anterior
    for c in ("bpm_mean", "bpm_std", "baseline_bpm", "bpm_drop_pct"):
        if c in w:
            w[c] = w[c].ffill(limit=2)

    w["fatiga_regla"] = (w["estado_fusion"] == "alerta").astype(int)

    # Etiqueta real: último autoreporte KSS de los KSS_MAX_AGE anteriores
    reports = pd.DataFrame(database.list_self_reports(session_id=session_id))
    w = w.reset_index()
    if not reports.empty:
        reports["timestamp"] = pd.to_datetime(reports["timestamp"], format="ISO8601")
        reports = reports.sort_values("timestamp")[["timestamp", "kss"]]
        w = pd.merge_asof(w.sort_values("timestamp"), reports, on="timestamp",
                          direction="backward", tolerance=KSS_MAX_AGE)
    else:
        w["kss"] = np.nan
    w["somnoliento_kss"] = np.where(w["kss"].isna(), np.nan, (w["kss"] >= KSS_SOMNOLIENTO).astype(float))

    for c in FEATURES:
        if c not in w:
            w[c] = np.nan
    w.insert(1, "session_id", session_id)
    w.insert(2, "persona", persona_de(session_id))
    return w


def _complete(w: pd.DataFrame) -> pd.DataFrame:
    """Ventanas con TODAS las características (requisito de los algoritmos)."""
    return w.dropna(subset=FEATURES).reset_index(drop=True)


# ---------------------------------------------------------------------------
# 4a. Minería descriptiva
# ---------------------------------------------------------------------------

def describe(w: pd.DataFrame, session_id: str) -> dict:
    wc = _complete(w)
    stats = {}
    for c in FEATURES:
        s = w[c].dropna()
        stats[c] = {
            "etiqueta": FEATURE_LABELS[c],
            "n": len(s), "media": s.mean(), "desv": s.std(), "min": s.min(),
            "p50": s.median(), "max": s.max(),
        }

    corr = wc[FEATURES].corr().round(3) if len(wc) >= 3 else None

    # Comparación de las características según el estado de la fusión
    by_status = {}
    if not wc.empty:
        grp = wc.groupby("estado_fusion")[FEATURES].mean()
        by_status = {st: row.to_dict() for st, row in grp.iterrows()}

    events = pd.DataFrame(database.list_events(
        session_id=None if session_id == TODAS else session_id, limit=100000))
    por_hora, por_dia = {}, {}
    if not events.empty:
        ts = pd.to_datetime(events["timestamp"], format="ISO8601")
        fatigue = events["sensor_warning"].astype(int) == 0
        por_hora = ts[fatigue].dt.hour.value_counts().sort_index().to_dict()
        por_dia = ts[fatigue].dt.date.astype(str).value_counts().sort_index().to_dict()

    distrib = w["estado_fusion"].value_counts().to_dict()

    cols = ["timestamp", "ear_mean", "perclos", "bpm_mean", "bpm_drop_pct"]
    if w["session_id"].nunique() > 1:
        # varias sesiones: promedio por instante (si se solapan) para no mezclar líneas
        serie = w[cols].groupby("timestamp", as_index=False).mean().tail(720)
    else:
        serie = w[cols].tail(720)

    return {
        "disponible": True,
        "ventanas_totales": len(w),
        "ventanas_completas": len(wc),
        "estadisticos": stats,
        "correlacion": {"variables": FEATURES, "matriz": corr.values.tolist()} if corr is not None else None,
        "medias_por_estado": by_status,
        "distribucion_estados": distrib,
        "eventos_por_hora": por_hora,
        "eventos_por_dia": por_dia,
        "serie_temporal": serie.to_dict(orient="records"),
    }


# ---------------------------------------------------------------------------
# 4b. Clustering (no supervisado): K-Means
# ---------------------------------------------------------------------------

def cluster(w: pd.DataFrame) -> dict:
    wc = _complete(w)
    if len(wc) < MIN_WINDOWS_CLUSTER:
        return _insufficient(
            f"Se necesitan al menos {MIN_WINDOWS_CLUSTER} ventanas completas (hay {len(wc)})."
        )

    X = wc[FEATURES].values
    scaler = StandardScaler()
    Xs = scaler.fit_transform(X)

    # Selección de k por coeficiente de silueta
    siluetas = {}
    for k in range(2, min(6, len(wc) - 1) + 1):
        labels = KMeans(n_clusters=k, n_init=10, random_state=RANDOM_STATE).fit_predict(Xs)
        if len(set(labels)) > 1:
            siluetas[k] = silhouette_score(Xs, labels)
    if not siluetas:
        return _insufficient("Los datos no presentan variación suficiente para agrupar.")
    # Se prefiere k=3 (alerta / intermedio / somnolencia) si su silueta es casi la mejor
    best_k = max(siluetas, key=siluetas.get)
    if 3 in siluetas and siluetas[3] >= siluetas[best_k] - 0.05:
        best_k = 3

    km = KMeans(n_clusters=best_k, n_init=10, random_state=RANDOM_STATE).fit(Xs)
    labels = km.labels_
    centroids = pd.DataFrame(scaler.inverse_transform(km.cluster_centers_), columns=FEATURES)

    # Índice de fatiga del centroide (en unidades estandarizadas) para nombrar grupos
    zc = pd.DataFrame(km.cluster_centers_, columns=FEATURES)
    fatigue_idx = zc["perclos"] + zc["bpm_drop_pct"] + zc["yawn_count"] - zc["ear_mean"] - zc["bpm_std"]
    order = fatigue_idx.sort_values().index.tolist()
    if best_k == 2:
        names = ["Alerta", "Somnolencia"]
    elif best_k == 3:
        names = ["Alerta", "Intermedio", "Somnolencia"]
    else:
        names = ["Alerta"] + [f"Intermedio {i}" for i in range(1, best_k - 1)] + ["Somnolencia"]
    name_of = {cid: names[rank] for rank, cid in enumerate(order)}

    wc = wc.assign(cluster=[name_of[l] for l in labels])

    # Validación externa: ¿coinciden los grupos con el estado de la fusión?
    ari = adjusted_rand_score(wc["estado_fusion"].fillna("?"), wc["cluster"])
    cruce = pd.crosstab(wc["cluster"], wc["estado_fusion"].fillna("sin estado"))

    pca = PCA(n_components=2, random_state=RANDOM_STATE)
    P = pca.fit_transform(Xs)
    pts = pd.DataFrame({"x": P[:, 0], "y": P[:, 1], "cluster": wc["cluster"],
                        "timestamp": wc["timestamp"]})
    if len(pts) > 800:
        pts = pts.sample(800, random_state=RANDOM_STATE)

    grupos = []
    for cid in order:
        nm = name_of[cid]
        grupos.append({
            "nombre": nm,
            "tamano": int((wc["cluster"] == nm).sum()),
            "porcentaje": 100 * (wc["cluster"] == nm).mean(),
            "centroide": centroids.loc[cid].to_dict(),
        })

    return {
        "disponible": True,
        "algoritmo": "K-Means (variables estandarizadas con z-score)",
        "k": best_k,
        "silueta_por_k": siluetas,
        "silueta": siluetas[best_k],
        "grupos": grupos,
        "ari_vs_fusion": ari,
        "cruce_cluster_vs_fusion": {
            "filas": cruce.index.tolist(), "columnas": cruce.columns.tolist(),
            "valores": cruce.values.tolist(),
        },
        "pca_varianza_explicada": pca.explained_variance_ratio_.tolist(),
        "puntos_pca": pts.to_dict(orient="records"),
    }


# ---------------------------------------------------------------------------
# 4c. Clasificación (supervisado): árbol de decisión + comparación
# ---------------------------------------------------------------------------

def _binary_target(wc: pd.DataFrame) -> tuple[pd.DataFrame, str, str, str | None]:
    """Variable objetivo binaria (fatiga sí/no): KSS real si hay suficientes
    autoreportes con ambas clases; si no, el estado de la fusión por reglas.
    Devuelve (datos, columna, descripción, advertencia)."""
    labeled_kss = wc.dropna(subset=["somnoliento_kss"])
    if len(labeled_kss) >= MIN_WINDOWS_CLASSIFY and labeled_kss["somnoliento_kss"].nunique() == 2:
        return labeled_kss, "somnoliento_kss", "autoreporte KSS (etiqueta real: KSS >= 7 = somnoliento)", None
    return wc, "fatiga_regla", "estado de la fusión por reglas (status = alerta)", (
        "No hay suficientes autoreportes KSS, así que la etiqueta sale de las mismas reglas "
        "de fusion.py. El modelo reaprende esas reglas: es útil para ver qué variables pesan "
        "y obtener reglas legibles, pero no es una validación independiente. Registren "
        "autoreportes KSS durante las pruebas (POST /autoreporte) para evaluar de verdad."
    )


def _check_classes(data: pd.DataFrame, target: str, fuente: str) -> dict | None:
    """None si hay datos suficientes para un modelo binario; si no, el motivo."""
    if len(data) < MIN_WINDOWS_CLASSIFY:
        return _insufficient(
            f"Se necesitan al menos {MIN_WINDOWS_CLASSIFY} ventanas etiquetadas (hay {len(data)}).",
            fuente_etiqueta=fuente,
        )
    counts = np.bincount(data[target].astype(int).values, minlength=2)
    if counts.min() < 4:
        return _insufficient(
            "Las dos clases (fatiga / no fatiga) necesitan al menos 4 ventanas cada una "
            f"(hay {int(counts[0])} sin fatiga y {int(counts[1])} con fatiga).",
            fuente_etiqueta=fuente,
        )
    return None


def _split(X, y, groups, stratify: bool = True):
    """Partición entrenamiento / prueba. Con >= 3 personas se separa POR
    PERSONA (nadie aparece en los dos conjuntos); si no, partición aleatoria
    (estratificada en clasificación), que es más optimista y así se informa.
    Devuelve (X_tr, X_te, y_tr, y_te, descripción)."""
    n_personas = len(set(groups))
    if n_personas >= MIN_PERSONAS_GRUPOS:
        for seed in range(20):   # busca una partición con ambas clases en prueba
            gss = GroupShuffleSplit(n_splits=1, test_size=0.3, random_state=RANDOM_STATE + seed)
            tr, te = next(gss.split(X, y, groups))
            if not stratify or (len(set(y[te])) == 2 and len(set(y[tr])) == 2):
                return (X[tr], X[te], y[tr], y[te],
                        f"por persona ({n_personas} personas; las de prueba no se usaron "
                        f"para entrenar: {', '.join(sorted(set(groups[te])))})")
    X_tr, X_te, y_tr, y_te = train_test_split(
        X, y, test_size=0.3, stratify=y if stratify else None, random_state=RANDOM_STATE
    )
    return (X_tr, X_te, y_tr, y_te,
            f"aleatoria{' estratificada' if stratify else ''} 70/30 ({n_personas} persona(s)). Ventanas "
            "seguidas de la misma persona se parecen mucho, así que estas métricas son optimistas; "
            f"con {MIN_PERSONAS_GRUPOS} o más personas se separa por persona.")


def _cv(groups, y=None, classification: bool = True):
    """Esquema de validación cruzada coherente con _split. Devuelve (cv, n_splits, nombre, usa_grupos)."""
    n_personas = len(set(groups))
    if n_personas >= MIN_PERSONAS_GRUPOS:
        n = int(min(5, n_personas))
        return GroupKFold(n_splits=n), n, "GroupKFold por persona", True
    if classification:
        n = int(min(5, np.bincount(y, minlength=2).min()))
        if n < 2:
            return None, n, "StratifiedKFold", False
        return StratifiedKFold(n_splits=n, shuffle=True, random_state=RANDOM_STATE), n, "StratifiedKFold", False
    n = int(min(5, len(groups) // 5))
    if n < 2:
        return None, n, "KFold", False
    return KFold(n_splits=n, shuffle=True, random_state=RANDOM_STATE), n, "KFold", False


def classify(w: pd.DataFrame) -> dict:
    wc = _complete(w)
    data, target, fuente, advertencia = _binary_target(wc)
    if (falta := _check_classes(data, target, fuente)) is not None:
        return falta

    y = data[target].astype(int).values
    counts = np.bincount(y, minlength=2)
    X = data[FEATURES].values
    groups = data["persona"].values
    X_tr, X_te, y_tr, y_te, tipo_particion = _split(X, y, groups)

    tree = DecisionTreeClassifier(max_depth=4, min_samples_leaf=3,
                                  class_weight="balanced", random_state=RANDOM_STATE)
    tree.fit(X_tr, y_tr)
    pred = tree.predict(X_te)

    metrics = {
        "exactitud": accuracy_score(y_te, pred),
        "precision": precision_score(y_te, pred, zero_division=0),
        "recall": recall_score(y_te, pred, zero_division=0),
        "f1": f1_score(y_te, pred, zero_division=0),
    }
    cm = confusion_matrix(y_te, pred, labels=[0, 1])

    base = DummyClassifier(strategy="most_frequent").fit(X_tr, y_tr)
    metrics["exactitud_clasificador_base"] = accuracy_score(y_te, base.predict(X_te))

    # Comparación de algoritmos con validación cruzada (F1)
    cv, n_splits, cv_nombre, use_groups = _cv(groups, y)
    comparacion = []
    if cv is not None:
        modelos = {
            "Árbol de decisión": DecisionTreeClassifier(max_depth=4, min_samples_leaf=3,
                                                        class_weight="balanced",
                                                        random_state=RANDOM_STATE),
            "Random Forest": RandomForestClassifier(n_estimators=150, max_depth=6,
                                                    class_weight="balanced",
                                                    random_state=RANDOM_STATE),
            "KNN (k=5)": make_pipeline(StandardScaler(),
                                       KNeighborsClassifier(n_neighbors=min(5, max(1, len(X) // 4)))),
            "Naive Bayes": make_pipeline(StandardScaler(), GaussianNB()),
            "Regresión logística": make_pipeline(StandardScaler(), LogisticRegression(
                class_weight="balanced", max_iter=2000)),
        }
        for nombre, m in modelos.items():
            scores = cross_val_score(m, X, y, cv=cv, scoring="f1",
                                     groups=groups if use_groups else None)
            comparacion.append({"modelo": nombre, "f1_medio": scores.mean(), "f1_desv": scores.std()})
        comparacion.sort(key=lambda r: r["f1_medio"], reverse=True)

    importancias = sorted(
        ({"variable": FEATURE_LABELS[f], "clave": f, "importancia": imp}
         for f, imp in zip(FEATURES, tree.feature_importances_)),
        key=lambda r: r["importancia"], reverse=True,
    )
    reglas = export_text(tree, feature_names=[FEATURE_LABELS[f] for f in FEATURES], decimals=3)
    reglas = reglas.replace("class: 1", "→ FATIGA").replace("class: 0", "→ sin fatiga")

    return {
        "disponible": True,
        "algoritmo": "Árbol de decisión (CART, profundidad máx. 4)",
        "fuente_etiqueta": fuente,
        "advertencia": advertencia,
        "particion": tipo_particion,
        "validacion_cruzada": cv_nombre,
        "n_entrenamiento": len(y_tr),
        "n_prueba": len(y_te),
        "clases": {"sin_fatiga": int(counts[0]), "fatiga": int(counts[1])},
        "metricas": metrics,
        "matriz_confusion": {"etiquetas": ["sin fatiga", "fatiga"], "valores": cm.tolist()},
        "importancia_variables": importancias,
        "reglas": reglas,
        "comparacion_modelos": comparacion,
        "folds_validacion_cruzada": n_splits,
    }


# ---------------------------------------------------------------------------
# 4d. Regresión: logística (objetivo binario) o lineal (objetivo continuo)
# ---------------------------------------------------------------------------

def _coefs(model, intercept_label: str) -> tuple[list[dict], str]:
    """Coeficientes estandarizados (por 1 desviación estándar de cada variable),
    ordenados por magnitud, y la ecuación legible."""
    coef = np.ravel(model.coef_)
    b0 = float(np.ravel(model.intercept_)[0]) if np.ndim(model.intercept_) else float(model.intercept_)
    filas = sorted(
        ({"variable": FEATURE_LABELS[f], "clave": f, "coeficiente": c,
          "efecto": "aumenta" if c > 0 else "reduce"} for f, c in zip(FEATURES, coef)),
        key=lambda r: abs(r["coeficiente"]), reverse=True,
    )
    terms = " ".join(f"{'+' if r['coeficiente'] >= 0 else '−'} {abs(r['coeficiente']):.3f}·z({r['variable']})"
                     for r in filas)
    return filas, f"{intercept_label} = {b0:.3f} {terms}"


def _logistic(data: pd.DataFrame, target: str, fuente: str, advertencia: str | None) -> dict:
    if (falta := _check_classes(data, target, fuente)) is not None:
        return falta
    X = data[FEATURES].values
    y = data[target].astype(int).values
    groups = data["persona"].values
    X_tr, X_te, y_tr, y_te, particion = _split(X, y, groups)

    model = make_pipeline(StandardScaler(), LogisticRegression(class_weight="balanced", max_iter=2000))
    model.fit(X_tr, y_tr)
    proba = model.predict_proba(X_te)[:, 1]
    pred = (proba >= 0.5).astype(int)
    two_classes = len(set(y_te)) == 2

    metricas = {
        "exactitud": accuracy_score(y_te, pred),
        "precision": precision_score(y_te, pred, zero_division=0),
        "recall": recall_score(y_te, pred, zero_division=0),
        "f1": f1_score(y_te, pred, zero_division=0),
        "auc": roc_auc_score(y_te, proba) if two_classes else None,
        "exactitud_clasificador_base": accuracy_score(
            y_te, DummyClassifier(strategy="most_frequent").fit(X_tr, y_tr).predict(X_te)),
    }
    roc = []
    if two_classes:
        fpr, tpr, _ = roc_curve(y_te, proba)
        idx = np.unique(np.linspace(0, len(fpr) - 1, min(len(fpr), 60)).astype(int))
        roc = [{"fpr": fpr[i], "tpr": tpr[i]} for i in idx]

    cv, n_splits, cv_nombre, use_groups = _cv(groups, y)
    cv_res = None
    if cv is not None:
        g = groups if use_groups else None
        f1s = cross_val_score(model, X, y, cv=cv, scoring="f1", groups=g)
        aucs = cross_val_score(model, X, y, cv=cv, scoring="roc_auc", groups=g)
        cv_res = {"esquema": cv_nombre, "particiones": n_splits,
                  "f1_medio": f1s.mean(), "f1_desv": f1s.std(),
                  "auc_medio": np.nanmean(aucs), "auc_desv": np.nanstd(aucs)}

    filas, ecuacion = _coefs(model[-1], "logit(p fatiga)")
    for r in filas:
        r["odds_ratio"] = math.exp(r["coeficiente"])   # multiplicador de las odds por +1 DE

    return {
        "disponible": True,
        "algoritmo": "Regresión logística (variables estandarizadas, clases balanceadas)",
        "objetivo": "probabilidad de que la ventana sea fatiga",
        "fuente_etiqueta": fuente,
        "advertencia": advertencia,
        "particion": particion,
        "n_entrenamiento": len(y_tr),
        "n_prueba": len(y_te),
        "clases": {"sin_fatiga": int((y == 0).sum()), "fatiga": int((y == 1).sum())},
        "metricas": metricas,
        "matriz_confusion": {"etiquetas": ["sin fatiga", "fatiga"],
                             "valores": confusion_matrix(y_te, pred, labels=[0, 1]).tolist()},
        "curva_roc": roc,
        "validacion_cruzada": cv_res,
        "coeficientes": filas,
        "intercepto": float(model[-1].intercept_[0]),
        "ecuacion": ecuacion,
    }


def _linear(data: pd.DataFrame) -> dict:
    X = data[FEATURES].values
    y = data["kss"].astype(float).values
    groups = data["persona"].values
    X_tr, X_te, y_tr, y_te, particion = _split(X, y, groups, stratify=False)

    model = make_pipeline(StandardScaler(), LinearRegression()).fit(X_tr, y_tr)
    pred = np.clip(model.predict(X_te), 1, 9)
    base = np.full_like(y_te, y_tr.mean())

    cv, n_splits, cv_nombre, use_groups = _cv(groups, classification=False)
    cv_res = None
    if cv is not None:
        r2s = cross_val_score(model, X, y, cv=cv, scoring="r2", groups=groups if use_groups else None)
        cv_res = {"esquema": cv_nombre, "particiones": n_splits, "r2_medio": r2s.mean(), "r2_desv": r2s.std()}

    filas, ecuacion = _coefs(model[-1], "KSS estimado")
    return {
        "disponible": True,
        "algoritmo": "Regresión lineal por mínimos cuadrados (variables estandarizadas)",
        "objetivo": "nivel de somnolencia KSS (1 = muy alerta … 9 = luchando contra el sueño)",
        "particion": particion,
        "n_entrenamiento": len(y_tr),
        "n_prueba": len(y_te),
        "metricas": {
            "r2": r2_score(y_te, pred) if len(y_te) > 1 else None,
            "mae": mean_absolute_error(y_te, pred),
            "rmse": math.sqrt(mean_squared_error(y_te, pred)),
            "mae_modelo_base": mean_absolute_error(y_te, base),
        },
        "validacion_cruzada": cv_res,
        "coeficientes": filas,
        "intercepto": float(model[-1].intercept_),
        "ecuacion": ecuacion,
        "real_vs_predicho": [{"real": r, "predicho": p} for r, p in list(zip(y_te, pred))[:300]],
    }


def regression(w: pd.DataFrame) -> dict:
    """Ajusta el tipo de regresión adecuado a la variable objetivo disponible:

    - Lineal, si hay suficientes ventanas con autoreporte KSS y este toma
      varios valores: la escala 1-9 es numérica y ordenada, y estimarla
      conserva más información que reducirla a sí/no.
    - Logística, si el objetivo es binario (fatiga sí/no). Una regresión lineal
      sobre 0/1 predice valores fuera de [0, 1] y sus residuos no cumplen los
      supuestos; la logística modela directamente la probabilidad.

    Se calculan las dos cuando es posible y `modelo_elegido` indica cuál
    conviene, con el motivo.
    """
    wc = _complete(w)
    data, target, fuente, advertencia = _binary_target(wc)
    logistica = _logistic(data, target, fuente, advertencia)

    kss = wc.dropna(subset=["kss"])
    niveles = int(kss["kss"].nunique()) if not kss.empty else 0
    if len(kss) >= MIN_WINDOWS_CLASSIFY and niveles >= MIN_KSS_NIVELES_LINEAL:
        lineal = _linear(kss)
    else:
        lineal = _insufficient(
            f"La regresión lineal necesita una variable objetivo continua: el KSS con al menos "
            f"{MIN_WINDOWS_CLASSIFY} ventanas etiquetadas y {MIN_KSS_NIVELES_LINEAL} niveles distintos "
            f"(hay {len(kss)} ventanas con KSS y {niveles} niveles). Registren autoreportes KSS."
        )

    r2 = lineal.get("metricas", {}).get("r2") if lineal["disponible"] else None
    if lineal["disponible"] and r2 is not None and r2 >= MIN_R2_LINEAL:
        elegido = "lineal"
        motivo = (f"Hay {len(kss)} ventanas con autoreporte KSS en {niveles} niveles distintos: la variable "
                  f"objetivo es numérica y ordenada, así que la regresión lineal estima el nivel de "
                  f"somnolencia sin perder información (R² en prueba = {r2:.2f}). La logística se muestra "
                  f"como complemento para el umbral KSS ≥ {KSS_SOMNOLIENTO}.")
    elif logistica["disponible"]:
        elegido = "logistica"
        motivo = ("La variable objetivo disponible es binaria (fatiga / sin fatiga, según "
                  f"{fuente}). La regresión logística modela la probabilidad de fatiga, acotada entre 0 y 1; "
                  "una regresión lineal sobre 0/1 daría valores imposibles y residuos que violan sus supuestos.")
        if lineal["disponible"]:
            motivo += (f" La regresión lineal sobre el KSS se calculó pero explica poco "
                       f"(R² = {r2 if r2 is not None else 0:.2f} < {MIN_R2_LINEAL}).")
    else:
        return _insufficient(
            "Todavía no hay datos suficientes para ninguna regresión. " + logistica.get("mensaje", ""),
            logistica=logistica, lineal=lineal,
        )
    return {"disponible": True, "modelo_elegido": elegido, "motivo": motivo,
            "logistica": logistica, "lineal": lineal}


# ---------------------------------------------------------------------------
# 4e. Detección de anomalías: Isolation Forest
# ---------------------------------------------------------------------------

def anomalies(w: pd.DataFrame, contamination: float = 0.05) -> dict:
    wc = _complete(w)
    if len(wc) < MIN_WINDOWS_CLUSTER:
        return _insufficient(
            f"Se necesitan al menos {MIN_WINDOWS_CLUSTER} ventanas completas (hay {len(wc)})."
        )
    Xs = StandardScaler().fit_transform(wc[FEATURES].values)
    iso = IsolationForest(contamination=contamination, random_state=RANDOM_STATE).fit(Xs)
    flag = iso.predict(Xs) == -1
    score = -iso.score_samples(Xs)   # mayor = más anómalo

    out = wc.loc[flag, ["timestamp", "estado_fusion"] + FEATURES].copy()
    out["puntaje_anomalia"] = score[flag]
    out = out.sort_values("puntaje_anomalia", ascending=False)

    # ¿Qué variable se aleja más de lo normal en cada anomalía?
    z = pd.DataFrame(Xs, columns=FEATURES).loc[flag]
    out["variable_mas_atipica"] = [FEATURE_LABELS[z.loc[i].abs().idxmax()] for i in out.index]

    return {
        "disponible": True,
        "algoritmo": f"Isolation Forest (contaminación esperada {int(contamination * 100)} %)",
        "ventanas_analizadas": len(wc),
        "anomalias_detectadas": int(flag.sum()),
        "anomalias": out.head(50).to_dict(orient="records"),
    }


# ---------------------------------------------------------------------------
# Reporte completo
# ---------------------------------------------------------------------------

def full_report(session_id: str, ventana_s: int = VENTANA_DEFECTO_S) -> dict:
    df = load_readings(session_id)
    if len(df) < MIN_READINGS:
        return _clean({
            "session_id": session_id,
            "disponible": False,
            "mensaje": (f"La sesión '{session_id}' tiene {len(df)} lecturas; se necesitan al menos "
                        f"{MIN_READINGS} para aplicar la analítica."),
        })

    clean, quality = preprocess(df)
    w = build_windows(clean, ventana_s)
    quality["sesiones"] = int(df["session_id"].nunique())
    quality["personas"] = int(df["session_id"].map(persona_de).nunique())
    quality["desde"] = df["timestamp"].min()
    quality["hasta"] = df["timestamp"].max()
    quality["autoreportes_kss"] = len(database.list_self_reports(
        session_id=None if session_id == TODAS else session_id))
    quality["ventanas_con_kss"] = int(w["kss"].notna().sum()) if "kss" in w else 0

    report = {
        "session_id": session_id,
        "disponible": True,
        "metodologia": "CRISP-DM",
        "parametros": {"ventana_s": int(ventana_s), "variables": FEATURES,
                       "etiquetas_variables": FEATURE_LABELS,
                       "criterios_exito": {"recall": CRITERIO_RECALL, "precision": CRITERIO_PRECISION}},
        "calidad_datos": quality,
        "descriptiva": describe(w, session_id),
        "clustering": cluster(w),
        "clasificacion": classify(w),
        "regresion": regression(w),
        "anomalias": anomalies(w),
    }
    return _clean(report)


# ---------------------------------------------------------------------------
# Panel de todos los usuarios (administrador / supervisor)
# ---------------------------------------------------------------------------

def users_overview() -> dict:
    """Una fila por sesión monitoreada (y por conductor aunque aún no tenga
    datos), con sus indicadores principales para comparar personas."""
    users = database.list_users()
    by_session = {u["session_id"]: u for u in users if u.get("session_id")}
    df = load_readings(TODAS)
    events = pd.DataFrame(database.list_events(session_id=None, limit=1_000_000))
    reports = pd.DataFrame(database.list_self_reports(session_id=None))

    filas = []
    sesiones = sorted(set(df["session_id"]) if not df.empty else set())
    for sid in sesiones:
        g = df[df["session_id"] == sid].sort_values("timestamp")
        frames = g[(g["source"] == "frame") & (g["face_detected"].fillna(0) == 1)]
        pulses = g[(g["source"] == "pulso") & g["bpm"].between(*PLAUSIBLE_BPM)]
        gaps = g["timestamp"].diff().dt.total_seconds()
        horas = float(gaps[gaps <= GAP_FIN_SESION_S].sum()) / 3600
        ev = events[events["session_id"] == sid] if not events.empty else events
        fatiga = ev[ev["sensor_warning"].astype(int) == 0] if not ev.empty else ev
        kss = reports[reports["session_id"] == sid]["kss"] if not reports.empty else pd.Series(dtype=float)
        estados = g["fusion_status"].value_counts(normalize=True)
        por_hora = len(fatiga) / horas if horas > 0 else 0.0
        nivel = "alto" if por_hora >= 2 or (not fatiga.empty and (fatiga["risk_level"] == "alto").any()) \
            else ("medio" if len(fatiga) > 0 or estados.get("vigilancia", 0) > 0.2 else "bajo")
        u = by_session.get(sid)
        filas.append({
            "session_id": sid,
            "persona": persona_de(sid),
            "usuario": u["username"] if u else None,
            "nombre": (u.get("full_name") or u["username"]) if u else None,
            "rol": u["role"] if u else None,
            "activo": bool(u["active"]) if u else None,
            "lecturas": int(len(g)),
            "desde": g["timestamp"].min(),
            "hasta": g["timestamp"].max(),
            "horas_monitoreo": horas,
            "bpm_medio": pulses["bpm"].mean() if not pulses.empty else None,
            "basal_bpm": g["baseline_bpm"].dropna().iloc[-1] if g["baseline_bpm"].notna().any() else None,
            "ear_medio": frames["ear"].mean() if not frames.empty else None,
            "perclos": frames["eyes_closed"].mean() * 100 if not frames.empty else None,
            "pct_alerta": 100 * estados.get("alerta", 0),
            "pct_vigilancia": 100 * estados.get("vigilancia", 0),
            "episodios_alto": int((fatiga["risk_level"] == "alto").sum()) if not fatiga.empty else 0,
            "episodios_medio": int((fatiga["risk_level"] == "medio").sum()) if not fatiga.empty else 0,
            "advertencias_sensor": int(len(ev) - len(fatiga)) if not ev.empty else 0,
            "episodios_por_hora": por_hora,
            "kss_reportes": int(len(kss)),
            "kss_medio": kss.mean() if len(kss) else None,
            "nivel_riesgo": nivel,
        })

    # Conductores registrados que todavía no enviaron datos
    for u in users:
        if u["role"] == "conductor" and u.get("session_id") and u["session_id"] not in sesiones:
            filas.append({
                "session_id": u["session_id"], "persona": persona_de(u["session_id"]),
                "usuario": u["username"], "nombre": u.get("full_name") or u["username"],
                "rol": u["role"], "activo": bool(u["active"]), "lecturas": 0, "nivel_riesgo": "sin_datos",
            })

    orden = {"alto": 0, "medio": 1, "bajo": 2, "sin_datos": 3}
    filas.sort(key=lambda f: (orden[f["nivel_riesgo"]], -(f.get("episodios_por_hora") or 0)))
    con_datos = [f for f in filas if f["lecturas"]]
    return _clean({
        "totales": {
            "usuarios": len(users),
            "conductores": sum(1 for u in users if u["role"] == "conductor"),
            "sesiones": len(sesiones),
            "lecturas": int(len(df)),
            "episodios_fatiga": sum(f["episodios_alto"] + f["episodios_medio"] for f in con_datos),
            "kss_reportes": int(len(reports)),
            "horas_monitoreo": sum(f["horas_monitoreo"] for f in con_datos),
        },
        "por_nivel": {k: sum(1 for f in filas if f["nivel_riesgo"] == k) for k in orden},
        "usuarios": filas,
    })


def windows_dataframe(session_id: str, ventana_s: int = VENTANA_DEFECTO_S) -> pd.DataFrame:
    """Dataset transformado (una fila por ventana) para exportar a CSV."""
    df = load_readings(session_id)
    if df.empty:
        return pd.DataFrame()
    clean, _ = preprocess(df)
    w = build_windows(clean, ventana_s)
    num = w.select_dtypes("number").columns
    w[num] = w[num].round(4)
    return w