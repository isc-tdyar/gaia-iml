#!/usr/bin/env bash
#
# End-to-end: what a judge does, and nothing else.
#
#   docker exec gaia-iml-iris ... 'do ^RunScript'
#     -> data/out/result.csv    the challenge answer, from a deterministic rule
#     -> data/out/quality.csv   the IntegratedML deliverable, from PREDICT()
#
# Both outputs are deleted first. A test that passes because the previous run's
# files are still there is worse than no test: it reports the pipeline working on
# the day it breaks.
#
# The challenge answer is a specific set of 57,099 source_ids, and all three
# entries (gaia-iml, gaia-fast, gaia-terse) must produce exactly the same one by
# three unrelated routes. That set's checksum is asserted below as a literal, so
# this file is also the cross-entry agreement test -- if the three checksums ever
# disagree, at most one of the entries is right.
#
# This entry's own claim is larger than the other two: every source is scored by
# two custom NGBoost IRISModels through SQL PREDICT(). result.csv being right does
# not test that at all -- it comes from a WHERE clause -- so quality.csv and the
# GaiaQualityScored table are asserted separately, and that is most of what is
# below.
#
# The analysis layer (^Analyze, ^RLMAudit, ^RLMTriage, ^RLM2Audit) is NOT run here.
# Those make LLM calls whose latency and output are not ours to control, and they
# are deliberately outside ^RunScript. `tests/zpm_install.sh` covers the install
# side of them, and the %UnitTest suite covers their logic against a null provider.
#
# Usage: tests/e2e.sh [container]
set -euo pipefail

CONTAINER="${1:-gaia-iml-iris}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO/data/out/result.csv"
QUALITY="$REPO/data/out/quality.csv"

# Measured on the 20-file benchmark.
WANT_ROWS=57099
WANT_HEADER="source_id,bp_min_flux,bp_max_flux,rp_min_flux,rp_max_flux,percentage_change"
WANT_IDS_SHA="7018a3b12c539f1de54163a393aa4bcb586bb8f8"
WANT_QUALITY_ROWS=74998
WANT_QUALITY_HEADER="source_id,esa_reject_fraction,predicted_reject_fraction,prediction_sigma,n_bp,n_rp,percentage_change"
# ~11s measured, and this is the entry whose listing quotes a time while also
# doing the ML work. The ceiling catches an order-of-magnitude regression -- most
# plausibly a model reloading or retraining per row instead of once at build time.
MAX_SECONDS=45
# MAE 0.0432 against 0.0613 for predicting the mean. The gate is the comparison,
# not the figure: a model no better than the mean is not worth a PREDICT() call,
# and that is the failure a row-count check cannot see.
BASELINE_MAE=0.0613

FAIL=0
ok()   { echo "  ok   $1"; }
bad()  { echo "  FAIL $1"; FAIL=1; }
want() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

echo "== e2e: gaia-iml in $CONTAINER"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
	echo "  FAIL $CONTAINER is not running (docker compose up --build -d)"
	exit 1
fi

