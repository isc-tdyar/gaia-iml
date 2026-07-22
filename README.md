# Gaia Variable Star Detector — Employee Programming Challenge #1

**Kitchen-sink entry**: IntegratedML PREDICT() + custom IRISModel + AI Hub image.

## Bonuses targeted

- **+3 Python bonus**: pipeline runs entirely via `irispython` (`run_embedded_iml.py`)
- **+3 AI Hub bonus**: base image is the ISC AI Hub build (`irishealth:2026.3.0AI`)

## How it works

1. `docker build` pulls the AI Hub IRIS image, installs `intersystems-iris-automl` and `isal`.
2. `10_compile_runscript.sh` compiles `RunScript.mac` into IRIS at container first-start.
3. `05_pretrain_gaia_model.py` trains `GaiaVariability` on 2500 synthetic stars so
   the model is **ready before contest time** — no 33s training hit during judging.
4. At contest: `do ^RunScript` sets env vars and shells out to `irispython`.
5. `run_embedded_iml.py` decompresses `.gz` files in parallel, ingests flux stats into
   `GaiaFluxStats`, calls `PREDICT(GaiaVariability)` via IntegratedML SQL, and writes
   `result.csv` with variable-star rows sorted by `pct_change DESC`.

## Custom IRISModel

`gaia_variability_iris_model.py` supplies a `GradientBoostingClassifier` wrapped in
the `IRISModel` contract expected by `iris_automl`. IntegratedML selects it via
`USING {"iscmodelsdisabled":1, "pathtoclassifiers":"..."}`.

## Quick start

```bash
cp /path/to/EpochPhotometry*.gz .data/in/
docker compose up --build
docker exec gaia-iml-iris iris session IRIS -U USER "do ^RunScript"
cat .data/out/result.csv
```
