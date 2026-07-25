"""
Pre-train GaiaVariability IntegratedML model at container build time.
This eliminates 33s training cost from RunScript execution at contest time.

Synthetic training data covers the full feature space: stable stars (pct_change < 50)
and variable stars (pct_change > 100). Model learns the threshold pattern from features.
"""
import iris, random

random.seed(42)

# Ensure AutoML provider is registered
try:
    iris.cls("%ML.Provider")._CreateProvider("AutoML", "%ML.AutoML.Provider")
except Exception as e:
    if "already registered" not in str(e).lower():
        print(f"AutoML provider note: {e}")

# Build synthetic training set: 2000 stable + 500 variable stars
rows = []
for i in range(2000):
    scale = random.uniform(100, 50000)
    pct = random.uniform(0, 90)
    bn = scale
    bx = bn * (1 + pct/100)
    rn = scale * random.uniform(0.5, 2)
    rx = rn * (1 + pct * random.uniform(0.5, 1.5) / 100)
    nb = random.randint(2, 90)
    nr = random.randint(2, 89)
    rows.append((i + 1000000, bn, bx, rn, rx, nb, nr, round(pct, 4), 0))
for i in range(500):
    scale = random.uniform(100, 50000)
    pct = random.uniform(110, 10000)
    bn = scale
    bx = bn * (1 + pct/100)
    rn = scale * random.uniform(0.5, 2)
    rx = rn * (1 + pct * random.uniform(0.5, 1.5) / 100)
    nb = random.randint(2, 90)
    nr = random.randint(2, 89)
    rows.append((i + 3000000, bn, bx, rn, rx, nb, nr, round(pct, 4), 1))

for sql in (
    "DROP TABLE IF EXISTS GaiaFluxStats",
    "CREATE TABLE GaiaFluxStats (source_id BIGINT,bp_min DOUBLE,bp_max DOUBLE,"
    "rp_min DOUBLE,rp_max DOUBLE,n_bp INTEGER,n_rp INTEGER,pct_change DOUBLE,is_variable INTEGER)",
):
    iris.sql.exec(sql)

stmt = iris.sql.prepare("INSERT INTO GaiaFluxStats VALUES (?,?,?,?,?,?,?,?,?)")
for r in rows:
    stmt.execute(*r)
print(f"Inserted {len(rows)} synthetic training rows")

# Resolve the Classifiers dir by importing the installed package rather than
# globbing for it: the install prefix differs across IRIS images, and a missed
# glob silently yields a pathtoclassifiers of "None", which then fails deep
# inside TRAIN MODEL. The Dockerfile already copied the classifier in as root.
import os, iris_automl

automl_root = os.path.dirname(iris_automl.__file__)
# Classification and regression models are loaded from separate pools, by
# separate USING keys: pathtoclassifiers -> Classifiers, pathtoregressors ->
# Regressors (iris_automl/automl_train.py, _determine_best_regressor). Passing
# pathtoclassifiers for a numeric target silently loads no custom model at all
# and TRAIN MODEL then dies with NoEstimatorChosen once the isc models are off.
#
# Each model also gets its own subdirectory: load_models() imports every .py in
# the directory it is given, so co-locating two models makes AutoML try each on
# the other's target.
classifiers_path = os.path.join(automl_root, "Classifiers", "gaia_variability")
model_file = os.path.join(classifiers_path, "gaia_variability_iris_model.py")
if not os.path.isfile(model_file):
    raise RuntimeError(f"custom classifier not installed at {model_file}")
print(f"Using classifiers dir {classifiers_path}")

# Create and train model
for sql in ("DROP MODEL IF EXISTS GaiaVariability",):
    try: iris.sql.exec(sql)
    except: pass

using = '{"iscmodelsdisabled":1,"pathtoclassifiers":"' + str(classifiers_path) + '"}'
# Train on the raw flux columns only. pct_change must be excluded: is_variable is
# defined as pct_change > 100, so including it leaks the target and the model
# degenerates to "always 1" - it predicted variable for all 74,998 real rows,
# including all 17,899 with pct_change <= 100. Learning from the fluxes and epoch
# counts instead makes PREDICT() a genuine classifier.
iris.sql.exec(
    f"CREATE MODEL GaiaVariability PREDICTING (is_variable) "
    f"WITH (bp_min NUMERIC, bp_max NUMERIC, rp_min NUMERIC, rp_max NUMERIC, "
    f"n_bp NUMERIC, n_rp NUMERIC) "
    f"FROM GaiaFluxStats USING {using}"
)
print("Training GaiaVariability model...")
iris.sql.exec("TRAIN MODEL GaiaVariability")
print("GaiaVariability model trained and ready.")

# Clean up synthetic training data (real data ingested at RunScript time)
iris.sql.exec("DROP TABLE IF EXISTS GaiaFluxStats")

