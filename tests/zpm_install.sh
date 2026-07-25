#!/usr/bin/env bash
#
# Gate: `zpm load` must succeed on a public community image, where none of the
# optional analysis layer's dependencies exist.
#
# This is the check an OpenExchange reviewer performs, and it is the one that was
# claimed as done and was not: the three project containers ship no package
# manager at all, so `zpm load` had never been run against any of these
# manifests. It failed twice when it finally was -- an unresolvable `rlm-core`
# dependency, then `%AI.Agent does not exist` on every class that extends it.
#
# What must hold on the community image:
#   1. the load reports SUCCESS, not ERROR
#   2. ^RunScript -- the contest entry point, and the only thing a judge runs --
#      is compiled and callable
#   3. the analysis layer is skipped out loud, naming what was missing, rather
#      than failing the install or silently going absent
#
# Usage: tests/zpm_install.sh [image]
set -euo pipefail

IMAGE="${1:-intersystemsdc/iris-community:2026.1}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
NAME="gaia-iml-zpm-gate-$$"
FAIL=0

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

check() {
	if printf '%s' "$2" | grep -qF -- "$3"; then
		echo "  ok   $1"
	else
		echo "  FAIL $1 (expected to find: $3)"
		FAIL=1
	fi
}

refute() {
	if printf '%s' "$2" | grep -qF -- "$3"; then
		echo "  FAIL $1 (found: $3)"
		FAIL=1
	else
		echo "  ok   $1"
	fi
}

echo "== zpm load gate on $IMAGE"
docker run --rm -d --name "$NAME" "$IMAGE" >/dev/null

# The image is not ready the moment the container is. Poll rather than sleep a
# guessed interval, or a slow machine reads as a failed gate.
for _ in $(seq 1 60); do
	if docker exec "$NAME" iris session IRIS -U USER </dev/null >/dev/null 2>&1; then break; fi
	sleep 2
done

# Ship the working tree, not a git archive: the point is to test what someone
# gets, and what they get from IPM has no submodule in it. `lib/rlm-core` is
# excluded deliberately -- its absence is the condition under test.
docker exec "$NAME" mkdir -p /tmp/gaia-iml
tar -c -C "$REPO" --exclude lib --exclude .git --exclude data --exclude __pycache__ . \
	| docker exec -i "$NAME" tar -x -C /tmp/gaia-iml 2>/dev/null

OUT=$(printf 'zpm "load /tmp/gaia-iml -v"\nhalt\n' \
	| docker exec -i "$NAME" iris session IRIS -U USER 2>&1)

echo "$OUT" | grep -E "SUCCESS|FAILURE|ERROR|skipped|Gaia" || true
echo "-- assertions"

check   "load activates the module"          "$OUT" "Activate SUCCESS"
refute  "no compile failure"                 "$OUT" "Compile FAILURE"
refute  "rlm-core is not demanded of IPM"    "$OUT" "Could not find satisfactory version"
# Matched by error code, not by the phrase "does not exist": IPM prints
# "Skipping preload - directory does not exist" on every clean load, so the
# phrase alone fails a passing install. #5373 is the superclass error itself.
refute  "no missing-superclass error"        "$OUT" "ERROR #5373"
check   "the skip is announced"              "$OUT" "analysis layer skipped"

# The contest path itself. A module that installs but leaves ^RunScript
# uncallable passes every string check above and is still worthless.
PROBE=$(printf 'write "RUNSCRIPT=",##class(%%Library.Routine).Exists("RunScript.OBJ"),!\nhalt\n' \
	| docker exec -i "$NAME" iris session IRIS -U USER 2>&1)
check   "^RunScript is compiled"             "$PROBE" "RUNSCRIPT=1"

echo
if [ "$FAIL" -eq 0 ]; then
	echo "PASS: gaia-iml installs on $IMAGE"
else
	echo "FAIL: gaia-iml does not install cleanly on $IMAGE"
fi
exit "$FAIL"
