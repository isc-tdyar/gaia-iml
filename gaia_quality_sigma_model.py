"""
IRISModel for GaiaQualityUncertainty: the NGBoost predictive *standard
deviation* of `reject_fraction`. Identical estimator to the mean head; only the
projection differs. See gaia_quality_estimator.py for rationale and measurements.

    CREATE MODEL GaiaQualityUncertainty PREDICTING (reject_fraction)
    WITH (...)  FROM GaiaQualityStats
    USING {"pathtoregressors": ".../Regressors/gaia_quality_sigma",
           "iscmodelsdisabled": 1}

The two heads are separate files in separate directories because AutoML drops
custom USING keys before they reach IRISModel(**kwargs). See the note in
gaia_quality_mean_model.py.

One consequence worth knowing when reading the training log: AutoML scores this
model with mean squared error against `reject_fraction`, the same column the mean
head is scored on. That number is meaningless for the sigma head: it is not
trying to predict the target, it is reporting the spread of its own predictive
distribution. Its selection score should be ignored; what matters is the interval
coverage, measured in gaia_quality_estimator.py's docstring.
"""

from gaia_quality_estimator import NGBoostQualityEstimator


class IRISModel:
    def __init__(self, **kwargs):
        self.name = "gaia_data_quality_ngboost_sigma"
        self.model_type = "NGBoost Natural Gradient Boosting (predictive sigma)"
        self.package = "ngboost"
        self.model = NGBoostQualityEstimator(
            n_estimators=int(kwargs.get("n_estimators", 300)),
            learning_rate=float(kwargs.get("learning_rate", 0.01)),
            # `or 42`: AutoML always passes random_state=None explicitly, so
            # .get()'s default never fires. See gaia_quality_mean_model.py.
            random_state=kwargs.get("random_state") or 42,
            predict_output="sigma",
        )
