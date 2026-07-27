"""
Where the classifier and the DR3 catalogue disagree, and what statistics can
settle before an agent is involved.

This module deliberately does as much of the adjudication as arithmetic allows.
Two questions turn out to be answerable without a language model:

  1. "Which label does this source actually resemble?" -- compare it to the
     centroids of confidently-agreed examples of both classes. On this dataset
     64% of disputes land closer to the classifier's answer than the
     catalogue's.

  2. "Are these disputes independent, or the same confusion repeated?" -- k-means
     over the disputed sources collapses ~50 class-pairs into a handful of
     recurring degeneracies, and finds the bidirectional ones (RS->ECL and
     ECL->RS are one phenomenon) without being told they are related.

Both are cheap, deterministic and reproducible, which an LLM call is not. What
survives them -- weighing decades of conflicting published classifications --
goes to Gaia.Adjudicator.
"""

import numpy as np
from sklearn.cluster import KMeans
from sklearn.impute import SimpleImputer
from sklearn.preprocessing import StandardScaler

# Features that carry the argument between the classes that actually get
# confused. Reported alongside a verdict so the numbers can be checked by hand.
DISCRIMINATING = ["g_p", "g_amp", "g_abbe", "g_stetson", "bp_rp_colour", "g_skew"]


def find_disputes(source_ids, catalogue_class, model_class, model_conf):
    """Rows where the classifier and the catalogue disagree."""
    dis = np.asarray(model_class) != np.asarray(catalogue_class)
    return [
        {"source_id": int(s), "catalogue": c, "model": m, "model_conf": float(k)}
        for s, c, m, k in zip(np.asarray(source_ids)[dis],
                              np.asarray(catalogue_class)[dis],
                              np.asarray(model_class)[dis],
                              np.asarray(model_conf)[dis])
    ]


def class_centroids(X, y, agreed_mask):
    """Centroid per class, computed only from sources both parties agree on.

    Disputed sources are excluded: including them would let the thing being
    measured move the yardstick.
    """
    imputer = SimpleImputer(strategy="median").fit(X)
    scaler = StandardScaler().fit(imputer.transform(X))
    Z = scaler.transform(imputer.transform(X))
    cents = {c: Z[agreed_mask & (y == c)].mean(axis=0)
             for c in np.unique(y[agreed_mask])}
    return cents, imputer, scaler


def adjudicate_numerically(x_row, catalogue_cls, model_cls, cents, imputer, scaler):
    """Which class centroid is this source closer to?

    Returns (winner, d_catalogue, d_model). Not a probability and not a proof --
    a source can sit nearer one centroid and still belong to the other class --
    but it is the question the light curve alone can answer, and it is worth
    answering before spending an LLM call.
    """
    z = scaler.transform(imputer.transform(np.asarray(x_row).reshape(1, -1)))[0]
    d_cat = float(np.linalg.norm(z - cents[catalogue_cls]))
    d_mod = float(np.linalg.norm(z - cents[model_cls]))
    return ("model" if d_mod < d_cat else "catalogue"), d_cat, d_mod


def cluster_disputes(X_disputed, n_clusters=6, random_state=0):
    """Group disputed sources by how they look, not by their label pair.

    Labels impose the pairing; clustering discovers it. That difference matters:
    RS->ECL and ECL->RS are two label pairs but one physical degeneracy, and
    k-means puts them in the same cluster without being told to.
    """
    imputer = SimpleImputer(strategy="median")
    Z = StandardScaler().fit_transform(imputer.fit_transform(X_disputed))
    km = KMeans(n_clusters=n_clusters, n_init=10, random_state=random_state).fit(Z)
    return km.labels_


def feature_comparison(x_row, X, y, agreed_mask, catalogue_cls, model_cls,
                       feature_names, features=None):
    """Table comparing one disputed source to confident examples of both classes.

    This is the numeric evidence handed to the agent. Medians rather than means:
    light-curve features are heavy-tailed and one bad epoch should not move the
    reference point.
    """
    features = features or DISCRIMINATING
    idx = {f: i for i, f in enumerate(feature_names)}
    rows = []
    for f in features:
        if f not in idx:
            continue
        i = idx[f]

        def med(cls):
            v = X[agreed_mask & (y == cls), i]
            v = v[~np.isnan(v)]
            return float(np.median(v)) if v.size else float("nan")

        rows.append({
            "feature": f,
            "this_source": float(x_row[i]),
            f"typical_{catalogue_cls}": med(catalogue_cls),
            f"typical_{model_cls}": med(model_cls),
        })
    return rows


def format_feature_comparison(rows, catalogue_cls, model_cls):
    """Render the comparison as the text block the agent reads."""
    if not rows:
        return "No feature comparison available."
    head = (f"{'feature':<16}{'this source':>14}"
            f"{('typical ' + catalogue_cls)[:20]:>22}"
            f"{('typical ' + model_cls)[:20]:>22}")
    out = [head, "-" * len(head)]
    for r in rows:
        out.append(f"{r['feature']:<16}{r['this_source']:>14.3f}"
                   f"{r[f'typical_{catalogue_cls}']:>22.3f}"
                   f"{r[f'typical_{model_cls}']:>22.3f}")
    return "\n".join(out)


def summarise_clusters(labels, disputes):
    """Per-cluster breakdown of which label pairs it contains."""
    from collections import Counter
    out = []
    for k in sorted(set(labels)):
        members = [d for d, lab in zip(disputes, labels) if lab == k]
        pairs = Counter((d["catalogue"], d["model"]) for d in members)
        out.append({
            "cluster": int(k),
            "n": len(members),
            "top_pairs": [(f"{a}->{b}", n) for (a, b), n in pairs.most_common(3)],
        })
    return out
