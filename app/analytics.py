"""
Analítica / minería de datos para SIDFAM.

Implementa el proceso KDD (y las fases 2-5 de CRISP-DM) sobre la tabla
`sensor_readings`, que guarda CADA lectura recibida de los ESP32:

  1. Selección        -> lecturas de una sesión (load_readings).
  2. Preprocesamiento -> duplicados, nulos, lecturas implausibles,
                         inconsistencias y valores atípicos (preprocess).
  3. Transformación   -> integración de las dos fuentes (visión + pulso)
                         en ventanas de tiempo fijas (1 minuto por defecto,
                         como indica la metodología del documento) y
                         extracción de características (build_windows).
  4. Minería          -> descriptiva (describe), clustering K-Means
                         (cluster), clasificación supervisada con árbol de
                         decisión + comparación de modelos (classify) y
                         detección de anomalías con Isolation Forest
                         (anomalies).
  5. Evaluación       -> silueta, matriz de confusión, precisión, recall,
                         F1, validación cruzada y comparación contra un
                         clasificador base.

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
from sklearn.metrics import (
    accuracy_score, adjusted_rand_score, confusion_matrix, f1_score,
    precision_score, recall_score, silhouette_score,
)
from sklearn.model_selection import (
    GroupKFold, GroupShuffleSplit, StratifiedKFold, cross_val_score, train_test_split,
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

def classify(w: pd.DataFrame) -> dict:
    wc = _complete(w)

    labeled_kss = wc.dropna(subset=["somnoliento_kss"])
    if len(labeled_kss) >= MIN_WINDOWS_CLASSIFY and labeled_kss["somnoliento_kss"].nunique() == 2:
        data, target = labeled_kss, "somnoliento_kss"
        fuente = "autoreporte KSS (etiqueta real: KSS >= 7 = somnoliento)"
        advertencia = None
    else:
        data, target = wc, "fatiga_regla"
        fuente = "estado de la fusión por reglas (status = alerta)"
        advertencia = (
            "No hay suficientes autoreportes KSS, así que la etiqueta sale de las mismas reglas "
            "de fusion.py. El árbol reaprende esas reglas: es útil para ver qué variables pesan "
            "y obtener reglas legibles, pero no es una validación independiente. Registren "
            "autoreportes KSS durante las pruebas (POST /autoreporte) para evaluar de verdad."
        )

    if len(data) < MIN_WINDOWS_CLASSIFY:
        return _insufficient(
            f"Se necesitan al menos {MIN_WINDOWS_CLASSIFY} ventanas etiquetadas (hay {len(data)}).",
            fuente_etiqueta=fuente,
        )
    y = data[target].astype(int).values
    counts = np.bincount(y, minlength=2)
    if counts.min() < 4:
        return _insufficient(
            "Las dos clases (fatiga / no fatiga) necesitan al menos 4 ventanas cada una "
            f"(hay {int(counts[0])} sin fatiga y {int(counts[1])} con fatiga).",
            fuente_etiqueta=fuente,
        )

    X = data[FEATURES].values
    groups = data["persona"].values
    n_personas = len(set(groups))

    # Partición entrenamiento / prueba. Con >= 3 personas se separa POR
    # PERSONA (nadie aparece en los dos conjuntos); si no, partición
    # aleatoria estratificada, que es más optimista y así se informa.
    particion = None
    if n_personas >= MIN_PERSONAS_GRUPOS:
        for seed in range(20):   # busca una partición con ambas clases en prueba
            gss = GroupShuffleSplit(n_splits=1, test_size=0.3, random_state=RANDOM_STATE + seed)
            tr, te = next(gss.split(X, y, groups))
            if len(set(y[te])) == 2 and len(set(y[tr])) == 2:
                particion = (tr, te)
                break
    if particion is not None:
        tr, te = particion
        X_tr, X_te, y_tr, y_te = X[tr], X[te], y[tr], y[te]
        tipo_particion = (f"por persona ({n_personas} personas; las de prueba no se usaron "
                          f"para entrenar: {', '.join(sorted(set(groups[te])))})")
    else:
        X_tr, X_te, y_tr, y_te = train_test_split(
            X, y, test_size=0.3, stratify=y, random_state=RANDOM_STATE
        )
        tipo_particion = (f"aleatoria estratificada 70/30 ({n_personas} persona(s)). Ventanas "
                          "seguidas de la misma persona se parecen mucho, así que estas métricas "
                          f"son optimistas; con {MIN_PERSONAS_GRUPOS} o más personas se separa por persona.")

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

    # Comparación de algoritmos con validación cruzada estratificada (F1)
    use_groups = n_personas >= MIN_PERSONAS_GRUPOS
    n_splits = int(min(5, n_personas)) if use_groups else int(min(5, counts.min()))
    comparacion = []
    if n_splits >= 2:
        cv = GroupKFold(n_splits=n_splits) if use_groups else \
            StratifiedKFold(n_splits=n_splits, shuffle=True, random_state=RANDOM_STATE)
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
        "validacion_cruzada": "GroupKFold por persona" if use_groups else "StratifiedKFold",
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
# 4d. Detección de anomalías: Isolation Forest
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

    return _clean({
        "session_id": session_id,
        "disponible": True,
        "parametros": {"ventana_s": int(ventana_s), "variables": FEATURES,
                       "etiquetas_variables": FEATURE_LABELS},
        "calidad_datos": quality,
        "descriptiva": describe(w, session_id),
        "clustering": cluster(w),
        "clasificacion": classify(w),
        "anomalias": anomalies(w),
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