# Gaia DR3 Variable Star Detection: IntegratedML + AI Hub Entry

InterSystems Employee Programming Challenge #1

Detects variable stars in Gaia DR3 epoch photometry using **IntegratedML Custom
Models** running inside IRIS via AI Hub. Scans 20 gzipped epoch photometry files,
ingests flux and quality statistics into SQL tables, then scores every source with
`PREDICT()` calls backed by three custom `IRISModel` files: a
`GradientBoostingClassifier` for variability and two NGBoost heads for data
quality.

**~11 seconds** end-to-end. Targets Python (+3) and AI Hub (+3) contest bonuses.

**Note:** This entry uses an ISC-internal Docker image (`docker.iscinternal.com`).
It is intended for ISC employees participating in the Employee Programming
Challenge. External contestants cannot pull the image without ISC network/VPN
access.

## How It Works

1. `do ^RunScript` → `irispython run_embedded_iml.py`
2. Parallel streaming scan extracts BP/RP flux, flux-error and ESA reject-flag
   arrays from 20 `.gz` files
3. Inserts 74,998 rows into `GaiaFluxStats` and `GaiaQualityStats`
4. `PREDICT(GaiaVariability)` scores every row using the pre-trained GBT model
5. Writes `result.csv`: every source with `pct_change > 100`, sorted descending
6. `PREDICT(GaiaDataQuality)` and `PREDICT(GaiaQualityUncertainty)` write
   `quality.csv` and materialize `GaiaQualityScored`

`result.csv` comes from the deterministic rule. The variability model reproduces
that rule at 57.7% recall, so filtering on it would emit a wrong answer. The
prediction is reported next to the rule instead.

## The Custom IRISModels

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
        # Do NOT implement fit() or predict(). IntegratedML calls self.model directly.
