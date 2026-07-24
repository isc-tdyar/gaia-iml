# Gaia DR3 Variable Star Detection — IntegratedML + AI Hub Entry

InterSystems Employee Programming Challenge #1

Detects variable stars in Gaia DR3 epoch photometry using **IntegratedML Custom
Models** running inside IRIS via AI Hub. Scans 21 gzipped epoch photometry files,
ingests flux statistics into a SQL table, then scores each source with a single
`PREDICT()` call backed by a custom `GradientBoostingClassifier` IRISModel.

**~5 seconds** end-to-end. Targets Python (+3) and AI Hub (+3) contest bonuses.

**Note:** This entry uses an ISC-internal Docker image (`docker.iscinternal.com`).
It is intended for ISC employees participating in the Employee Programming
Challenge. External contestants cannot pull the image without ISC network/VPN
access.

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
trained at **container init** on synthetic data
(`docker-entrypoint-initdb.d/05_pretrain_gaia_model.py`). At runtime,
`run_embedded_iml.py` checks `INFORMATION_SCHEMA.ML_TRAINED_MODELS` and skips
training if the model already exists.

## Prerequisites

- ISC network or VPN access (required to pull the AI Hub image)
- Docker + Docker Compose installed
- 16 GB RAM recommended (8 GB minimum)
- ~30 GB free disk space (image + data)
- Internet access for data download (~10 GB)

## Get the Data

Download Gaia DR3 EpochPhotometry bulk files from the ESA archive:

```bash
mkdir -p .data/in
cd .data/in

# Download 21 files (~480 MB each compressed)
for i in $(seq -w 1 21); do
  wget "https://cdn.gea.esac.esa.int/Gaia/gdr3/Photometry/EpochPhotometry/EpochPhotometry_${i}.csv.gz"
done
cd ../..
```

Expected: 21 files, ~480 MB each compressed, ~10 GB total.

## Quick Start

Requires the AI Hub IRIS image (`2026.3.0AI.113.0`). Set `IRIS_IMAGE` in your
environment or use the Dockerfile default.

```bash
# Place Gaia EpochPhotometry .gz files in .data/in/
docker compose up --build -d
docker exec gaia-iml-iris iris session IRIS -U USER "do ^RunScript"
cat .data/out/result.csv | head -5
```

## Output Format

```csv
source_id,bp_min_flux,bp_max_flux,rp_min_flux,rp_max_flux,percentage_change
94494163890456704,0.000000,153710.892478,22.176222,171140.910128,1258654236473444.0000
...
```

Typical result: ~57,100 variable sources, `percentage_change` range from ~100%
to >10^21%.

## Article

See [ARTICLE.md](ARTICLE.md) for a full write-up: IRISModel contract, data
description, 4-step pipeline, pre-training strategy, three common gotchas, and
performance table.

## Related Entries

- [gaia-fast](https://github.com/isc-tdyar/gaia-fast) — isal +
  ProcessPoolExecutor, ~1s, no IntegratedML
- [gaia-golf](https://github.com/isc-tdyar/gaia-golf) — 580-char
  `$SYSTEM.Python.Run()` one-liner, ~17s
