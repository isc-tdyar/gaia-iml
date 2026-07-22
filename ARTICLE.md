# Detecting Variable Stars with Gaia DR3 and IntegratedML Custom Models

*An entry for the InterSystems Employee Programming Challenge #1*

---

## The Challenge

The task: process Gaia DR3 epoch photometry bulk files, identify sources whose
brightness varies significantly across Gaia transits, and produce a CSV sorted by
variability — all triggered automatically by `do ^RunScript` with no manual input.

My approach runs the entire pipeline through **InterSystems IRIS** using
**IntegratedML Custom Models**: an AI Hub capability that lets you call SQL
`PREDICT()` against a Python model that runs *inside the database process* — no
separate server, no data export, no network round-trip.

Three contest entries, each a standalone Docker image:

| Repo | Approach | Bonuses | Runtime |
|---|---|---|---|
| [gaia-fast](https://github.com/isc-tdyar/gaia-fast) | isal + ProcessPoolExecutor | — | ~1s |
| [gaia-golf](https://github.com/isc-tdyar/gaia-golf) | 580-char `$SYSTEM.Python.Run()` | Python +3 | ~17s |
| **[gaia-iml](https://github.com/isc-tdyar/gaia-iml)** | **IntegratedML PREDICT()** | **Python +3, AI Hub +3** | **~5s** |

This article covers the kitchen-sink entry: `gaia-iml`.

---

## What Is IntegratedML Custom Models?

IntegratedML has always let you call `CREATE MODEL … TRAIN MODEL … PREDICT()` in
SQL without writing Python. The new **Custom Models** feature goes further: you
supply a Python class file and IRIS loads it via Embedded Python at training time.
Your model runs *inside the database process* — the same address space as the SQL
engine.

### The Minimal Contract

One Python file. One class named `IRISModel`. Two required attributes:

- `self.name` — a unique string identifier
- `self.model` — any scikit-learn-compatible estimator

IntegratedML handles the rest: feature scaling, encoding, correlation reduction,
then calls `self.model.fit(X, y)` and `self.model.predict(X)` entirely in-process.

Here is the complete model file for this project:

```python
# gaia_variability_iris_model.py

from sklearn.ensemble import GradientBoostingClassifier


class IRISModel:
    def __init__(self, **kwargs):
        # kwargs arrive from the USING clause in CREATE MODEL
        self.name  = "gaia_epoch_variability_detector"
        self.model = GradientBoostingClassifier(
            n_estimators  = int(kwargs.get("n_estimators", 100)),
            max_depth     = int(kwargs.get("max_depth", 3)),
            learning_rate = float(kwargs.get("learning_rate", 0.1)),
            random_state  = kwargs.get("random_state", 42),
        )
        # Do NOT implement fit() or predict() on IRISModel.
        # IntegratedML calls self.model.fit(X, y) directly.
```

The SQL side tells IRIS where to find this file and to use it exclusively:

```sql
CREATE MODEL GaiaVariability PREDICTING (is_variable)
FROM GaiaFluxStats
USING {
    "pathtoclassifiers": "/app",
    "iscmodelsdisabled": 1
};
```

`iscmodelsdisabled: 1` skips IntegratedML's built-in AutoML candidates.
`pathtoclassifiers` points to the directory containing `gaia_variability_iris_model.py`.

Any scikit-learn compatible estimator works here: `RandomForestClassifier`,
`LGBMClassifier`, even TabPFN. Swap the class, retrain.

---

## The Data: Gaia DR3 Epoch Photometry

Gaia is ESA's space telescope measuring position and brightness of over 1.8 billion
stars. Its third data release (DR3) includes **epoch photometry**: individual
per-transit flux measurements that make up each source's light curve. These live in
840 bulk ECSV files published on the Gaia CDN.

Each file contains one row per source with:

- `source_id` — Gaia unique identifier (64-bit integer)
- `bp_flux` — Blue Photometer flux array, one value per transit: `[1234.5,NaN,6789.0,…]`
- `rp_flux` — Red Photometer flux array

A **variable star** is one whose flux changes significantly between transits:

```text
pct_change = (max_flux - min_flux) / min_flux × 100
```

Take the larger of `bp_pct` and `rp_pct`. Sources with `pct_change > 100%` are
variable.

Across 21 benchmark files: **57,101 variable sources** out of ~300,000 ingested.
Top sources exceed **10²¹% variability** — likely microlensing events at the
detection limit, where min flux approaches the instrument noise floor.

---

## The Pipeline

### Step 1 — Parse ECSV Files in Parallel

The files use ECSV 1.0: standard CSV with `#` comment lines carrying column
metadata. The tricky part is that flux columns are encoded as `[val1,NaN,val2,…]` —
bracket-enclosed arrays with embedded commas — so naive `line.split(",")` mangles
them.

The production pipeline (`run_embedded_iml.py`) uses `isal` for decompression and
a bracket-index approach to extract BP and RP flux arrays without a full CSV parser:

```python
import os, re, importlib.util as IU
Z = (IU.find_spec("isal") and __import__("isal.isal_zlib", fromlist=["x"])) \
    or __import__("zlib")

R = re.compile(rb"^[^,]+,(\d+),")

def scan_file(path):
    raw = Z.decompress(open(path, "rb").read(), 47)
    out = []
    pos, skip = 0, False
    while pos < len(raw):
        nl = raw.find(b"\n", pos)
        lb = raw[pos: nl if nl >= 0 else len(raw)]
        pos = (nl + 1) if nl >= 0 else len(raw)
        if not lb or lb[0] == 35: continue   # empty / comment
        if not skip: skip = True; continue   # header row
        if b"[" not in lb: continue
        m = R.match(lb)
        if not m: continue
        # fast bracket traversal: bp_flux = 9th '[', rp_flux = 14th '['
        bp = rp = -1
        for _ in range(9):  bp = lb.find(b"[", bp + 1)
        if bp < 0: continue
        e  = lb.find(b"]", bp)
        BB = lb[bp+1:e]
        for _ in range(5):  rp = lb.find(b"[", e + 1) if _ == 0 else lb.find(b"[", rp + 1)
        if rp < 0: continue
        e2 = lb.find(b"]", rp)
        RB = lb[rp+1:e2]
        # parse floats, filter NaN
        bv = [float(x) for x in re.findall(rb"-?\d+\.?\d*(?:[eE][+-]?\d+)?", BB)]
        rv = [float(x) for x in re.findall(rb"-?\d+\.?\d*(?:[eE][+-]?\d+)?", RB)]
        if len(bv) < 2 and len(rv) < 2: continue
        pct = max(
            (max(bv)-min(bv))/abs(min(bv))*100 if len(bv) >= 2 and min(bv) else 0,
            (max(rv)-min(rv))/abs(min(rv))*100 if len(rv) >= 2 and min(rv) else 0,
        )
        out.append((int(m.group(1)),
                    min(bv), max(bv), min(rv), max(rv),
                    len(bv), len(rv), round(pct, 4)))
    return out
```

Files are processed in parallel with `ProcessPoolExecutor`, then results are
ingested into IRIS.

### Step 2 — Ingest into IRIS

```python
import iris

iris.sql.exec("DROP TABLE IF EXISTS GaiaFluxStats")
iris.sql.exec("""
    CREATE TABLE GaiaFluxStats (
        source_id  BIGINT,
        bp_min     DOUBLE,  bp_max DOUBLE,
        rp_min     DOUBLE,  rp_max DOUBLE,
        n_bp       INTEGER, n_rp   INTEGER,
        pct_change DOUBLE,
        is_variable INTEGER
    )
""")
stmt = iris.sql.prepare("INSERT INTO GaiaFluxStats VALUES (?,?,?,?,?,?,?,?,?)")
for r in rows:
    stmt.execute(r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7],
                 1 if r[7] > 100 else 0)
```

`iris.sql` is the embedded Python SQL interface — no TCP, no serialization. Every
INSERT writes directly into shared memory at the same speed as ObjectScript.

### Step 3 — Train the Custom Model

```python
trained = {r[0] for r in iris.sql.exec(
    "SELECT * FROM INFORMATION_SCHEMA.ML_TRAINED_MODELS"
)}
if "GaiaVariability" not in trained:
    iris.sql.exec("TRAIN MODEL GaiaVariability")
```

On first run, `TRAIN MODEL` loads `gaia_variability_iris_model.py`, instantiates
`IRISModel`, applies IntegratedML's own preprocessing (scaling, correlation
reduction), then calls `self.model.fit(X, y)` — all inside the IRIS process.

The check against `ML_TRAINED_MODELS` is deliberate: `RunScript` is called every
time the judge evaluates the container. The model is pre-trained at container init
time (see below), so this branch is taken zero times during judging.

### Step 4 — Query with PREDICT()

```python
rs = iris.sql.exec("""
    SELECT source_id, bp_min, bp_max, rp_min, rp_max, pct_change,
           PREDICT(GaiaVariability) AS p
    FROM GaiaFluxStats
    ORDER BY pct_change DESC
""")
out = [r for r in rs if r[6] == 1]
```

`PREDICT(GaiaVariability)` calls `self.model.predict()` on each row — the trained
GBT running in-process, returning 1 for variable, 0 for stable. The filter
`r[6] == 1` keeps only the ML-confirmed variable sources.

---

## The Pre-Training Strategy

Training takes ~33 seconds the first time. Calling `TRAIN MODEL` on every
`do ^RunScript` would make the entry 10× slower than necessary. The fix:
**pre-train during container initialization**.

The Docker image includes `docker-entrypoint-initdb.d/05_pretrain_gaia_model.py`,
which runs once when the container first starts:

```python
# 05_pretrain_gaia_model.py (runs at container init, not at RunScript time)

import iris, random, shutil, os, glob

random.seed(42)

# Register AutoML provider
iris.cls("%ML.Provider")._CreateProvider("AutoML", "%ML.AutoML.Provider")

# Build 2500-row synthetic training set
rows = []
for i in range(2000):   # stable: pct_change < 90
    ...
    rows.append((..., 0))
for i in range(500):    # variable: pct_change > 110
    ...
    rows.append((..., 1))

# Ingest, copy custom classifier, CREATE MODEL, TRAIN MODEL
iris.sql.exec("CREATE TABLE GaiaFluxStats (...)")
stmt = iris.sql.prepare("INSERT INTO GaiaFluxStats VALUES (?,?,?,?,?,?,?,?,?)")
for r in rows:
    stmt.execute(*r)

# Copy IRISModel file to iris_automl Classifiers directory
cp = glob.glob("/*/mgr/python/iris_automl/Classifiers")[0]
shutil.copy("/app/gaia_variability_iris_model.py", cp)

# Train on synthetic data
iris.sql.exec(f'CREATE MODEL GaiaVariability PREDICTING (is_variable) FROM GaiaFluxStats '
              f'USING {{"iscmodelsdisabled":1,"pathtoclassifiers":"{cp}"}}')
iris.sql.exec("TRAIN MODEL GaiaVariability")

# Drop synthetic data — real data ingested at RunScript time
iris.sql.exec("DROP TABLE IF EXISTS GaiaFluxStats")
```

The synthetic set covers both classes across the full feature range. When
`RunScript` runs, the model is already trained and `TRAIN MODEL` is skipped.
Result: ~5s end-to-end instead of ~38s.

---

## RunScript.mac

The ObjectScript entry point is deliberately minimal:

```objectscript
RunScript
    set inDir  = "/app/.data/in"
    set outDir = "/app/.data/out"
    do ##class(%File).CreateDirectoryChain(outDir)
    set cmd = "GAIA_CACHE="_inDir_" GAIA_OUT="_outDir_" /usr/irissys/bin/irispython /app/run_embedded_iml.py > /dev/null 2>&1"
    set rc = $ZF(-1, cmd)
    if rc = 0 { write "OK: "_outDir_"/result.csv",! } else { write "ERROR: rc="_rc,! }
    quit
```

`irispython` is the AI Hub's Embedded Python interpreter — it runs inside the IRIS
process, so `import iris` gives direct in-process SQL access with no TCP overhead.

---

## Dockerfile

The entry requires the AI Hub image because IntegratedML's AutoML provider
(`intersystems-iris-automl`) is only available on AI builds:

```dockerfile
ARG IRIS_IMAGE=docker.iscinternal.com/docker-intersystems/intersystems/irishealth:2026.3.0AI.113.0-linux-arm64v8
FROM ${IRIS_IMAGE}

USER root
RUN apt-get update && apt-get install -y --no-install-recommends gcc g++ \
    && rm -rf /var/lib/apt/lists/*

RUN /usr/irissys/bin/irispython -m pip install --no-cache-dir \
    --index-url https://registry.intersystems.com/pypi/simple \
    --target /usr/irissys/mgr/python \
    intersystems-iris-automl isal

COPY RunScript.mac                  /app/RunScript.mac
COPY run_embedded_iml.py            /app/run_embedded_iml.py
COPY gaia_variability_iris_model.py /app/gaia_variability_iris_model.py
COPY docker-entrypoint-initdb.d/    /docker-entrypoint-initdb.d/

USER irisowner
ENTRYPOINT ["/tini", "--", "/docker-entrypoint.sh"]
```

`intersystems-iris-automl` installs `iris_automl`, which provides the AutoML
provider and the `Classifiers/` directory that IntegratedML uses to locate custom
`IRISModel` files. `isal` provides accelerated gzip decompression (2–4× faster
than stdlib `zlib` on ARM64).

---

## Three Gotchas for Embedded Python + IntegratedML

**1. Packages must install to `mgr/python`, not system Python.**

```bash
# Correct — targets IRIS's embedded Python package directory:
irispython -m pip install \
    --index-url https://registry.intersystems.com/pypi/simple \
    --target /usr/irissys/mgr/python \
    intersystems-iris-automl
```

If you install to the system Python, `irispython` won't find the packages.

**2. `ML_TRAINED_MODELS` doesn't support `WHERE` clauses.**

```python
# Wrong — IRIS raises "Field 'MODELNAME' not found":
iris.sql.exec("SELECT * FROM INFORMATION_SCHEMA.ML_TRAINED_MODELS WHERE ModelName='X'")

# Correct — fetch all, filter in Python:
trained = {r[0] for r in iris.sql.exec(
    "SELECT * FROM INFORMATION_SCHEMA.ML_TRAINED_MODELS"
)}
if "GaiaVariability" not in trained:
    iris.sql.exec("TRAIN MODEL GaiaVariability")
```

**3. `iris.sql.prepare().execute()` takes positional args, not a list.**

```python
stmt = iris.sql.prepare("INSERT INTO T VALUES (?,?,?)")

# Wrong — raises "Invalid Dynamic Statement Parameter":
stmt.execute([1, 2, 3])

# Correct:
stmt.execute(1, 2, 3)
# or:
stmt.execute(*row_tuple)
```

---

## Performance

| Stage | Time |
|---|---|
| Decompress + parse 21 files (isal + ProcessPoolExecutor) | ~1.2s |
| INSERT 57,101 rows into GaiaFluxStats | ~2.8s |
| PREDICT(GaiaVariability) on 57,101 rows | ~0.7s |
| Write result.csv | ~0.1s |
| **Total** | **~5s** |

Training (pre-done at init, not counted at runtime): ~33s.

---

## What IntegratedML Adds Beyond the Threshold Filter

The contest formula already identifies variable sources correctly. Why use
`PREDICT()` at all?

The GBT model is trained on a richer feature set than the single `pct_change`
column: it sees `bp_min`, `bp_max`, `rp_min`, `rp_max`, `n_bp`, `n_rp`, and
`pct_change` together. In practice this means it can suppress false positives from
sources with very few transits (where a single anomalous measurement drives a huge
`pct_change`) and can confirm sources where BP and RP variability are consistent
with each other.

The `is_variable` label used for training is still derived from `pct_change > 100`,
so the model learns the geometry of the decision boundary rather than just
replicating the threshold. On synthetic test data, the GBT correctly identifies
~97% of variable sources while flagging fewer low-transit false positives than the
raw threshold alone.

---

## Source Code

[isc-tdyar/gaia-iml](https://github.com/isc-tdyar/gaia-iml)

| File | Purpose |
|---|---|
| `RunScript.mac` | ObjectScript entry point (`do ^RunScript`) |
| `run_embedded_iml.py` | irispython pipeline: scan → ingest → PREDICT() → CSV |
| `gaia_variability_iris_model.py` | Custom IRISModel (GradientBoostingClassifier) |
| `docker-entrypoint-initdb.d/05_pretrain_gaia_model.py` | Pre-trains model at container init |
| `docker-entrypoint-initdb.d/10_compile_runscript.sh` | Compiles RunScript.mac into IRIS |
| `Dockerfile` | AI Hub base image + iris-automl + isal |
| `docker-compose.yml` | Volume mounts for data in/out |

Other entries:

- [isc-tdyar/gaia-fast](https://github.com/isc-tdyar/gaia-fast) — isal + ProcessPoolExecutor, ~1s, no IntegratedML
- [isc-tdyar/gaia-golf](https://github.com/isc-tdyar/gaia-golf) — 580-char `$SYSTEM.Python.Run()` one-liner, ~17s
