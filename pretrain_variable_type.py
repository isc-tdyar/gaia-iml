"""
Pre-train the GaiaVariableType IntegratedML model at container build time.

Multi-class variable-star classification from Gaia DR3 light-curve features.
Labels are ESA's own, from gaiadr3.vari_classifier_result.best_class_name, so
the ground truth is the published DR3 classification rather than anything
invented here.

Training data: variable_type_train.csv.gz, a class-balanced sample (<=1200 per
class, 10,660 rows) drawn from the 70,385 sources in the 20-file benchmark that
carry a DR3 classifier label. Balanced on purpose -- the raw population is 26%
AGN and 0.5% RR, and a model trained on that ordering learns the prior instead
of the physics.
"""
import csv
import gzip
import os

import iris
import iris_automl

from gaia_lightcurve_features import FEATURES

# Ensure the AutoML provider is registered.
try:
    iris.cls("%ML.Provider")._CreateProvider("AutoML", "%ML.AutoML.Provider")
except Exception as e:
    if "already registered" not in str(e).lower():
        print(f"AutoML provider note: {e}")

# Resolve the Classifiers dir by importing the installed package rather than
# globbing: the install prefix differs across IRIS images, and a missed glob
# yields a path of "None" that fails deep inside TRAIN MODEL.
automl_root = os.path.dirname(iris_automl.__file__)
classifiers_path = os.path.join(automl_root, "Classifiers", "gaia_variable_type")
model_file = os.path.join(classifiers_path, "gaia_variable_type_model.py")
if not os.path.isfile(model_file):
    raise RuntimeError(f"classifier not installed at {model_file}")

train_path = "/home/irisowner/dev/variable_type_train.csv.gz"
with gzip.open(train_path, "rt") as fh:
    rows = list(csv.DictReader(fh))
print(f"Loaded {len(rows)} labelled training rows from {train_path}")

coldefs = ", ".join(f"{f} DOUBLE" for f in FEATURES)
for sql in (
    "DROP TABLE IF EXISTS GaiaLightCurveFeatures",
    f"CREATE TABLE GaiaLightCurveFeatures (source_id BIGINT, {coldefs}, "
    "var_class VARCHAR(32))",
):
    iris.sql.exec(sql)

placeholders = ",".join("?" * (len(FEATURES) + 2))
stmt = iris.sql.prepare(
    f"INSERT INTO GaiaLightCurveFeatures VALUES ({placeholders})")


def _num(v):
    """CSV cell -> float, or "" meaning SQL NULL.

    The empty string is not a stylistic choice. Passing Python `None` through
    iris.sql.prepare().execute() does not produce NULL -- it hands SQL a Python
    object reference and the insert dies with:

        Field 'SQLUser.GaiaLightCurveFeatures.bp_mean'
        (value '6@%SYS.Python') failed validation

    Passing float("nan") is worse: it inserts cleanly and stores the literal
    `nan`, which is not NULL, so `WHERE x IS NULL` misses it and the model sees a
    number that is not a number. The empty string is the one input that lands as
    a real SQL NULL.

    Missing stays missing on purpose: HistGradientBoostingClassifier takes NaN
    natively, and imputing a Lomb-Scargle period for a source with too few
    epochs would invent a signal that was never observed.
    """
    if v is None or v == "":
        return ""
    try:
        f = float(v)
    except (TypeError, ValueError):
        return ""
    return "" if f != f else f


for r in rows:
    stmt.execute(int(r["source_id"]),
                 *[_num(r.get(f)) for f in FEATURES],
                 r["var_class"])
print(f"Inserted {len(rows)} rows into GaiaLightCurveFeatures")

# pathtoclassifiers, not pathtoregressors: a categorical target never consults
# the regressor pool.
withcols = ", ".join(f"{f} NUMERIC" for f in FEATURES)
using = ('{"iscmodelsdisabled":1,"random_state":42,"pathtoclassifiers":"'
         + classifiers_path + '"}')

try:
    iris.sql.exec("DROP MODEL IF EXISTS GaiaVariableType")
except Exception:
    pass

iris.sql.exec(
    f"CREATE MODEL GaiaVariableType PREDICTING (var_class) "
    f"WITH ({withcols}) FROM GaiaLightCurveFeatures USING {using}"
)
print("Training GaiaVariableType (HistGradientBoosting, 9 classes)...")
iris.sql.exec("TRAIN MODEL GaiaVariableType")
print("GaiaVariableType trained.")

# Smoke test: the model must produce more than one distinct class. A model that
# collapses to the majority class still "trains" and still returns rows.
check = list(iris.sql.exec(
    "SELECT COUNT(DISTINCT PREDICT(GaiaVariableType)) AS n_classes "
    "FROM GaiaLightCurveFeatures"))[0]
n_classes = int(check[0])
if n_classes < 2:
    raise RuntimeError(
        f"GaiaVariableType predicts only {n_classes} distinct class; "
        "the model collapsed rather than learning")
print(f"Smoke test: model predicts {n_classes} distinct classes.")