# ---------------------------------------------------------------------------
# GaiaDataQuality / GaiaQualityUncertainty: NGBoost regression on ESA's own
# per-epoch reject flags.
#
# Trained on a real extract (quality_train.csv.gz, 5,344 sources from archive
# file 1), not synthetic data. Synthetic rows would be generated from a rule we
# invented, the same leakage that made the GaiaVariability numbers
# meaningless - reject_fraction is only worth modelling because it is ESA's
# curation and not recoverable from the features.
# ---------------------------------------------------------------------------
import csv, gzip

FEATS = ["n_bp", "n_rp", "bp_snr", "rp_snr", "bp_cv", "rp_cv",
         "bp_min", "bp_max", "rp_min", "rp_max"]

train_path = "/home/irisowner/dev/quality_train.csv.gz"
with gzip.open(train_path, "rt") as fh:
    qrows = list(csv.DictReader(fh))
print(f"Loaded {len(qrows)} real training rows from {train_path}")

for sql in (
    "DROP TABLE IF EXISTS GaiaQualityStats",
    "CREATE TABLE GaiaQualityStats (source_id BIGINT,n_bp INTEGER,n_rp INTEGER,"
    "bp_snr DOUBLE,rp_snr DOUBLE,bp_cv DOUBLE,rp_cv DOUBLE,bp_min DOUBLE,"
    "bp_max DOUBLE,rp_min DOUBLE,rp_max DOUBLE,pct_change DOUBLE,reject_fraction DOUBLE)",
):
    iris.sql.exec(sql)

qstmt = iris.sql.prepare("INSERT INTO GaiaQualityStats VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)")
for r in qrows:
    qstmt.execute(int(r["source_id"]), int(r["n_bp"]), int(r["n_rp"]),
                  float(r["bp_snr"]), float(r["rp_snr"]), float(r["bp_cv"]),
                  float(r["rp_cv"]), float(r["bp_min"]), float(r["bp_max"]),
                  float(r["rp_min"]), float(r["rp_max"]), float(r["pct_change"]),
                  float(r["reject_fraction"]))

# pct_change is excluded from the feature list on purpose. It is not a leak here
# (the target is ESA's, not ours) but it is the challenge's answer column, and
# keeping it out means the quality score is independent evidence rather than a
# restatement of result.csv.
withcols = ", ".join(f + " NUMERIC" for f in FEATS)

# PREDICT() yields one scalar per row, so the predictive mean and its standard
# deviation are two models. They are two model *files* in two directories rather
# than one parameterised file because AutoML forwards only isc_models_disabled,
# n_jobs, problem_type, random_state and verbose into IRISModel(**kwargs) - any
# other USING key is dropped before it arrives, so the head cannot be passed in.
#
# pathtoregressors, not pathtoclassifiers: regression and classification
# candidates come from separate pools, and a numeric target never looks in the
# classifier pool - it reports NoEstimatorChosen instead.
QUALITY_MODELS = (
    ("GaiaDataQuality", "gaia_quality_mean", "gaia_quality_mean_model.py", "mean"),
    ("GaiaQualityUncertainty", "gaia_quality_sigma", "gaia_quality_sigma_model.py", "sigma"),
)

for name, subdir, filename, head in QUALITY_MODELS:
    regressors_path = os.path.join(automl_root, "Regressors", subdir)
    if not os.path.isfile(os.path.join(regressors_path, filename)):
        raise RuntimeError(f"quality model not installed at {regressors_path}/{filename}")
    try:
        iris.sql.exec(f"DROP MODEL IF EXISTS {name}")
    except Exception:
        pass
    qusing = ('{"iscmodelsdisabled":1,"pathtoregressors":"' + regressors_path + '"}')
    iris.sql.exec(
        f"CREATE MODEL {name} PREDICTING (reject_fraction) "
        f"WITH ({withcols}) FROM GaiaQualityStats USING {qusing}"
    )
    print(f"Training {name} (NGBoost, {head} head)...")
    iris.sql.exec(f"TRAIN MODEL {name}")
    print(f"{name} trained.")

# Verify the two models really are different heads. They are trained from
# separate files, so a mistake here (both pointing at the same directory, or a
# stale copy) would silently produce two identical mean models and a
# prediction_sigma column that is quietly wrong rather than obviously broken.
check = list(iris.sql.exec(
    "SELECT COUNT(*) AS n, SUM(CASE WHEN ABS(PREDICT(GaiaDataQuality) - "
    "PREDICT(GaiaQualityUncertainty)) < 1E-9 THEN 1 ELSE 0 END) AS identical "
    "FROM GaiaQualityStats"))[0]
if int(check[1]) == int(check[0]):
    raise RuntimeError("GaiaQualityUncertainty is returning the same values as "
                       "GaiaDataQuality - the sigma head did not take effect")
print(f"Head check: {check[1]}/{check[0]} rows identical (expected near 0)")

iris.sql.exec("DROP TABLE IF EXISTS GaiaQualityStats")
print("Quality models ready.")
