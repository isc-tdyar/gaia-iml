# Gaia DR3 Variable Star Detection: IntegratedML Entry

InterSystems Employee Programming Challenge #1

Detects variable stars in Gaia DR3 epoch photometry using **IntegratedML Custom
Models** running inside IRIS. Scans 20 gzipped epoch photometry files,
ingests flux and quality statistics into SQL tables, then scores every source with
`PREDICT()` calls backed by two custom `IRISModel` files: NGBoost heads
predicting data quality and its uncertainty.

**~11 seconds** end-to-end. Targets the Python (+3) and AI Hub (+3) contest
bonuses.

On top of that, four **AI Hub** reports read the scored table back: `^Analyze`
interprets a fixed aggregate panel, and `^RLMAudit`, `^RLMTriage` and `^RLM2Audit`
run recursive language models over 74,998 scored sources without ever putting a
row in a prompt. See [The AI Hub analysis layer](#the-ai-hub-analysis-layer).

The default image is the 2026.3 AI preview community build, which carries both
halves, so every command below works with no flags. ISC employees pull it from
`docker.iscinternal.com`; everyone else downloads the tarball from
<https://evaluation.intersystems.com>.

Without that image the contest pipeline still runs in full on the public
`iris-community:2026.1` — no login, no VPN, no license key. `Gaia.Install` skips
the analysis classes and names them; `^RunScript` and `result.csv` are unaffected,
and `tests/e2e.sh` passes 23/23 on either image. See
[Building without AI Hub](#building-without-ai-hub).

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

## Prerequisites

- Docker + Docker Compose installed.
- The 2026.3 AI preview community image, the default base. ISC employees pull it
  from `docker.iscinternal.com`; everyone else downloads the tarball from
  <https://evaluation.intersystems.com> and `docker load`s it. Not needed for the
  contest pipeline alone — see [Building without AI Hub](#building-without-ai-hub),
  which requires no login, no VPN and no license key.
- `OPENAI_API_KEY` for the four analysis reports. The pipeline does not use it.
- 16 GB RAM recommended (8 GB minimum)
- ~10 GB free disk space (image + data)
- Internet access for data download (~360 MB)

## Quick Start

Five steps, from nothing to `result.csv` and the analysis reports.

```bash
git clone --recursive https://github.com/isc-tdyar/gaia-iml.git
cd gaia-iml
```

`--recursive` matters: the optional RLM analysis classes extend
[rlm-core](https://github.com/isc-tdyar/rlm-iris), which arrives as a submodule
at `lib/rlm-core`. If you already cloned without it, run
`git submodule update --init`.

**1. Get the data.** The benchmark is the first 20 EpochPhotometry files from
the Gaia DR3 archive, `EpochPhotometry_000000-003111` through
`EpochPhotometry_020985-021233`. The archive's object store answers a bucket
listing at the `?prefix=...&delimiter=/` query form and returns S3
`ListBucketResult` XML, so the file names come out of `<Key>` elements:

```bash
mkdir -p data/in && cd data/in
BASE=https://gaia.eu-1.cdn77-storage.com
PREFIX=Gaia/gdr3/Photometry/epoch_photometry/
curl -s "$BASE/?prefix=$PREFIX&delimiter=/" \
  | grep -oE '<Key>[^<]*EpochPhotometry_[0-9]+-[0-9]+\.csv\.gz</Key>' \
  | sed -E 's:</?Key>::g' | sort | head -20 \
  | xargs -P 8 -I{} curl -sO "$BASE/{}"
cd ../..
ls data/in/*.csv.gz | wc -l   # expect 20
```

Expected: 20 files, ~360 MB total, 74,998 sources. Allow several minutes.

Do not fetch the bare directory URL
(`https://cdn.gea.esac.esa.int/Gaia/gdr3/Photometry/epoch_photometry/`) — it is
an object store, not a web server, and answers `301` with an empty body, so a
`grep` for file names over it silently yields zero files and the download step
appears to succeed while downloading nothing.

**2. Build and start IRIS.** `--wait` is not optional: IRIS takes several
seconds to come up after the container does, and without it the `docker exec` on
the next line runs against an instance that is not accepting connections yet.
The `healthcheck:` in `docker-compose.yml` is what `--wait` waits on.

```bash
docker compose up --build -d --wait
```

**3. Run the pipeline.**

```bash
docker exec gaia-iml-iris bash -c \
  'printf "do ^RunScript\nhalt\n" | iris session IRIS'
```

**4. Look at the answer.**

```bash
head -5 data/out/result.csv
head -5 data/out/quality.csv
```

**5. Read the analysis.** The four AI Hub reports need `OPENAI_API_KEY` in the
environment; they sit outside `^RunScript` because LLM latency is not ours to
control.

```bash
docker exec -i gaia-iml-iris iris session IRIS -U USER <<'EOF'
do ^Analyze
do ^RLMAudit
halt
EOF
head -40 data/out/rlm_audit.md
```

The base image is the 2026.3 AI preview community build. Override it with
`docker compose build --build-arg IMAGE=<your tag>` — see
[Building without AI Hub](#building-without-ai-hub).

### Installing with IPM

```objectscript
zpm "load /path/to/gaia-iml"
```

Docker is the supported route, and the only one that gets a full run: `^RunScript`
shells out to `irispython` against fixed paths under `/home/irisowner/dev`, which
an IPM install does not create. What `zpm load` gives you is the routines and the
models on an instance you already have.

On an image without AI Hub or `lib/rlm-core` — see
[Building without AI Hub](#building-without-ai-hub) — the install compiles
`^RunScript` and prints what it left out:

```text
[gaia-iml] analysis layer skipped: %AI.Agent, %AI.Tool, RLM.Source.Table,
  RLM.Slice not present on this instance.
```

`Gaia.Install` decides that at activation. `module.xml` deliberately does not list
`Gaia.PKG` — six classes there extend `%AI.Agent`, `%AI.Tool` or
`RLM.Source.Table`, and listing the package makes the whole module fail to install
on any stock image, `^RunScript` included, for the sake of a bonus feature.
`tests/zpm_install.sh` is the check, run against
`intersystemsdc/iris-community:2026.1`.

Nor does it declare a `<Dependencies>` entry for `rlm-core`: the library is not
published to a registry, so naming it aborts the load before a line is compiled.
The submodule above is how it arrives.

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

## Tests

```bash
tests/e2e.sh          # the pipeline, end to end
tests/zpm_install.sh  # the IPM install, on a stock community image
```

`e2e.sh` deletes both outputs, runs `^RunScript`, and checks `result.csv` the
way a judge would — 20 inputs, header, 57,099 rows, descending sort, the 100%
threshold, duplicates, `min <= max`, and the `source_id` checksum shared with
[gaia-fast](https://github.com/isc-tdyar/gaia-fast) and
[gaia-terse](https://github.com/isc-tdyar/gaia-terse).

Most of it is about `quality.csv`, because `result.csv` being right says nothing
about the ML: it comes from a `WHERE` clause. So the tests assert that all
74,998 sources are scored and not just the 57,099 detections, that predictions
vary (a constant-output model passes every count-based check), that every
`prediction_sigma` is positive, and that MAE recomputed from the file beats the
0.0613 predict-the-mean baseline. Then a SQL probe checks
`SQLUser.GaiaQualityScored` directly, since a complete CSV written from a
partially-scored table would leave the agents unable to run and nothing else
would notice.

The four analysis entry points are not in `e2e.sh` — they make LLM calls, which
is why they sit outside `^RunScript`. Their logic is covered by a `%UnitTest`
suite against a null provider:

```bash
docker exec -i gaia-iml-iris iris session IRIS -U USER <<'EOF'
do ##class(%UnitTest.Manager).RunTest("Gaia",,"ck")
halt
EOF
```

`Gaia`, not `UnitTest.Gaia`: `iris.script` sets `^UnitTestRoot` to
`/home/irisowner/dev/src/UnitTest`, so the argument is a path below it and the
fuller name resolves to `src/UnitTest/UnitTest/Gaia`, which does not exist. The
`"ck"` qualifier is required — without it the classes are found but never
compiled.

All six classes compile and run on the default image. On the public-image
fallback, three of them (`UnitTest.Gaia.Source`, `UnitTest.Gaia.RLM2`,
`UnitTest.Gaia.SourceCounts`) fail to compile on `Gaia.Source`/`Gaia.RLM2` not
existing and `RunTest` reports the suite as failed. That is expected there and
says nothing about the contest pipeline — `tests/e2e.sh` covers `^RunScript` and
both IntegratedML models, and it passes on either image.

## The AI Hub analysis layer

`^RunScript` produces the challenge answer. This layer reads it back: 74,998
scored sources are a table no one wants to read, and the interesting question —
_where is the photometry bad, and why_ — is not one a `WHERE` clause asks.

It runs on the default image. All four entry points need `OPENAI_API_KEY` in the
environment, and all four are kept out of `^RunScript` because LLM latency is not
ours to control:

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

## Building without AI Hub

The contest pipeline runs in full on the public community image, which needs no
InterSystems login, no VPN and no license key:

```bash
docker compose build \
  --build-arg IMAGE=containers.intersystems.com/intersystems/iris-community:2026.1
docker compose up -d --wait
```

That image carries embedded Python, IntegratedML and the `%ML.AutoML.Provider`
the custom `IRISModel` regressors plug into — everything `^RunScript` needs. What
it lacks is `%AI.Agent` and `%AI.Tool`, so `Gaia.Install` skips the six analysis
classes at activation and names what it skipped:

```text
[gaia-iml] analysis layer skipped: %AI.Agent, %AI.Tool, RLM.Source.Table,
  RLM.Slice not present on this instance.
```

`tests/e2e.sh` passes 23/23 either way, in 11.3s against 10.7s, and `result.csv`
is byte-identical: it comes from a `WHERE` clause, so nothing about the image can
move it. The four report entry points are absent rather than broken — a skip that
names the classes it dropped, not a stack trace.

`quality.csv` is not byte-identical, and not because of the image. NGBoost's fit
runs at `docker build` time and is not bit-reproducible across builds even with
`random_state=42` fixed: two builds of the _same_ image disagree on 1,900 of
74,998 predictions, mean absolute difference 0.00005 and worst case 0.0157. MAE
holds at 0.0432 either way. If you need the exact same numbers twice, keep the
image rather than rebuilding it.

Deciding that at activation is why `module.xml` does not list `Gaia.PKG`: naming
the package would make the whole module fail to install on a stock image,
`^RunScript` included, for the sake of the analysis layer.

## Article

See [ARTICLE.md](ARTICLE.md) for the full write-up: IRISModel contract, data
description, the pipeline, pre-training, four gotchas, measured performance, the
RLM agent, and codebase graph tooling.

## Related Entries

- [gaia-fast](https://github.com/isc-tdyar/gaia-fast): isal +
  ProcessPoolExecutor, ~1s, no IntegratedML
- [gaia-terse](https://github.com/isc-tdyar/gaia-terse): 580-char
  `$SYSTEM.Python.Run()` one-liner, ~16s
