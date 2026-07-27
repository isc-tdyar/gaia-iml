#!/usr/bin/env bash
#
# Regression test for the cross-process PREDICT() failure.
#
# The bug this guards against is silent. A custom IRISModel whose estimator does
# not survive dill's round trip trains correctly, predicts correctly in the
# process that trained it, and then returns ZERO ROWS from PREDICT() in every
# other process -- with SQLCODE=0, no exception and nothing in messages.log. It
# looks like an empty table, not a broken model.
#
# Two things cause it, and either one alone is enough:
#   1. a wrapper estimator that builds its real model inside fit()
#      -> subclass the sklearn estimator instead
#   2. the module defining the estimator class not being on the embedded Python
#      path (dill serializes classes by reference)
#      -> copy it to /usr/irissys/mgr/python/, not only into the pool directory
#
# It matters because the models are trained at `docker build` time and every
# PREDICT() at runtime is a different process. It also survives hot-patch
# testing in a warm container, so this test insists on a container that was
# started fresh.
#
# Usage: tests/test_predict_cold.sh [container]
set -uo pipefail

CONTAINER="${1:-gaia-iml-iris}"
FAIL=0

check() {  # check <description> <condition-result>
  if [ "$2" = "0" ]; then
    printf '  ok   %s\n' "$1"
  else
    printf '  FAIL %s\n' "$1"
    FAIL=1
  fi
}

echo "cold-start PREDICT() regression test (container: $CONTAINER)"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "  FAIL container $CONTAINER is not running"
  exit 1
fi

# Restart so nothing is served from a warm process. This is the whole point of
# the test: the bug is invisible without it.
echo "  restarting container to guarantee a cold process..."
docker restart "$CONTAINER" >/dev/null
for _ in $(seq 1 60); do
  if docker exec "$CONTAINER" iris session IRIS -U USER </dev/null >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

OUT=$(docker exec "$CONTAINER" /usr/irissys/bin/irispython -c '
import iris
n = list(iris.sql.exec("SELECT COUNT(*) FROM GaiaLightCurveFeatures"))[0][0]
rows = list(iris.sql.exec(
    "SELECT TOP 20 var_class, PREDICT(GaiaVariableType) FROM GaiaLightCurveFeatures"))
classes = list(iris.sql.exec(
    "SELECT COUNT(DISTINCT PREDICT(GaiaVariableType)) FROM GaiaLightCurveFeatures"))
agree = list(iris.sql.exec(
    "SELECT COUNT(*) FROM GaiaLightCurveFeatures "
    "WHERE var_class = PREDICT(GaiaVariableType)"))
print("TABLEROWS", n)
print("PREDROWS", len(rows))
print("DISTINCT", classes[0][0] if classes else 0)
print("AGREE", agree[0][0] if agree else 0)
' 2>&1)

echo "$OUT" | grep -E '^(TABLEROWS|PREDROWS|DISTINCT|AGREE)' | sed 's/^/    /'

tablerows=$(echo "$OUT" | awk '/^TABLEROWS/{print $2}')
predrows=$(echo "$OUT"  | awk '/^PREDROWS/{print $2}')
distinct=$(echo "$OUT"  | awk '/^DISTINCT/{print $2}')
agree=$(echo "$OUT"     | awk '/^AGREE/{print $2}')

check "training table is populated"            "$([ "${tablerows:-0}" -gt 1000 ] && echo 0 || echo 1)"

# The headline assertion. Zero here is the bug, and it is why this file exists.
check "PREDICT() returns rows in a cold process" \
      "$([ "${predrows:-0}" -eq 20 ] && echo 0 || echo 1)"

# A model that collapsed to one class still returns rows, so check the spread.
check "predicts more than one class"           "$([ "${distinct:-0}" -ge 2 ] && echo 0 || echo 1)"

# Fit data, so agreement should be high; this catches a model that reloads as
# noise rather than failing outright.
if [ "${tablerows:-0}" -gt 0 ] && [ "${agree:-0}" -gt 0 ]; then
  pct=$(( 100 * agree / tablerows ))
  check "agreement on training data >= 90% (got ${pct}%)" \
        "$([ "$pct" -ge 90 ] && echo 0 || echo 1)"
else
  check "agreement on training data >= 90%" 1
fi

if [ "$FAIL" -eq 0 ]; then
  echo "PASS"
else
  echo "FAIL -- see gaia_variable_type_model.py for the two-part cause"
fi
exit "$FAIL"
