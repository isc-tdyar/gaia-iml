"""
IRISModel for GaiaDataQuality: the NGBoost predictive *mean* of
`reject_fraction`. See gaia_quality_estimator.py for the target rationale, the
bake-off numbers and the calibration measurements.

Deployed to its own Regressors subdirectory and selected with:

    CREATE MODEL GaiaDataQuality PREDICTING (reject_fraction)
    WITH (n_bp NUMERIC, n_rp NUMERIC, bp_snr NUMERIC, rp_snr NUMERIC,
          bp_cv NUMERIC, rp_cv NUMERIC, bp_min NUMERIC, bp_max NUMERIC,
          rp_min NUMERIC, rp_max NUMERIC)
    FROM GaiaQualityStats
    USING {"pathtoregressors": ".../Regressors/gaia_quality_mean",
           "iscmodelsdisabled": 1}

Note `pathtoregressors`, not `pathtoclassifiers`: AutoML loads regression and
classification candidates from separate pools (iris_automl/automl_train.py,
_determine_best_regressor), and a numeric target never consults the classifier
pool. It reports NoEstimatorChosen once the isc models are disabled.

The mean and sigma heads live in two separate files, each in its own directory,
rather than one parameterised file. AutoML forwards only isc_models_disabled,
n_jobs, problem_type, random_state and verbose into IRISModel(**kwargs). Extra
USING keys are dropped before they get here (measured), so a "predict_output"
parameter cannot be passed in and the head has to be fixed at file level.

IRISModel contract (iris_automl/automl_model.py):
    - __init__(**kwargs) receives random_state, n_jobs and the state variables
    - self.model must be a sklearn-compatible estimator
    - self.name must be a unique string
    - IntegratedML pre-processes features before calling self.model.fit(X, y);
      X arrives as a (sparse) float matrix and column indices are not stable.
"""

from gaia_quality_estimator import NGBoostQualityEstimator


class IRISModel:
    def __init__(self, **kwargs):
        self.name = "gaia_data_quality_ngboost_mean"
        self.model_type = "NGBoost Natural Gradient Boosting (predictive mean)"
        self.package = "ngboost"
        # `or 42`, not `kwargs.get("random_state", 42)`. AutoML's train() declares
        # `random_state=None` and passes it down explicitly, so the key is always
        # present and .get()'s default never applies -- NGBoost then seeds itself
        # from the OS and two builds of the same image train two different models.
        # That is invisible in the accuracy figures (MAE was 0.0432 both times) and
        # shows up as bucket populations that shift by ~0.05%, which is enough to
        # fail a test asserting a measured population.
        self.model = NGBoostQualityEstimator(
            n_estimators=int(kwargs.get("n_estimators", 300)),
            learning_rate=float(kwargs.get("learning_rate", 0.01)),
            random_state=kwargs.get("random_state") or 42,
            predict_output="mean",
        )
