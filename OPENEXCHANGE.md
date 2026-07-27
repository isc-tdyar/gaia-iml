# OpenExchange Submission Draft

Not submitted. Registration at <https://openexchange.intersystems.com/> is a
manual form per app; this file holds the field values so the three entries stay
consistent when they are entered.

All three repos must be pushed to `github.com/isc-tdyar/<name>` before
submitting: OEX reads the manifest and README from the public default branch.

## gaia-iml

- **Name:** gaia-iml
- **Repository:** <https://github.com/isc-tdyar/gaia-iml>
- **Version:** 1.0.0
- **License:** MIT
- **Category:** Machine Learning / Analytics
- **Tags:** IntegratedML, custom-models, AI-Hub, gaia, variable-stars,
  astronomy, embedded-python, PREDICT, NGBoost, machine-learning
- **Short description:** Gaia DR3 variable star detection using IntegratedML
  Custom Models. Scans 20 gzipped epoch photometry files, ingests
  flux and per-epoch quality statistics into IRIS, then scores every source with
  SQL `PREDICT()` against two custom NGBoost `IRISModel` regressors predicting
  ESA's own epoch reject fraction and its uncertainty. ~11s end-to-end. Four AI
  Hub reports then read the scored table back, including recursive language
  models that never put a row in a prompt.
- **What to state on the listing:** two layers, both first-class. The pipeline is
  `^RunScript`, the two IntegratedML models, `result.csv` and `quality.csv`. On
  top of it sit four AI Hub entry points (`^Analyze`, `^RLMAudit`, `^RLMTriage`,
  `^RLM2Audit`); `^RLMAudit` and `^RLMTriage` run `rlm-core`'s recursive engine
  over 74,998 scored sources on aggregate statistics alone, and `^RLM2Audit`
  answers the same question with the model owning the recursion instead, so the
  two are comparable.

  The `Dockerfile` default is the 2026.3 AI preview community image, so both
  layers work with no flags for anyone who has it: ISC employees from
  `docker.iscinternal.com`, everyone else from the evaluation tarball. Also state
  the fallback: one `--build-arg IMAGE=…iris-community:2026.1` runs the whole
  contest pipeline on the public image with no login, no VPN and no license key,
  where `Gaia.Install` skips the analysis classes and prints which ones. Both
  paths pass `tests/e2e.sh` 23/23, in 10.7s and 11.3s, and `result.csv` is
  byte-identical. `quality.csv` is not, because NGBoost's build-time fit is not
  bit-reproducible across builds on either image; MAE holds at 0.0432. Do not
  promise a prediction checksum on the listing.

## gaia-fast

- **Name:** gaia-fast
- **Repository:** <https://github.com/isc-tdyar/gaia-fast>
- **Version:** 1.0.0
- **License:** MIT
- **Category:** Performance / Data Processing
- **Tags:** gaia, variable-stars, astronomy, embedded-python, performance,
  parallel, isal
- **Short description:** Gaia DR3 variable star detection, speed entry. `isal`
  SIMD-accelerated inflate plus `ProcessPoolExecutor` over 20 gzipped epoch
  photometry files, streamed in 4 MB chunks. 57,099 variable sources in under a
  second. Public `iris-community` image, no login required.

## gaia-terse

- **Name:** gaia-terse
- **Repository:** <https://github.com/isc-tdyar/gaia-terse>
- **Version:** 1.0.0
- **License:** MIT
- **Category:** Embedded Python / Curiosities
- **Tags:** gaia, variable-stars, minimal-code, embedded-python, astronomy,
  one-liner
- **Short description:** Gaia DR3 variable star detection in one
  `$SYSTEM.Python.Run()` call holding a 580-character stdlib-only expression.
  No `.py` file, no pip install. 57,099 sources in ~16s.

## Pre-submission checks

Done for all three:

- `zpm load <repo>` succeeds on `intersystemsdc/iris-community:2026.1`, and
  `^RunScript` is compiled and callable afterwards. Run it with
  `gaia-iml/tests/zpm_install.sh`.

  This check was listed as done here before it had ever run. None of the three
  project containers has IPM installed at all. `%IPM.Main` and
  `%ZPM.PackageManager` are both absent from the AI-preview and the project
  images, so every earlier claim about `zpm load` was inference from reading the
  manifests. Running it for real on a public community image passed `gaia-fast`
  and `gaia-terse` and failed `gaia-iml` twice over: an unresolvable `rlm-core`
  dependency aborted the load before compiling anything, and with that removed
  six classes failed on `%AI.Agent`/`RLM.Source.Table` not existing, taking
  `^RunScript` down with them. `Gaia.Install` now gates the analysis layer, and
  the gate script is the regression test.

- `module.xml` declares Name, Version, Author, License, SourcesRoot, Resources,
  Keywords
- **The three cannot be installed into one namespace at once.** All three ship
  `RunScript.MAC`, and IPM refuses a second claim on a resource:

  ```text
  ERROR #5001: Resource 'RunScript.MAC' is already defined as part of module 'gaia-fast'
  ```

  That is correct behaviour, since they are three answers to one challenge
  rather than components, but it is worth one line on each listing so nobody
  reads it as a broken package.

- MIT `LICENSE` present
- README covers prerequisites, data download, quick start, output format
- `markdownlint-cli2` and `prettier` clean
- No credentials in tracked files, no tracked file over 1 MB
- `do ^RunScript` verified end to end on the 20-file benchmark; all three emit
  the same 57,099 `source_id`s
- Each repo has `tests/e2e.sh`, run from a `--no-cache` rebuild rather than a
  long-lived container. gaia-fast 12 checks in 0.84s, gaia-terse 13 in 16.6s,
  gaia-iml 23 in 11.0s. All three assert the same literal checksum of the
  `source_id` set, so the cross-entry agreement is a test rather than a claim.
  gaia-iml's 23 checks were re-run from a fresh `git clone --recursive` on the
  public `iris-community:2026.1` image: all 23 pass, 57,099 detections, 74,998
  scored, MAE 0.0432, 10.6s. gaia-iml also has the `%UnitTest` suite and the IPM
  gate, but the `%UnitTest` suite covers the optional analysis layer and needs
  the AI preview image: three of its six classes do not compile on the public
  one.

  Writing these found a real defect. Both NGBoost models were training
  unseeded: AutoML passes `random_state=None` explicitly, so
  `kwargs.get("random_state", 42)` never returned 42, and AutoML's own
  `df.sample(frac=1, random_state=...)` shuffle was unseeded too. Every
  `docker build` produced a slightly different model. Accuracy was unaffected
  (MAE 0.0432 both times) which is why nothing caught it: it showed up only
  as bucket populations moving by ~0.05%. Both are now pinned.

Still outstanding:

- Article on Developer Community, then link it from each listing
- Demo video, then link it from each listing
