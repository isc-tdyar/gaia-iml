"""
IRISModel for GaiaVariableType: multi-class variable-star classification from
Gaia DR3 light-curve features.

    CREATE MODEL GaiaVariableType PREDICTING (var_class)
    WITH (g_n NUMERIC, g_mean NUMERIC, ... rej_rp NUMERIC)
    FROM GaiaLightCurveFeatures
    USING {"pathtoclassifiers": ".../Classifiers/gaia_variable_type",
           "iscmodelsdisabled": 1}

Note `pathtoclassifiers`, not `pathtoregressors`. AutoML loads regression and
classification candidates from separate pools, and a categorical target never
consults the regressor pool -- it reports NoEstimatorChosen once the built-in
isc models are disabled. The quality models in this repo use the regressor pool;
this one is the mirror image.

Why a histogram gradient boosting classifier rather than something deeper: on
light-curve classification, hand-crafted features plus a tree ensemble are still
the state of the art. The StarEmbed benchmark (arXiv:2510.06200) measured 138
hand-crafted features + Random Forest at F1 0.807 on ZTF, ahead of every
time-series foundation model it tested (Chronos-tiny 0.640, Astromer-2 0.580).
That is convenient here, because a tree ensemble over 27 columns is exactly the
shape that fits inside SQL PREDICT().

IRISModel contract (iris_automl/automl_model.py):
    - __init__(**kwargs) receives random_state, n_jobs and the state variables
    - self.model must be a sklearn-compatible estimator
    - self.name must be a unique string
    - do NOT implement fit()/predict() here; IntegratedML calls self.model
"""

import numpy as np
from sklearn.ensemble import HistGradientBoostingClassifier


def _dense(X):
    """Densify whatever AutoML hands us.

    IntegratedML's feature pipeline emits a scipy sparse csr_matrix once it has
    added the isMissing indicator columns -- which this model guarantees it will,
    because a Lomb-Scargle period is genuinely NULL for a source with too few
    epochs. HistGradientBoostingClassifier rejects sparse input outright:

        TypeError: Sparse data was passed for X, but dense data is required.

    The documented fix_matrix_type hook only runs for the final
    fit_on_all_data() call, not for the cross-validation folds, so the
    conversion has to live here. Same shim as gaia_quality_estimator._dense.
    """
    if hasattr(X, "toarray"):
        X = X.toarray()
    return np.asarray(X, dtype=float)


class LightCurveClassifier(HistGradientBoostingClassifier):
    """HistGradientBoostingClassifier that accepts IntegratedML's sparse frames.

    SUBCLASS, NOT A WRAPPER, AND THE DIFFERENCE IS NOT STYLISTIC.

    The obvious shape for this is a BaseEstimator/ClassifierMixin wrapper holding
    the real estimator in an attribute created by fit():

        def fit(self, X, y):
            self.model_ = HistGradientBoostingClassifier(...)   # DO NOT
            self.model_.fit(_dense(X), y)

    That trains correctly and predicts correctly in the process that trained it,
    then silently returns *zero rows* from PREDICT() in any other process. The
    model is stored by dill.dumps() and reloaded by dill.loads()
    (iris_automl/automl_trained_model.py), and the lazily-created inner estimator
    does not survive the round trip. Nothing raises: TrainedModel.predict()
    returns an empty result and SQL reports SQLCODE=0 with no rows, so the
    failure looks like an empty table rather than a broken model.

    Measured, on the same data in the same container: a bare
    RandomForestClassifier in the pool predicts fine from a fresh process, this
    class as a wrapper predicted nothing, and this class as a subclass predicts
    fine. The pre-training strategy depends on that -- the model is trained at
    docker build time and every later PREDICT() runs in a different process.

    THE OTHER HALF OF THE FIX IS IN THE DOCKERFILE.

    Subclassing alone is not enough. dill serializes classes *by reference*, so
    the module defining this class has to be importable when the model is
    reloaded in a cold process. The Classifiers/ pool directory is not on
    sys.path, so this file is copied to /usr/irissys/mgr/python/ as well as into
    the pool. Without that copy the symptom is identical -- zero rows, no error.

    That is also why the NGBoost regressors in this repo never showed the bug:
    gaia_quality_estimator.py was already on the embedded Python path so the two
    head files could share it.

    Verify this in a freshly started container, not a hot-patched one. A warm
    process can have the class cached and will predict happily while a cold
    start returns nothing.

    Subclassing keeps the one thing the wrapper was for: densifying. IntegratedML
    emits a scipy sparse csr_matrix once it adds isMissing indicator columns,
    which this model guarantees because a Lomb-Scargle period is genuinely NULL
    for a source with too few epochs, and HistGradientBoostingClassifier rejects
    sparse input outright.
    """

    def fit(self, X, y, **kwargs):
        return super().fit(_dense(X), np.asarray(y), **kwargs)

    def predict(self, X):
        return super().predict(_dense(X))

    def predict_proba(self, X):
        return super().predict_proba(_dense(X))


class IRISModel:
    def __init__(self, **kwargs):
        self.name = "gaia_variable_type_hgb"
        self.model_type = "Histogram Gradient Boosting (multi-class)"
        self.package = "scikit-learn"
        # `or 42`, not kwargs.get("random_state", 42): AutoML declares
        # random_state=None and passes it down explicitly, so the key is always
        # present and .get()'s default never fires. Without this, two builds of
        # the same image train two different models.
        self.model = LightCurveClassifier(
            max_iter=int(kwargs.get("max_iter", 300)),
            learning_rate=float(kwargs.get("learning_rate", 0.1)),
            random_state=kwargs.get("random_state") or 42,
        )