INPUTS=$(ls "$REPO"/data/in/*.gz 2>/dev/null | wc -l | tr -d ' ')
want "20 input files are present" "$INPUTS" "20"
if [ "$INPUTS" != "20" ]; then
	echo "  (see README: download the first 20 EpochPhotometry files)"
	exit 1
fi

rm -f "$OUT" "$QUALITY"
[ ! -f "$OUT" ] && [ ! -f "$QUALITY" ] && ok "previous outputs cleared" || bad "could not clear outputs"

RUN=$(printf 'do ^RunScript\nhalt\n' | docker exec -i "$CONTAINER" iris session IRIS -U USER 2>&1)
echo "$RUN" | grep -E "OK:|ERROR|Elapsed|MAE|sigma" || true
echo "-- assertions"

case "$RUN" in
*"OK: /home/irisowner/dev/data/out/result.csv"*) ok "^RunScript reports success" ;;
*) bad "^RunScript did not report success" ;;
esac
case "$RUN" in *"ERROR: rc="*) bad "the embedded python step returned nonzero" ;; *) ok "no pipeline error" ;; esac

# The routine prints its own elapsed time; assert against that rather than timing
# the docker exec, which would fold in session startup.
ELAPSED=$(printf '%s' "$RUN" | sed -n 's/^Elapsed time: \([0-9.]*\).*/\1/p' | head -1)
if [ -z "$ELAPSED" ]; then
	bad "^RunScript printed no elapsed time"
elif [ "$(echo "$ELAPSED < $MAX_SECONDS" | bc -l)" = "1" ]; then
	ok "ran in ${ELAPSED}s (under ${MAX_SECONDS}s)"
else
	bad "took ${ELAPSED}s, over the ${MAX_SECONDS}s ceiling"
fi

echo "-- result.csv (the challenge answer)"

if [ ! -s "$OUT" ]; then
	bad "result.csv was not written"
	echo; echo "FAIL: gaia-iml e2e"; exit 1
fi
ok "result.csv exists and is non-empty"

want "header is the challenge's column list" "$(head -1 "$OUT")" "$WANT_HEADER"
want "row count"                             "$(( $(wc -l < "$OUT") - 1 ))" "$WANT_ROWS"
want "the source_id set matches all three entries" \
	"$(tail -n +2 "$OUT" | cut -d, -f1 | sort | shasum | cut -d' ' -f1)" "$WANT_IDS_SHA"

SORTED=$(tail -n +2 "$OUT" | cut -d, -f6 | awk 'NR>1 && $1>prev+1e-9 {print "unsorted"; exit} {prev=$1}')
want "rows are sorted by percentage_change descending" "${SORTED:-sorted}" "sorted"

BELOW=$(tail -n +2 "$OUT" | awk -F, '$6 <= 100 {c++} END {print c+0}')
want "no row is below the 100% threshold" "$BELOW" "0"
want "no duplicate source_id" \
	"$(tail -n +2 "$OUT" | cut -d, -f1 | sort | uniq -d | wc -l | tr -d ' ')" "0"

BADFLUX=$(tail -n +2 "$OUT" | awk -F, '$2>$3 || $4>$5 {c++} END {print c+0}')
want "bp/rp min never exceeds max" "$BADFLUX" "0"
NONNUM=$(tail -n +2 "$OUT" | awk -F, '$1 !~ /^[0-9]+$/ || $6 !~ /^[0-9.eE+-]+$/ {c++} END {print c+0}')
want "source_id integral and percentage numeric on every row" "$NONNUM" "0"

echo "-- quality.csv (the IntegratedML deliverable)"

if [ ! -s "$QUALITY" ]; then
	bad "quality.csv was not written -- PREDICT() did not run"
	echo; echo "FAIL: gaia-iml e2e"; exit 1
fi
ok "quality.csv exists and is non-empty"

want "quality header" "$(head -1 "$QUALITY")" "$WANT_QUALITY_HEADER"
# Every source, not only the detections: the quality question is asked of the whole
# survey, and a file of 57,099 rows would mean it silently inherited result.csv's
# filter.
want "every source is scored, not only the detections" \
	"$(( $(wc -l < "$QUALITY") - 1 ))" "$WANT_QUALITY_ROWS"

# A model that returns a constant produces a full file with a plausible mean, and
# every count-based check above passes. Distinct values is what catches it.
DISTINCT=$(tail -n +2 "$QUALITY" | cut -d, -f3 | sort -u | wc -l | tr -d ' ')
if [ "$DISTINCT" -gt 1000 ]; then
	ok "predictions vary ($DISTINCT distinct values, so not a constant)"
else
	bad "only $DISTINCT distinct predictions -- the model is returning a constant"
fi

# A reject fraction is a proportion. Out-of-range output means the regressor is
# being read as something it is not.
OOR=$(tail -n +2 "$QUALITY" | awk -F, '$3 < -0.5 || $3 > 1.5 {c++} END {print c+0}')
want "predicted reject fraction stays near [0,1]" "$OOR" "0"
# The sigma head is the second model, and the point of using NGBoost at all. A
# nonpositive error bar means it is unfit or unwired.
BADSIG=$(tail -n +2 "$QUALITY" | awk -F, '$4 <= 0 {c++} END {print c+0}')
want "every row has a positive prediction sigma" "$BADSIG" "0"

# The accuracy claim on the listing, recomputed from the file rather than trusted
# from the run's own log line.
MAE=$(tail -n +2 "$QUALITY" | awk -F, '{s += ($3>$2 ? $3-$2 : $2-$3); n++} END {printf "%.4f", s/n}')
if [ "$(echo "$MAE < $BASELINE_MAE" | bc -l)" = "1" ]; then
	ok "MAE $MAE beats the predict-the-mean baseline of $BASELINE_MAE"
else
	bad "MAE $MAE is no better than the $BASELINE_MAE baseline -- the model adds nothing"
fi

echo "-- GaiaQualityScored (what the analysis layer reads)"

# The table, not the file. Gaia.Source.Ready() refuses a partially-scored table,
# so a run that wrote a complete CSV from an incomplete table would leave the
# reports unable to run and nothing else would notice.
# The table's columns are pred_reject and pred_sigma -- quality.csv renames them to
# predicted_reject_fraction and prediction_sigma on the way out. Two names for one
# value, and a probe written from the CSV header fails with SQLCODE -29 rather than
# a count mismatch, which reads as a broken pipeline when it is a broken test.
#
# `AS cnt` is required, not decoration: a dynamic result exposes columns only as
# properties (there is no %GetData or %Get on %SQL.StatementResult), and an
# aggregate aliased without AS is not exposed at all.
PROBE=$(printf 'set rs=##class(%%SQL.Statement).%%ExecDirect(,"SELECT COUNT(*) AS cnt, COUNT(pred_reject) AS scored, COUNT(pred_sigma) AS sigmas FROM SQLUser.GaiaQualityScored")\ndo rs.%%Next()\nwrite "SCORED=",rs.cnt,"/",rs.scored,"/",rs.sigmas,!\nwrite "SQLCODE=",rs.%%SQLCODE,!\nhalt\n' \
	| docker exec -i "$CONTAINER" iris session IRIS -U USER 2>&1)
want "the probe query is valid" \
	"$(printf '%s' "$PROBE" | sed -n 's/^SQLCODE=\(.*\)/\1/p' | tr -d '\r' | head -1)" "0"
want "the table holds every source, both heads scored" \
	"$(printf '%s' "$PROBE" | sed -n 's/^SCORED=\([0-9/]*\).*/\1/p' | head -1)" \
	"$WANT_QUALITY_ROWS/$WANT_QUALITY_ROWS/$WANT_QUALITY_ROWS"

echo
if [ "$FAIL" -eq 0 ]; then
	echo "PASS: gaia-iml e2e ($WANT_ROWS detections, $WANT_QUALITY_ROWS scored, MAE $MAE, ${ELAPSED}s)"
else
	echo "FAIL: gaia-iml e2e"
fi
exit "$FAIL"
