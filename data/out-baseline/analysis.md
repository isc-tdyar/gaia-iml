## Analysis
In this run, a total of 74,998 sources were analyzed from the Gaia DR3 dataset. The model identified 35,747 sources as variable. However, there is a notable discrepancy between the heuristic and model classifications: 24,151 sources were labeled as variable by the heuristic but not by the model, while the model predicted 2,799 sources as variable that were not classified by the heuristic.

Among the variable sources, there are concerning extreme values in the flux swing statistics. A staggering 57,099 sources exhibit a minimum percent change greater than 100%, with an extraordinarily high average percent change of approximately 90 billion, raising questions about the physical significance of these changes.

### Likely artifacts
Quantifying potential contamination from instrument-related effects:
- **800 sources** exhibited near-zero minimum flux (either `bp_min` or `rp_min` below 1), leading to inflated `pct_change` calculations.
- **82 sources** had very few usable epochs (fewer than 5 in either BP or RP band), suggesting that a single bad epoch could significantly influence their variability assessment.

### Method
The figures presented are based on SQL aggregate queries in which `PREDICT(GaiaVariability)` was evaluated inline, highlighting variable sources from the `SQLUser.GaiaFluxStats` table.