```

Registered via `CREATE MODEL ... USING {"iscmodelsdisabled":1,
"pathtoclassifiers":"<automl_root>/Classifiers/gaia_variability"}`. The quality
models use `pathtoregressors` instead: classification and regression candidates
come from separate pools, and a numeric target never looks in the classifier pool.

The NGBoost pair predicts `reject_fraction`, the share of a source's epochs that
ESA's own variability pipeline rejected. Unlike `is_variable` that target is not
derivable from the features, so there is something real to learn. MAE 0.0432
against 0.0613 for predicting the mean, 30% better, with a per-row error bar from
the sigma head.

## Pre-Training Strategy

Training all three models takes ~33s, paid once at `docker build` time by
`pretrain_gaia_model.py`. `GaiaVariability` trains on 2,500 synthetic rows;
the quality models train on `quality_train.csv.gz`, a real 5,344-source extract.
At runtime `run_embedded_iml.py` checks `INFORMATION_SCHEMA.ML_TRAINED_MODELS` and
skips training.

## AI Hub Agents

Four optional entry points, all kept out of `^RunScript` because LLM latency is
not ours to control:

| Command         | Output                   | What it does                    |
| --------------- | ------------------------ | ------------------------------- |
| `do ^Analyze`   | `data/out/analysis.md`   | Fixed aggregates, one LLM call  |
| `do ^RLMAudit`  | `data/out/rlm_audit.md`  | RLM: where photometry is bad    |
| `do ^RLMTriage` | `data/out/rlm_triage.md` | Same engine, variable detection |
| `do ^RLM2Audit` | `data/out/rlm2_audit.md` | Same audit, model-driven RLM    |

`Gaia.Analyst` runs a fixed set of aggregate queries, several of which call
`PREDICT(GaiaVariability)` inline, then asks the agent once to interpret them.

`Gaia.RLM` is a recursive language model over `GaiaQualityScored`. The data is
never placed in a prompt: each call receives only aggregate statistics for its
own slice, so context size is independent of table size. The model picks a
decomposition key from a fixed whitelist and the class owns the SQL predicates,
so there is no injection surface. Bounded at depth 3 and 18 LLM calls.

`Gaia.RLM2` answers the same audit question with the decomposition on the other
side. `Gaia.RLM` only ever asks the model which key to split by and decides the
rest in ObjectScript; `Gaia.RLM2` shows it the slice menu and lets it name the
slices, then hands each one to a `%AI.Agent.SubAgent` that peeks, sub-slices if
the spread warrants it, and returns a paragraph. `Gaia.RLM`'s cost is knowable
before the first call and every run has the same shape; `Gaia.RLM2`'s plan differs
run to run and is only bounded, at 6 delegations. 36s for the full audit.

Both keep the data out of the prompt, and in both the SQL predicates belong to
ObjectScript: `Gaia.Slice` resolves a name like
`reject_level:severe/epoch_count:few` against the same whitelist, so a model can
name a slice but cannot express a predicate. The plan is filtered against that
whitelist and truncated to the budget before the first spawn, not refused after
the last one, which is what `UnitTest.Gaia.RLM2` tests without needing a provider.

The spawn is performed by ObjectScript rather than exposed to the root as a tool.
A `%AI.Tool` that makes its own LLM call returns empty when the agent loop
dispatches it, because tool execution goes through `%AI.ToolMgr.ExecuteTool` into
`$ZF(-6)` and the nested provider call does not return. The same subagent works
when called directly. Verified in `2026.3.0AI.126.0`.

Requires `OPENAI_API_KEY` in the environment. Without it these print the reason
and exit, leaving `result.csv` untouched.

## Prerequisites

- ISC network or VPN access (required to pull the AI Hub image)
- Docker + Docker Compose installed
- 16 GB RAM recommended (8 GB minimum)
- ~10 GB free disk space (image + data)
- Internet access for data download (~360 MB)

## Get the Data

Download Gaia DR3 EpochPhotometry bulk files from the ESA archive. The benchmark
is the first 20 archive files, `EpochPhotometry_000000-003111` through
`EpochPhotometry_020985-021233`:

```bash
mkdir -p data/in && cd data/in
curl -s https://cdn.gea.esac.esa.int/Gaia/gdr3/Photometry/epoch_photometry/ \
  | grep -oE 'EpochPhotometry_[0-9]+-[0-9]+\.csv\.gz' | sort -u | head -20 \
  | xargs -P4 -I{} curl -sO \
      "https://cdn.gea.esac.esa.int/Gaia/gdr3/Photometry/epoch_photometry/{}"
cd ../..
```

Expected: 20 files, ~360 MB total, 74,998 sources.

## Quick Start

```bash
# Place Gaia EpochPhotometry .gz files in data/in/
docker compose up --build -d
docker exec gaia-iml-iris bash -c \
  'printf "do ^RunScript\nhalt\n" | iris session IRIS'
head -5 data/out/result.csv
```

Override the base image with
`docker compose build --build-arg IMAGE=<your local tag>` if you pulled the AI
preview tarball from evaluation.intersystems.com instead.

## Output Format

`result.csv` is the challenge answer:

```csv
source_id,bp_min_flux,bp_max_flux,rp_min_flux,rp_max_flux,percentage_change
94494163890456704,0.000000,153710.892478,22.176222,171140.910128,1258654236473444007936.0000
```

`quality.csv` is the IntegratedML deliverable, one row per source with its
predicted reject fraction and error bar:

```csv
source_id,esa_reject_fraction,predicted_reject_fraction,prediction_sigma,n_bp,n_rp,percentage_change
```

57,099 variable sources, `percentage_change` from ~100% to >10^21%.

## Article

See [ARTICLE.md](ARTICLE.md) for the full write-up: IRISModel contract, data
description, the pipeline, pre-training, four gotchas, measured performance, the
RLM agent, and codebase graph tooling.

## Related Entries

- [gaia-fast](https://github.com/isc-tdyar/gaia-fast): isal +
  ProcessPoolExecutor, ~1s, no IntegratedML
- [gaia-golf](https://github.com/isc-tdyar/gaia-golf): 580-char
  `$SYSTEM.Python.Run()` one-liner, ~17s
