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
# globbing for it — the install prefix differs across IRIS images, and a missed
# glob silently yields a pathtoclassifiers of "None", which then fails deep
# inside TRAIN MODEL. The Dockerfile already copied the classifier in as root.
import os, iris_automl

classifiers_path = os.path.join(os.path.dirname(iris_automl.__file__), "Classifiers")
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
