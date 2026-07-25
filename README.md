# Gaia DR3 Variable Star Detection: IntegratedML + AI Hub Entry

InterSystems Employee Programming Challenge #1

Detects variable stars in Gaia DR3 epoch photometry using **IntegratedML Custom
Models** running inside IRIS via AI Hub. Scans 20 gzipped epoch photometry files,
ingests flux and quality statistics into SQL tables, then scores every source with
`PREDICT()` calls backed by two custom `IRISModel` files: NGBoost heads
predicting data quality and its uncertainty.

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
4. Writes `result.csv`: every source with `pct_change > 100`, sorted descending
5. `PREDICT(GaiaDataQuality)` and `PREDICT(GaiaQualityUncertainty)` write
   `quality.csv` and materialize `GaiaQualityScored`

`result.csv` comes from the deterministic rule, not from a model. The challenge
asks for every source whose relative flux swing exceeds 100%, which SQL computes
exactly, so a model there could only approximate a known answer. The IntegratedML
work goes where a `WHERE` clause cannot reach.

## The Custom IRISModels

```python
# gaia_quality_mean_model.py
from gaia_quality_estimator import NGBoostQualityEstimator

class IRISModel:
    def __init__(self, **kwargs):
        self.name  = "gaia_data_quality_ngboost_mean"
        self.model = NGBoostQualityEstimator(
            n_estimators=int(kwargs.get("n_estimators", 300)),
            learning_rate=float(kwargs.get("learning_rate", 0.01)),
            predict_output="mean",
        )
        # Do NOT implement fit() or predict(). IntegratedML calls self.model directly.
```

Registered via `CREATE MODEL ... USING {"iscmodelsdisabled":1,
"pathtoregressors":"<automl_root>/Regressors/gaia_quality_mean"}`.
`pathtoregressors` for a numeric target, `pathtoclassifiers` for a categorical
one: the two candidate pools are separate, and a numeric target never looks in
the classifier pool. Each model gets its own subdirectory, because `load_models()`
imports every `.py` in the directory it is handed.

NGBoost is not scikit-learn compatible out of the box, which is the interesting
part: `gaia_quality_estimator.py` wraps it in a `fit`/`predict` shim, and that is
all IntegratedML needs.

The pair predicts `reject_fraction`, the share of a source's epochs that ESA's own
variability pipeline rejected. That target is not derivable from the features, so
there is something to learn: MAE 0.0432 against 0.0613 for predicting the mean,
30% better, with a per-row error bar from the sigma head.

## Pre-Training Strategy

Training both models takes ~33s, paid once at `docker build` time by
`pretrain_gaia_model.py`, from `quality_train.csv.gz`, a real 5,344-source
extract. At runtime the models are already trained, so `run_embedded_iml.py` goes
straight to `PREDICT()`.

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
`PREDICT(GaiaDataQuality)` inline, then asks the agent once to interpret them.

`Gaia.RLM` is a recursive language model over `GaiaQualityScored`. The data is
never placed in a prompt: each call receives only aggregate statistics for its
own slice, so context size is independent of table size. The model picks a
decomposition key from a fixed whitelist and the store owns the SQL predicates,
so there is no injection surface. Bounded at depth 3 and 18 LLM calls.

The recursion itself is not in this repository. `Gaia.RLM` is three
constructions of `RLM.Engine` from
[rlm-core](https://github.com/isc-tdyar/rlm-iris); what stays here is the domain
knowledge, and it is all in two classes:

- `Gaia.Source` extends `RLM.Source.Table`: six dimensions expanding to 22 slices,
  sixteen aggregates per peek, eleven lines of prose describing a slice, and a
  `>= 400`-row floor below which it declines to split.
- `Gaia.LLM.AIHub` implements `RLM.LLM`, and is the only class here that names
  `%AI.*`.
- `Gaia.RLM` holds the two questions, the two scopes, and where the reports go.

The recursion, the frontier, the call budget, the slice resolver, the trace and
the report assembly are all `rlm-core`'s.

Porting onto it removed 510 lines: `Gaia.RLM` went from 513 to 129, and
`Gaia.Slice` — a second copy of the slice grammar — was deleted outright.

`Gaia.RLM2` answers the same audit question with the decomposition on the other
side. `Gaia.RLM` only ever asks the model which key to split by and the engine
decides the rest; `Gaia.RLM2` shows it the slice menu and lets it name the
slices, then hands each one to a `%AI.Agent.SubAgent` that peeks, sub-slices if
the spread warrants it, and returns a paragraph. `Gaia.RLM`'s cost is knowable
before the first call and every run has the same shape; `Gaia.RLM2`'s plan differs
run to run and is only bounded, at 6 delegations. 36s for the full audit. It
keeps its own budget and trace deliberately: the model owns the recursion there,
so the library's engine has nothing to lend it, and it exists to be compared
against the engine.

Both keep the data out of the prompt, and in both the SQL predicates belong to
ObjectScript: `RLM.Slice` resolves a name like `reject_level:b3/epoch_count:b1`
against the dimensions `Gaia.Source` declares, so a model can name a slice but
cannot express a predicate. One resolver, one whitelist, one place a name can be
refused. The plan is filtered against that whitelist and truncated to the budget
before the first spawn, not refused after the last one, which is what
`UnitTest.Gaia.RLM2` tests without needing a provider.

The subagent is called from ObjectScript, once per planned slice, rather than
exposed to the root as a tool for its model to invoke. That path did not return
on the preview build used here once the child had tools of its own
([ai-hub-eap#26](https://github.com/intersystems-community/ai-hub-eap/issues/26)),
so the model chooses the decomposition and the spawn is explicit.

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

The RLM analysis classes extend [rlm-core](https://github.com/isc-tdyar/rlm-iris),
which arrives as a submodule at `lib/rlm-core`. Clone with it or nothing compiles:

```bash
git clone --recursive https://github.com/isc-tdyar/gaia-iml.git
# already cloned without it:
git submodule update --init
```

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
- [gaia-terse](https://github.com/isc-tdyar/gaia-terse): 580-char
  `$SYSTEM.Python.Run()` one-liner, ~16s
