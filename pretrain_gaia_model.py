"""
Pre-train the GaiaDataQuality / GaiaQualityUncertainty IntegratedML models at
container build time, so RunScript pays no training cost at contest time.

Both are custom IRISModel classes (NGBoost) trained on a real extract,
quality_train.csv.gz.
"""
import iris

# Ensure AutoML provider is registered
try:
    iris.cls("%ML.Provider")._CreateProvider("AutoML", "%ML.AutoML.Provider")
except Exception as e:
    if "already registered" not in str(e).lower():
        print(f"AutoML provider note: {e}")

# ---------------------------------------------------------------------------
# GaiaDataQuality / GaiaQualityUncertainty: NGBoost regression on ESA's own
# per-epoch reject flags.
#
# Trained on a real extract (quality_train.csv.gz, 5,344 sources from archive
# file 1), not synthetic data. Rows synthesized from a rule we invented would
# leak the target: reject_fraction is worth modelling precisely because it is
# ESA's curation and is not recoverable from the features.
# ---------------------------------------------------------------------------
import csv, gzip, os, iris_automl

# Resolve the Regressors dir by importing the installed package rather than
# globbing for it: the install prefix differs across IRIS images, and a missed
# glob silently yields a path of "None", which then fails deep inside
# TRAIN MODEL. The Dockerfile already copied the models in as root.
automl_root = os.path.dirname(iris_automl.__file__)

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
#
# Each model also gets its own subdirectory: load_models() imports every .py in
# the directory it is given, so co-locating the two heads makes AutoML try each
# on the other's target.
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
