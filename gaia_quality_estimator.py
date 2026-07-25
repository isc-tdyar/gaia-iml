"""
Shared NGBoost estimator behind the GaiaDataQuality / GaiaQualityUncertainty
models. Installed onto the embedded-Python path (not into a Regressors
directory) so both model files can import it.

Target: `reject_fraction`, the fraction of a source's epochs that ESA's own
variability pipeline flagged as rejected (`variability_flag_bp_reject` and
`variability_flag_rp_reject`).

Why this target: the challenge's own answer, "flux swing > 100%", is an exact
arithmetic rule, so a model that predicts it is strictly worse than the
comparison and any accuracy it shows is leakage. `reject_fraction` is different
in kind: it is a label ESA curated from per-epoch quality assessments that are
*not* recoverable from the summary statistics we feed the model. There is real
information to learn, and being wrong means being wrong.

Why NGBoost rather than a plain regressor: NGBoost fits a full conditional
*distribution* per source, so every prediction carries its own error bar. For a
data-quality score that is the interesting part. "40% of this source's epochs
are probably bad" means something quite different at sigma 0.02 than at 0.12.
It is also the kind of model AutoML cannot produce, which is why the
custom-models feature exists.

Measured on real archive data: files 1-2 as training (n=10,137), file 3 fully
held out as test (n=4,094). No fold leakage: different sources entirely.

    model                        MAE      R^2     fit
    predict the mean (baseline)  0.0677   -0.04   --
    GradientBoostingRegressor    0.0382   +0.60   2.4s
    NGBoost (this file)          0.0389   +0.59   10.6s
    gplearn symbolic regression  0.0445   +0.42   7.0s
    TabPFN (foundation model)    0.0405   +0.55   16s predict

NGBoost matches the point accuracy of plain gradient boosting (0.0389 vs 0.0382
MAE, well inside noise) and adds uncertainty that is calibrated rather than
decorative:

    nominal interval    empirical coverage
    50%                 50.8%
    80%                 80.2%
    90%                 90.6%
    95%                 95.0%

and the sigma is informative rather than constant: MAE in the most-confident quartile
is 0.0263 versus 0.0601 in the least, a 2.3x spread.
"""

import numpy as np
from sklearn.base import BaseEstimator, RegressorMixin


def _dense(X):
    """Densify whatever AutoML hands us.

    IntegratedML's feature pipeline emits a scipy sparse csr_matrix once it has
    added the isMissing indicator columns, and NGBoost's tree base learners want
    a dense array. np.asarray() on a csr_matrix produces a 0-d object array and
    fails with "float() argument must be ... not 'csr_matrix'". The documented
    fix_matrix_type hook only runs for the final fit_on_all_data() call, not for
    the cross-validation folds, so the conversion has to live here.
    """
    if hasattr(X, "toarray"):
        X = X.toarray()
    return np.asarray(X, dtype=float)


class NGBoostQualityEstimator(BaseEstimator, RegressorMixin):
    """NGBoost regressor whose predict() returns either the mean or the sigma.

    IntegratedML stores one scalar per row, so the predictive distribution has to
    be projected onto a single head at CREATE MODEL time rather than at query
    time. `predict_output` selects which.

    reject_fraction is a proportion, so the mean head is clipped to [0, 1]:
    boosting on a bounded target otherwise emits values slightly outside it, and
    a negative "fraction of epochs rejected" is nonsense in a report. The sigma
    head is left unclipped, being a spread rather than a proportion.
    """

    def __init__(self, n_estimators=300, learning_rate=0.01, minibatch_frac=1.0,
                 random_state=42, predict_output="mean"):
        self.n_estimators = n_estimators
        self.learning_rate = learning_rate
        self.minibatch_frac = minibatch_frac
        self.random_state = random_state
        self.predict_output = predict_output

    def fit(self, X, y, **kwargs):
        # Imported here, not at module scope: AutoML imports every file in the
        # models directory to discover candidates, and a missing ngboost would
        # then break unrelated models rather than this one alone.
        from ngboost import NGBRegressor
        from ngboost.distns import Normal

        self.model_ = NGBRegressor(
            Dist=Normal,
            n_estimators=self.n_estimators,
            learning_rate=self.learning_rate,
            minibatch_frac=self.minibatch_frac,
            random_state=self.random_state,
            verbose=False,
        )
        self.model_.fit(_dense(X), np.asarray(y, dtype=float).ravel())
        return self

    def predict(self, X):
        dist = self.model_.pred_dist(_dense(X))
        if self.predict_output == "sigma":
            return dist.scale
        return np.clip(dist.loc, 0.0, 1.0)

    def pred_dist(self, X):
        """Full predictive distribution, for callers not going through PREDICT()."""
        return self.model_.pred_dist(_dense(X))
