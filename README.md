# Gaia DR3 Variable Star Detection — IntegratedML + AI Hub Entry

InterSystems Employee Programming Challenge #1

Detects variable stars in Gaia DR3 epoch photometry using **IntegratedML Custom
Models** running inside IRIS via AI Hub. Scans 21 gzipped epoch photometry files,
ingests flux statistics into a SQL table, then scores each source with a single
`PREDICT()` call backed by a custom `GradientBoostingClassifier` IRISModel.

**~5 seconds** end-to-end. Targets Python (+3) and AI Hub (+3) contest bonuses.

## How It Works

1. `do ^RunScript` → `irispython run_embedded_iml.py`
2. Parallel binary scan extracts BP/RP flux arrays from 21 `.gz` files
3. Inserts 57,101+ rows into `GaiaFluxStats` with flux stats + `is_variable` label
4. `PREDICT(GaiaVariability)` scores every row using the pre-trained GBT model
5. Writes `result.csv` — only ML-confirmed variable sources, sorted by `pct_change`

## The Custom IRISModel

```python
# gaia_variability_iris_model.py
from sklearn.ensemble import GradientBoostingClassifier

class IRISModel:
    def __init__(self, **kwargs):
        self.name  = "gaia_epoch_variability_detector"
        self.model = GradientBoostingClassifier(
            n_estimators=int(kwargs.get("n_estimators", 100)),
            max_depth=int(kwargs.get("max_depth", 3)),
        )
        # Do NOT implement fit() or predict() — IntegratedML calls self.model directly
```

Registered via `CREATE MODEL ... USING {"iscmodelsdisabled":1, "pathtoclassifiers":"/app"}`.

## Pre-Training Strategy

Training takes ~33s. To avoid paying that cost at `RunScript` time, the model is
trained at **container init** on synthetic data (`docker-entrypoint-initdb.d/05_pretrain_gaia_model.py`).
At runtime, `run_embedded_iml.py` checks `INFORMATION_SCHEMA.ML_TRAINED_MODELS` and skips training
if the model already exists.

## Quick Start

Requires the AI Hub IRIS image (`2026.3.0AI.113.0`). Set `IRIS_IMAGE` in your environment or
use the Dockerfile default.

```bash
# Place Gaia EpochPhotometry .gz files in .data/in/
docker compose up --build -d
docker exec gaia-iml-iris iris session IRIS -U USER "do ^RunScript"
cat .data/out/result.csv | head -5
```

## Output Format

```
source_id,bp_min_flux,bp_max_flux,rp_min_flux,rp_max_flux,percentage_change
94494163890456704,0.000000,153710.892478,22.176222,171140.910128,1258654236473444.0000
...
```

57,101 variable sources from 21 files.

## Article

See [ARTICLE.md](ARTICLE.md) for a full write-up: IRISModel contract, data description,
4-step pipeline, pre-training strategy, three common gotchas, and performance table.

## Related Entries

- [gaia-fast](https://github.com/isc-tdyar/gaia-fast) — isal + ProcessPoolExecutor, ~1s, no IntegratedML
- [gaia-golf](https://github.com/isc-tdyar/gaia-golf) — 580-char `$SYSTEM.Python.Run()` one-liner, ~17s
