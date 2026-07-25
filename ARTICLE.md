# Detecting Variable Stars with Gaia DR3 and IntegratedML Custom Models

_An entry for the InterSystems Employee Programming Challenge #1_

---

## The Challenge

Process Gaia DR3 epoch photometry bulk files, identify sources whose brightness
varies significantly across Gaia transits, and produce a CSV sorted by
variability. All of it has to run from `do ^RunScript` with no manual input.

My approach runs the entire pipeline through **InterSystems IRIS** using
**IntegratedML Custom Models**, an AI Hub capability that lets you call SQL
`PREDICT()` against a Python model running _inside the database process_. No
separate server, no data export, no network round-trip.

Three contest entries, each a standalone Docker image:

| Repo                                                  | Approach                        | Bonuses                  | Runtime  |
| ----------------------------------------------------- | ------------------------------- | ------------------------ | -------- |
| [gaia-fast](https://github.com/isc-tdyar/gaia-fast)   | isal + ProcessPoolExecutor      | none                     | ~1s      |
| [gaia-golf](https://github.com/isc-tdyar/gaia-golf)   | 580-char `$SYSTEM.Python.Run()` | Python +3                | ~17s     |
| **[gaia-iml](https://github.com/isc-tdyar/gaia-iml)** | **IntegratedML PREDICT()**      | **Python +3, AI Hub +3** | **~11s** |

This article covers the kitchen-sink entry: `gaia-iml`.

---

## What Is IntegratedML Custom Models?

IntegratedML has always let you call `CREATE MODEL … TRAIN MODEL … PREDICT()` in
SQL without writing Python. The new **Custom Models** feature goes further. You
supply a Python class file, IRIS loads it via Embedded Python at training time,
and your model runs in the same address space as the SQL engine.

### The Minimal Contract

One Python file. One class named `IRISModel`. Two required attributes:

- `self.name`: a unique string identifier
- `self.model`: any scikit-learn-compatible estimator

IntegratedML handles feature scaling, encoding and correlation reduction, then
calls `self.model.fit(X, y)` and `self.model.predict(X)` in-process.

The complete model file for this project:

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
WITH (bp_min NUMERIC, bp_max NUMERIC, rp_min NUMERIC, rp_max NUMERIC,
      n_bp NUMERIC, n_rp NUMERIC)
FROM GaiaFluxStats
USING {
    "iscmodelsdisabled": 1,
    "pathtoclassifiers": "<automl_root>/Classifiers/gaia_variability"
};
```

`iscmodelsdisabled: 1` skips IntegratedML's built-in AutoML candidates.
`pathtoclassifiers` points at the directory holding
`gaia_variability_iris_model.py`. Resolve that directory by importing the
package (`os.path.dirname(iris_automl.__file__)`) rather than globbing for it:
the install prefix differs across IRIS images, and a missed glob yields a
`pathtoclassifiers` of `"None"` that fails deep inside `TRAIN MODEL`.

Give each model its own subdirectory. `load_models()` imports every `.py` in the
directory it is handed, so two models sharing a directory means AutoML tries
each one on the other's target.

The explicit `WITH` list matters here. `is_variable` is defined as `pct_change >
100`, so leaving `pct_change` in the feature set leaks the target: the first
version predicted variable for all 74,998 real rows, including the 17,899 with
`pct_change <= 100`.

Any scikit-learn compatible estimator works: `RandomForestClassifier`,
`LGBMClassifier`, even TabPFN. Swap the class, retrain.

---

## The Data: Gaia DR3 Epoch Photometry

Gaia is ESA's space telescope measuring position and brightness of over 1.8
billion stars. Its third data release (DR3) includes **epoch photometry**: the
individual per-transit flux measurements that make up each source's light curve.
These live in 840 bulk ECSV files published on the Gaia CDN.

Each file contains one row per source with:

- `source_id`: Gaia unique identifier (64-bit integer)
- `bp_flux`: Blue Photometer flux array, one value per transit: `[1234.5,NaN,6789.0,…]`
- `rp_flux`: Red Photometer flux array

A **variable star** is one whose flux changes significantly between transits:

```text
pct_change = (max_flux - min_flux) / min_flux × 100
```

Take the larger of `bp_pct` and `rp_pct`. Sources with `pct_change > 100%` are
variable.

Across the 20 benchmark files: **57,099 variable sources**. 74,998 sources carry
ESA's per-epoch quality flags, which feed the second model below. Top sources
exceed **10²¹% variability**, likely microlensing events at the detection limit,
where min flux approaches the instrument noise floor.

---

## The Pipeline

### Step 1: Parse ECSV Files in Parallel

The files use ECSV 1.0: standard CSV with `#` comment lines carrying column
metadata. The tricky part is that flux columns are encoded as
`[val1,NaN,val2,…]`, bracket-enclosed arrays with embedded commas, so a naive
`line.split(",")` mangles them.

The production pipeline (`run_embedded_iml.py`) uses `isal` for decompression
and a bracket-index approach to extract BP and RP flux arrays without a full CSV
parser:

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

### Step 2: Ingest into IRIS

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

`iris.sql` is the embedded Python SQL interface. No TCP, no serialization: every
INSERT writes directly into shared memory at the same speed as ObjectScript.

### Step 3: Train the Custom Model

```python
trained = {r[0] for r in iris.sql.exec(
    "SELECT * FROM INFORMATION_SCHEMA.ML_TRAINED_MODELS"
)}
if "GaiaVariability" not in trained:
    iris.sql.exec("TRAIN MODEL GaiaVariability")
```

On first run, `TRAIN MODEL` loads `gaia_variability_iris_model.py`, instantiates
`IRISModel`, applies IntegratedML's own preprocessing (scaling, correlation
reduction), then calls `self.model.fit(X, y)`, all inside the IRIS process.

The check against `ML_TRAINED_MODELS` matters. `RunScript` is called every
time the judge evaluates the container, and the model is pre-trained at
container init time (see below), so this branch is taken zero times during
judging.

### Step 4: Query with PREDICT()

```python
rs = iris.sql.exec("""
    SELECT source_id, bp_min, bp_max, rp_min, rp_max, pct_change,
           PREDICT(GaiaVariability) AS p
    FROM GaiaFluxStats
    WHERE pct_change > 100
    ORDER BY pct_change DESC
""")
out = list(rs)
agree = sum(1 for r in out if int(r[6]) == 1)
```

`PREDICT(GaiaVariability)` calls `self.model.predict()` on each row: the trained
GBT running in-process, returning 1 for variable, 0 for stable. It runs
alongside the `WHERE` clause rather than replacing it. The model is a learned
approximation of the threshold rule and drops about 1% of true positives, so
filtering on it would emit a subtly wrong answer; `agree` reports its recall
instead.

---

## The Pre-Training Strategy

Training takes about 33 seconds. Since the judge invokes `do ^RunScript` on a
fresh container every time, paying that on every run would triple the measured
time, so `pretrain_gaia_model.py` runs during `docker build`:

```dockerfile
RUN --mount=type=bind,src=.,dst=. \
    iris start IRIS && \
    iris merge IRIS merge.cpf && \
    iris session IRIS < iris.script && \
    /usr/irissys/bin/irispython /home/irisowner/dev/pretrain_gaia_model.py && \
    iris stop IRIS quietly safely
```

`GaiaVariability` trains on 2,500 synthetic rows (2,000 stable, 500 variable)
covering the feature range, then the synthetic table is dropped. The two NGBoost
quality models train on `quality_train.csv.gz`, a real 5,344-source extract from
archive file 1. The split is on purpose: synthetic rows for
`reject_fraction` would be generated from a rule I invented, which is the same
leakage that made the variability numbers meaningless. `reject_fraction` is
worth modelling because it is ESA's curation and not recoverable from
the features.

The last step of pre-training asserts the two heads differ:

```python
check = list(iris.sql.exec(
    "SELECT COUNT(*) AS n, SUM(CASE WHEN ABS(PREDICT(GaiaDataQuality) - "
    "PREDICT(GaiaQualityUncertainty)) < 1E-9 THEN 1 ELSE 0 END) AS identical "
    "FROM GaiaQualityStats"))[0]
if int(check[1]) == int(check[0]):
    raise RuntimeError("the sigma head did not take effect")
```

A stale copy or two directories pointing at the same file would produce two
identical mean models and a `prediction_sigma` column that is quietly wrong
rather than obviously broken. The build fails instead.

At runtime the model is already trained, `TRAIN MODEL` is skipped, and the whole
run is 11s instead of ~45s.

---

## RunScript.mac

The ObjectScript entry point is minimal:

```objectscript
ROUTINE RunScript
 New inDir,outDir,startTime,cmd,rc,elapsed
 Set inDir = "/home/irisowner/dev/data/in"
 Set outDir = "/home/irisowner/dev/data/out"
 Do ##class(%File).CreateDirectoryChain(outDir)
 Set startTime = $ZHOROLOG
 Set cmd = "GAIA_CACHE="_inDir_" GAIA_OUT="_outDir_" /usr/irissys/bin/irispython /home/irisowner/dev/run_embedded_iml.py"
 Set rc = $ZF(-1, cmd)
 Set elapsed = $ZHOROLOG - startTime
 If rc '= 0 { Write "ERROR: rc=",rc,! Quit }
 Write "OK: ",outDir,"/result.csv",!
 Write "Elapsed time: ",elapsed," seconds",!
 Quit
```

The AI Hub agent is not in this path. It makes LLM calls whose
latency is not mine to control, and this routine is the benchmarked one. It runs
separately as `do ^Analyze`.

`irispython` is the AI Hub's Embedded Python interpreter. It runs inside the
IRIS process, so `import iris` gives direct in-process SQL access with no TCP
overhead.

---

## Dockerfile

The entry requires the AI Hub image because IntegratedML's AutoML provider
(`intersystems-iris-automl`) is only available on AI builds:

```dockerfile
ARG IMAGE=docker.iscinternal.com/docker-intersystems/intersystems/irishealth-community:2026.3.0AI.126.0
FROM $IMAGE

WORKDIR /home/irisowner/dev
COPY . .

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends gcc g++ \
 && rm -rf /var/lib/apt/lists/* \
 && /usr/irissys/bin/irispython -m pip install --no-cache-dir \
        --index-url https://registry.intersystems.com/pypi/simple \
        --target /usr/irissys/mgr/python \
        intersystems-iris-automl isal \
 && /usr/irissys/bin/irispython -m pip install --no-cache-dir \
        --target /usr/irissys/mgr/python ngboost \
 && /usr/irissys/bin/irispython -c "from isal import isal_zlib; print('isal OK')" \
 && /usr/irissys/bin/irispython -c "from ngboost import NGBRegressor; print('ngboost OK')"

# Install the model files while still root: the Classifiers/Regressors dirs are
# root-owned, so the later irisowner build step cannot write into them.
RUN ADIR=$(/usr/irissys/bin/irispython -c "import os,iris_automl;print(os.path.dirname(iris_automl.__file__))") \
 && mkdir -p "$ADIR/Classifiers/gaia_variability" \
             "$ADIR/Regressors/gaia_quality_mean" \
             "$ADIR/Regressors/gaia_quality_sigma" \
 && cp gaia_variability_iris_model.py "$ADIR/Classifiers/gaia_variability/" \
 && cp gaia_quality_mean_model.py     "$ADIR/Regressors/gaia_quality_mean/" \
 && cp gaia_quality_sigma_model.py    "$ADIR/Regressors/gaia_quality_sigma/" \
 && cp gaia_quality_estimator.py /usr/irissys/mgr/python/
USER irisowner
```

`intersystems-iris-automl` installs `iris_automl`, which provides the AutoML
provider and the `Classifiers/` and `Regressors/` pools that IntegratedML
searches for custom `IRISModel` files. `isal` gives SIMD-accelerated gzip, and
inflate is about 70% of the scan, so the import is verified at build time rather
than silently falling back at runtime.

Classifiers and regressors come from separate pools reached by separate `USING`
keys. `pathtoclassifiers` searches `Classifiers/`, `pathtoregressors` searches
`Regressors/`, and a numeric target never looks in the classifier pool at all:
it reports `NoEstimatorChosen`. Passing `pathtoclassifiers` for the quality
models loads nothing and fails only once the built-in candidates are disabled.

The shared NGBoost estimator goes on the embedded Python path (`mgr/python`) so
both head files can import it.

---

## Four Gotchas for Embedded Python + IntegratedML

**1. Packages must install to `mgr/python`, not system Python.**

```bash
# Correct: targets IRIS's embedded Python package directory:
irispython -m pip install \
    --index-url https://registry.intersystems.com/pypi/simple \
    --target /usr/irissys/mgr/python \
    intersystems-iris-automl
```

If you install to the system Python, `irispython` won't find the packages.

**2. `ML_TRAINED_MODELS` doesn't support `WHERE` clauses.**

```python
# Wrong: IRIS raises "Field 'MODELNAME' not found":
iris.sql.exec("SELECT * FROM INFORMATION_SCHEMA.ML_TRAINED_MODELS WHERE ModelName='X'")

# Correct: fetch all, filter in Python:
trained = {r[0] for r in iris.sql.exec(
    "SELECT * FROM INFORMATION_SCHEMA.ML_TRAINED_MODELS"
)}
if "GaiaVariability" not in trained:
    iris.sql.exec("TRAIN MODEL GaiaVariability")
```

**3. `iris.sql.prepare().execute()` takes positional args, not a list.**

```python
stmt = iris.sql.prepare("INSERT INTO T VALUES (?,?,?)")

# Wrong: raises "Invalid Dynamic Statement Parameter":
stmt.execute([1, 2, 3])

# Correct:
stmt.execute(1, 2, 3)
# or:
stmt.execute(*row_tuple)
```

**4. `PREDICT()` is fast in a SELECT list and ruinous anywhere else.**

In a SELECT list it costs roughly 0.1 ms/row after model load. In an `ORDER BY`
it is re-invoked per comparison and effectively never returns: 2,000 rows did
not finish in 100 seconds, while the same two `PREDICT()`s in the SELECT list
took 0.2s. Sort the result in Python instead.

`UPDATE ... SET pred = PREDICT(...)` is worse. Measured across the 74,998 rows
it moved about two rows per second, and because it takes a row lock per row it
overflows the lock table and dies with SQLCODE -110 partway through, leaving a
half-scored table that every later `AVG()` silently averages over. The same work
as `INSERT INTO ... SELECT ... PREDICT(...)` takes 3.9s:

```python
iris.sql.exec("INSERT INTO GaiaQualityScored "
              "SELECT source_id, ..., PREDICT(GaiaDataQuality), "
              "PREDICT(GaiaQualityUncertainty) FROM GaiaQualityStats")
n = list(iris.sql.exec("SELECT COUNT(*), COUNT(pred_reject) FROM GaiaQualityScored"))[0]
if int(n[1]) != int(n[0]):
    raise RuntimeError(f"scored {n[1]} of {n[0]} rows")
```

The completeness assertion is there because a partial fill is invisible in every
aggregate that reads the table afterwards.

---

## Performance

Measured on the 20-file benchmark, 74,998 sources, ARM64 Docker:

| Stage                                                      | Cumulative |
| ---------------------------------------------------------- | ---------- |
| Decompress + parse 20 files (isal + ProcessPoolExecutor)   | 1.4s       |
| INSERT 74,998 rows into GaiaFluxStats                      | 2.5s       |
| INSERT 74,998 rows into GaiaQualityStats                   | 3.8s       |
| PREDICT(GaiaVariability) + write result.csv                | 5.4s       |
| NGBoost mean + sigma over 74,998 rows, quality.csv, scored | 11.0s      |
| **Total (`do ^RunScript`)**                                | **11.4s**  |

Training all three models is pre-done at container init and costs nothing at
runtime. The last stage is the expensive one: two NGBoost `PREDICT()` calls
across the full table for `quality.csv`, then the same two again as an
`INSERT...SELECT` to materialize `GaiaQualityScored` for the RLM analyst.

---

## What IntegratedML Adds Beyond the Threshold Filter

The contest formula already identifies variable sources correctly, so
`GaiaVariability` is a demonstration rather than a load-bearing part of the
answer. Its label is derived from `pct_change > 100`, which means the best it
can do is reproduce a rule I already have, and it reproduces it at 57.7% recall
(32,946 of 57,099). That is why `result.csv` comes from the `WHERE` clause and
the prediction is reported next to it rather than gating it. A model trained on
a synthetic distribution and evaluated on the real one is a good illustration of
why you check.

The second model is the one that earns its place. `reject_fraction` is the share
of a source's epochs that ESA's own variability pipeline threw out, and it is
not derivable from the flux summary columns, so there is something real to
learn. `GaiaDataQuality` is an NGBoost regressor over `n_bp`, `n_rp`, the BP/RP
signal-to-noise ratios, the coefficients of variation, the flux extremes and
`pct_change`. NGBoost predicts a distribution rather than a point, so a second
model file over the same fit returns the standard deviation, and every row in
`quality.csv` carries its own error bar.

Over all 74,998 sources its mean absolute error is 0.0432 against 0.0613 for
predicting the mean, 30% better, with a mean predicted sigma of 0.0466. Both
models are custom `IRISModel` files, both are called from SQL, and neither needs
a serving endpoint.

---

## The AI Hub Side: An Agent That Never Sees the Data

The obvious way to get an LLM to analyze these tables is to hand it a SQL
toolset and let it explore. I tried that first, in `Gaia.Analyst`, and it does
not work at this scale. `%AI.Tools.SQL`'s `ListTables` alone returns about 50KB
of namespace metadata, every tool result is re-sent on each subsequent call, and
gpt-4o-mini re-attempts discovery until `%AICore` raises `LoopDetected`.

`Gaia.RLM` inverts it. The data stays in SQL and the model interacts with it the
way a programmer uses a REPL: peek at a summary, choose a decomposition, recurse
into each part, then aggregate. Each call sees a few hundred characters
describing its own slice, so context depth is constant no matter how large the
table grows.

```text
ROOT      peek at survey-wide aggregates (never the rows)
          choose a decomposition from the whitelist
   |- LEAF(slice 1)   -> finding
   |- LEAF(slice 2)   -> still heterogeneous, so recurse
   |     |- LEAF(sub-slice a)
   |     '- LEAF(sub-slice b)
   '- LEAF(slice 3)   -> finding
REDUCE    synthesize the findings into the report
```

Two properties make it safe to ship. The model never writes SQL: it picks a
decomposition _key_ from a fixed whitelist and the class owns the predicates, so
there is no injection surface and no malformed-query retry loop. And cost is
bounded before the first call, by `MAXDEPTH = 3` and `MAXCALLS = 18`, with one
call reserved for the final synthesis. Every call is a single `Chat()`
round-trip rather than a tool loop, so `LoopDetected` cannot happen and
wall-clock is predictable.

The recursion is adaptive rather than a fixed fan-out. A slice is subdivided
only when its own reject-fraction standard deviation is still at least as large
as the whole survey's, meaning slicing bought no homogeneity and one summary
sentence would misrepresent it. From an actual run over 74,998 sources, 10 calls
of the 18 allowed:

```text
- clean (ESA rejected under 5% of epochs)  (n=13208, sd=0.0157) -> summarized
- moderate (5-20% rejected)                (n=52301, sd=0.0380) -> summarized
- heavy (20-50% rejected)                  (n=8844,  sd=0.0600) -> summarized
- severe (over half of all epochs)         (n=645,   sd=0.1462) -> split by variability
  - not variable (swing under 100%)        (n=150,   sd=0.1554) -> summarized
  - variable, modest swing (100-1000%)     (n=235,   sd=0.1375) -> summarized
  - variable, large swing (1000-100000%)   (n=193,   sd=0.1219) -> summarized
  - extreme swing (over 100000%)           (n=67,    sd=0.1137) -> summarized
```

Only `severe` needed subdividing, and it is the smallest slice, which is the
point: the badly-behaved tails are small by construction.

The agent reads `GaiaQualityScored`, the table with the NGBoost predictions
materialized as stored columns, so it can pass `AVG(pred_sigma)` per slice into
the prompt. That is what makes the report say where the model is least reliable
rather than only what the data looks like. Run it with `do ^RLMAudit`.

### The Same Idea With the Decomposition on the Other Side

`Gaia.RLM` owns the recursion in ObjectScript. `Recurse()` decides whether to
subdivide by comparing a slice's standard deviation to the survey baseline, and
the model only ever answers "which key should I split by". The AI Hub also ships
`%AI.Agent.SubAgent`, a `%AI.Tool` that spawns a child agent, which makes it
possible to hand the decomposition to the model instead. `Gaia.RLM2` answers the
same audit question that way, so the two reports are directly comparable.

The model sees the survey statistics and the slice menu and names the slices worth
separate analysis. Each one goes to a `SliceAnalyst` subagent that peeks at its
slice, sub-slices if the spread warrants it, and returns one paragraph. The root
then reduces those paragraphs into the report. Its context grows by a paragraph
per slice, the same bound the explicit recursion gets, reached by a different
route. A full audit is 36s: 6 delegations across 8 aggregate queries.

The trade is legible. `Gaia.RLM` costs at most 18 calls and every run has the same
shape. `Gaia.RLM2` is bounded at 6 delegations but its plan differs run to run.

One thing did not work as designed. The intent was to give the root the
`SliceAnalyst` as a tool and let its model choose when to delegate, putting the
recursion itself on the model's side. Delegation then hangs. `%AI.Tool`
execution goes through `%AI.ToolMgr.ExecuteTool`, which dispatches into the Rust
library via `$ZF(-6)`, and the subagent's own provider call inside that never comes
back; the tool returns an empty string. Called directly, the same subagent answers
in about 3 seconds. A one-method probe tool that does nothing but `Run()` a trivial
prompt reproduces it, so it is not specific to `SliceAnalyst`: in
`2026.3.0AI.126.0`, a tool that makes an LLM call cannot be driven by an agent
loop. So the plan is the model's and the spawn is ObjectScript's, which keeps the
interesting half and is honest about the other.

What does not change is where the safety lives. Handing the decomposition to the
model does not mean moving the constraints into the prompt. A model that names
slices needs the name to be a lookup, not a fragment, so `Gaia.Slice.Resolve()`
matches `reject_level:severe/epoch_count:few` against the same whitelist `Gaia.RLM`
uses and refuses everything else, including `reject_level:severe' OR 1=1 --`, which
fails because no such token exists rather than because it was escaped. And the
plan is filtered and truncated to the 6-delegation budget before the first spawn
rather than refused after the last one.

Both properties are then testable without an LLM, which is the practical reason
to put them there. `UnitTest.Gaia.RLM2` is 25 methods, none calling a provider,
and writing them first found five real bugs. Three were in the grammar and its
harness: a guard that used `$Length(used, ",")` to count resolved path components
and so passed on the empty string, because `$Length("", ",")` is 1; child tokens
derived as "first word, lowercased", which collided into `model` four times, so
`Resolve()` would have returned a different slice than the one the model asked for;
and an assumption that `%AI.Tool.%Invoke()` returns a wrapped object, when it
returns the method's own value. The other two came out of reading the first
finished report: `%Stream.FileCharacter` defaults to the local 8-bit table, so
every em dash the model wrote reached the file as `?`, and the analysts' own
sub-peeks were being recorded in the same trace as the delegations, so a 6-slice
plan produced 8 trace lines and read as a budget violation. The encoding bug was
in `Gaia.RLM` too, and had been shipping in `rlm_audit.md` unnoticed.

Run it with `do ^RLM2Audit`.

---

## Mapping the Codebase: ObjectScript in codebase-memory-mcp

This repo is two languages stapled together at the Embedded Python boundary,
which makes it awkward to navigate.
[codebase-memory-mcp](https://github.com/DeusData/codebase-memory-mcp) is an
open MCP server that builds a queryable graph of a codebase: nodes for classes,
methods, files and modules, edges for definition, calls and data flow, reachable
over Cypher or natural language from any MCP-capable agent. I contributed the
InterSystems ObjectScript support, so this section is partly self-interested,
which is why the numbers below are measured rather than asserted.

One caveat on versions. The tagged release
[v0.9.0](https://github.com/DeusData/codebase-memory-mcp/releases/tag/v0.9.0)
vendors the ObjectScript grammars but does not wire them into the extractor.
`lang_specs.c` on that tag contains no ObjectScript entries at all, so `.cls`
files come through as files and little else. The extraction wiring merged
afterwards ([PR #467](https://github.com/DeusData/codebase-memory-mcp/pull/467)
and follow-ups). Everything below is from `main` built from source, not from the
current release binary.

Indexing this repo produced a 168-node, 411-edge graph. The ObjectScript side of
it:

```text
MATCH (c:Class) WHERE c.name STARTS WITH 'Gaia' RETURN c.name, c.base_classes
  Gaia.RLM       ["%AI.Agent"]   lines 46-519
  Gaia.Analyst   ["%AI.Agent"]   lines 14-159
```

Both agent classes, with the superclass parsed off the `Extends` clause. 16 of
the 28 `Method` nodes are ObjectScript ClassMethods, with correct line ranges,
and the `INSTRUCTIONS` XData block in `Gaia.Analyst` gets its own node type. 25
`CALLS` edges connect methods inside the `.cls` files, resolved through the
relative-dot form ObjectScript uses for self-dispatch:

```text
MATCH (a:Method)-[r:CALLS]->(b:Method) WHERE a.file_path ENDS WITH '.cls'
  Recurse -> Peek             310
  Recurse -> ShouldRecurse    321
  Recurse -> ChooseDimension  348
  Report  -> Recurse          425
  Audit   -> Report           500
  ...
```

That makes `trace_path` work on the recursion I cared about. Asking for
`Recurse` returns 9 callees and 3 callers, which is the whole control flow of
the RLM pass without opening the file:

```text
trace_path(function_name="Recurse", mode="calls")
  callees: Ask, BaselineSpread, CallCount, ChooseDimension, Describe,
           Dimensions, Indent, Peek, ShouldRecurse
  callers: Report (1 hop), Audit (2), Triage (2)
```

Graph-augmented search is the other thing I use constantly. `Recurse` has 9 raw
grep hits across the repo; the search returns 4 results, each one a symbol with
its line range and its in/out degree attached, so the hit at line 425 arrives
labelled as "inside `Report`, which has 8 outgoing calls" rather than as a line
number.

Two limitations worth naming. `Recurse` calls itself at line 363 and that edge
is missing. Self-calls through `..Method()` are the one relative-dot case not
yet resolved, so the graph shows everything about the recursion except that it
recurses. And nothing links the two languages, which no extractor could:
`^RunScript` shelling out to `irispython`, and `iris.sql.exec()` calling back
into IRIS, are runtime handoffs rather than imports. Within one language the
graph is now good enough that I stopped grepping.

---

## Source Code

[isc-tdyar/gaia-iml](https://github.com/isc-tdyar/gaia-iml)

| File                              | Purpose                                              |
| --------------------------------- | ---------------------------------------------------- |
| `src/RunScript.mac`               | ObjectScript entry point (`do ^RunScript`)           |
| `src/Analyze.mac`                 | AI Hub agent report (`do ^Analyze`)                  |
| `src/RLMAudit.mac`                | Recursive data-quality audit (`do ^RLMAudit`)        |
| `src/RLMTriage.mac`               | Recursive triage pass (`do ^RLMTriage`)              |
| `src/RLM2Audit.mac`               | Delegated audit (`do ^RLM2Audit`)                    |
| `src/Gaia/Analyst.cls`            | `%AI.Agent` subclass: evidence + report              |
| `src/Gaia/RLM.cls`                | Recursive language model over aggregates             |
| `src/Gaia/RLM2.cls`               | Same idea via `%AI.Agent.SubAgent` delegation        |
| `src/Gaia/Slice.cls`              | Slice-name whitelist shared by both RLMs             |
| `src/Gaia/Tools/Survey.cls`       | Aggregate-only toolset given to every agent          |
| `src/Gaia/Tools/SliceAnalyst.cls` | The `%AI.Agent.SubAgent` the root delegates to       |
| `src/UnitTest/Gaia/RLM2.cls`      | 25 LLM-free tests: grammar, plan, budget, tools      |
| `run_embedded_iml.py`             | irispython pipeline: scan → ingest → PREDICT() → CSV |
| `gaia_variability_iris_model.py`  | Custom IRISModel (GradientBoostingClassifier)        |
| `gaia_quality_estimator.py`       | NGBoost estimator shared by both quality heads       |
| `gaia_quality_mean_model.py`      | IRISModel for `GaiaDataQuality` (predictive mean)    |
| `gaia_quality_sigma_model.py`     | IRISModel for `GaiaQualityUncertainty` (sigma)       |
| `pretrain_gaia_model.py`          | Trains all three models at `docker build` time       |
| `quality_train.csv.gz`            | 5,344-source real extract, quality models            |
| `iris.script`                     | Compiles the routines and agent classes              |
| `Dockerfile`                      | AI Hub image + iris-automl + ngboost + isal          |
| `docker-compose.yml`              | Volume mounts for data in/out                        |

Other entries:

- [isc-tdyar/gaia-fast](https://github.com/isc-tdyar/gaia-fast): isal +
  ProcessPoolExecutor, ~1s, no IntegratedML
- [isc-tdyar/gaia-golf](https://github.com/isc-tdyar/gaia-golf): 580-char
  `$SYSTEM.Python.Run()` one-liner, ~17s
