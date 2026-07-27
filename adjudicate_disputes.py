#!/usr/bin/env python3
"""
Adjudicate classifier/catalogue disagreements.

Three stages, in increasing cost, so that nothing reaches the language model
that arithmetic could have settled:

  1. find the disagreements                                    (SQL)
  2. numeric adjudication + clustering                         (numpy/sklearn)
  3. literature adjudication for the ones that matter          (SIMBAD + AI Hub)

Run inside IRIS:  irispython adjudicate_disputes.py
Run standalone:   python3 adjudicate_disputes.py --offline --limit 5
"""
import argparse
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import gaia_dispute as gd
import gaia_simbad as gs
from gaia_lightcurve_features import FEATURES

# Papers worth pulling for a disputed source. The whole bibliography of a
# well-studied star is hundreds of entries; these keywords select the ones that
# speak to why it varies.
KEYWORDS = ["otation", "spot", "ctivity", "eriod", "clips", "binar",
            "ulsat", "ariab"]

# Above this many relevant papers, the flat prompt would have to truncate, so the
# recursive path is used instead. Below it, one Chat() call sees the whole
# bibliography and recursion would be ceremony.
RLM_PAPER_THRESHOLD = 25


def load_literature(source_id, papers):
    """Replace GaiaLiterature with one source's papers, for an RLM run.

    The table holds one source at a time. RLM.Source.Table decomposes a whole
    extent and has no per-instance filter hook, so scoping is done by what is in
    the table rather than by a predicate. See Gaia.Literature for why the two
    alternatives are worse.
    """
    import iris
    from gaia_simbad import classify_paper

    # %DeleteExtent/%New rather than DELETE/INSERT. `DELETE FROM
    # Gaia.GaiaLiterature` fails with an empty SQLError against a persistent
    # class's projected table here while SELECT on the same table works, so the
    # class API is used for both halves to keep them consistent.
    row_cls = iris.cls("Gaia.LiteratureRow")
    row_cls._DeleteExtent()
    n = 0
    for p in papers:
        try:
            year = int(p["year"])
        except (TypeError, ValueError):
            continue          # a paper with no year cannot be placed in an epoch
        claim, study = classify_paper(p["title"])
        row = row_cls._New()
        row.SourceId = int(source_id)
        row.Bibcode = (p["bibcode"] or "")[:40]
        row.PubYear = year
        row.Journal = (p["journal"] or "")[:30]
        row.Title = (p["title"] or "")[:500]
        row.ClaimType = claim
        row.StudyType = study
        sc = row._Save()
        if iris.system.Status.IsError(sc):
            raise RuntimeError(iris.system.Status.GetErrorText(sc))
        n += 1
    return n

OUT_DIR = os.environ.get("GAIA_OUT", "/home/irisowner/dev/data/out")


def _num(v):
    """SQL cell -> float, with every spelling of NULL becoming NaN.

    IRIS returns a NULL as the empty string rather than None, so testing for
    None alone leaves float('') to raise.
    """
    if v is None or v == "":
        return np.nan
    try:
        return float(v)
    except (TypeError, ValueError):
        return np.nan


def load_from_iris():
    """Read scored sources out of IRIS.

    Only rows carrying ESA's label are returned. The scored table holds all
    75,068 sources but only the 10,660 in the training extract have a
    var_class, and a source with no published label cannot disagree with one.

    There is no confidence column. PREDICT() yields one scalar per row -- the
    class -- and IntegratedML has no path to predict_proba, so the confidence
    the offline path gets from the estimator is simply not available in SQL.
    Rather than invent one, disputes carry conf 0 and stage 3 falls back to
    ordering by source_id.
    """
    import iris
    rows = list(iris.sql.exec(
        "SELECT source_id, " + ", ".join(FEATURES) + ", var_class, "
        "predicted_class FROM GaiaVariableScored WHERE var_class IS NOT NULL"))
    sid = np.array([int(r[0]) for r in rows])
    X = np.array([[_num(v) for v in r[1:1 + len(FEATURES)]] for r in rows],
                 dtype=float)
    y = np.array([r[1 + len(FEATURES)] for r in rows])
    pred = np.array([r[2 + len(FEATURES)] for r in rows])
    conf = np.zeros(len(rows))
    return sid, X, y, pred, conf


def load_offline(scratch):
    """Rebuild the same arrays outside IRIS, for development."""
    import csv
    from collections import Counter
    from sklearn.ensemble import HistGradientBoostingClassifier
    from sklearn.model_selection import train_test_split

    lab = {}
    with open(os.path.join(scratch, "labels.csv")) as fh:
        for r in csv.DictReader(fh):
            try:
                lab[int(r["source_id"])] = r["best_class_name"]
            except (ValueError, KeyError):
                pass
    X, y, sid = [], [], []
    with open(os.path.join(scratch, "features.csv")) as fh:
        for r in csv.DictReader(fh):
            s = int(r["source_id"])
            if s not in lab:
                continue
            row = []
            for k in FEATURES:
                try:
                    v = float(r[k])
                    row.append(v if v == v else np.nan)
                except (ValueError, TypeError):
                    row.append(np.nan)
            X.append(row); y.append(lab[s]); sid.append(s)
    X = np.array(X, float); y = np.array(y); sid = np.array(sid)
    keep = {c for c, n in Counter(y).items() if n >= 300}
    m = np.isin(y, list(keep))
    X, y, sid = X[m], y[m], sid[m]
    idx = np.arange(len(y))
    itr, ite = train_test_split(idx, test_size=.25, stratify=y, random_state=42)
    clf = HistGradientBoostingClassifier(max_iter=300, random_state=42).fit(X[itr], y[itr])
    proba = clf.predict_proba(X[ite])
    pred = clf.classes_[proba.argmax(1)]
    return sid[ite], X[ite], y[ite], pred, proba.max(1)


def build_prompt(source_id, catalogue, model, conf, feature_block, evidence_block):
    return f"""## Disputed source

Gaia DR3 {source_id}

- Catalogue class: **{catalogue}**
- Model class: **{model}** (classifier confidence {conf:.2f})

## Light-curve feature comparison

{feature_block}

## Independent evidence

{evidence_block}
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--offline", action="store_true")
    ap.add_argument("--scratch", default=".")
    ap.add_argument("--limit", type=int, default=10,
                    help="how many disputes to send to the agent")
    ap.add_argument("--source", type=int, help="adjudicate one specific source_id")
    ap.add_argument("--no-agent", action="store_true",
                    help="stop after the numeric stage")
    ap.add_argument("--no-rlm", action="store_true",
                    help="force the flat one-call path even for well-studied "
                         "sources, for comparing the two routes")
    args = ap.parse_args()

    sid, X, y, pred, conf = (load_offline(args.scratch) if args.offline
                             else load_from_iris())
    print(f"{len(sid)} scored sources")

    # ---- stage 1: disagreements
    disputes = gd.find_disputes(sid, y, pred, conf)
    print(f"stage 1: {len(disputes)} disagreements "
          f"({100*len(disputes)/len(sid):.1f}%)")

    # ---- stage 2: what arithmetic can settle
    agreed = pred == y
    cents, imp, scal = gd.class_centroids(X, y, agreed)
    pos = {int(s): i for i, s in enumerate(sid)}
    n_model = 0
    for d in disputes:
        i = pos[d["source_id"]]
        winner, d_cat, d_mod = gd.adjudicate_numerically(
            X[i], d["catalogue"], d["model"], cents, imp, scal)
        d["numeric_winner"] = winner
        d["d_catalogue"], d["d_model"] = round(d_cat, 3), round(d_mod, 3)
        n_model += (winner == "model")
    print(f"stage 2: centroid distance favours the model on {n_model}"
          f" of {len(disputes)} ({100*n_model/len(disputes):.1f}%)")

    dmask = np.isin(sid, [d["source_id"] for d in disputes])
    labels = gd.cluster_disputes(X[dmask])
    for c in gd.summarise_clusters(labels, disputes):
        pairs = ", ".join(f"{p}({n})" for p, n in c["top_pairs"])
        print(f"    cluster {c['cluster']}: n={c['n']:4d}  {pairs}")

    if args.no_agent:
        _write(disputes, [])
        return

    # ---- stage 3: literature, for the disputes worth the call
    if args.source:
        chosen = [d for d in disputes if d["source_id"] == args.source]
        if not chosen:
            print(f"source {args.source} is not disputed")
            return
    else:
        # Most-confident model predictions first: those are the cases where the
        # classifier is making a real claim rather than guessing.
        chosen = sorted(disputes, key=lambda d: -d["model_conf"])[:args.limit]

    print(f"\nstage 3: {len(chosen)} sources -> SIMBAD + agent")
    verdicts = []
    for d in chosen:
        i = pos[d["source_id"]]
        fb = gd.format_feature_comparison(
            gd.feature_comparison(X[i], X, y, agreed, d["catalogue"],
                                  d["model"], FEATURES),
            d["catalogue"], d["model"])
        try:
            ev = gs.evidence_for(d["source_id"], keywords=KEYWORDS, max_papers=20)
        except Exception as e:
            print(f"  {d['source_id']}: SIMBAD unavailable ({type(e).__name__})")
            continue
        eb = gs.format_evidence(ev)
        prompt = build_prompt(d["source_id"], d["catalogue"], d["model"],
                              d["model_conf"], fb, eb)
        rec = dict(d, main_id=ev["main_id"], n_references=ev["n_references"],
                   independent_otypes=ev["independent_otypes"],
                   n_papers=ev["n_papers_total"])

        if ev["main_id"] is None:
            # No literature is a result, not a failure. Do not spend a call.
            rec["verdict"] = "insufficient evidence (not in SIMBAD)"
            rec["route"] = "none"
            print(f"  {d['source_id']}: not in SIMBAD")
        elif args.offline:
            rec["prompt"] = prompt
            rec["route"] = ("rlm" if ev["n_papers_total"] > RLM_PAPER_THRESHOLD
                            else "flat")
            print(f"  {d['source_id']} = {ev['main_id']}: "
                  f"{ev['n_references']} refs, {ev['n_papers_total']} relevant "
                  f"-> {rec['route']} (offline, agent not called)")
        elif ev["n_papers_total"] > RLM_PAPER_THRESHOLD and not args.no_rlm:
            # Too many papers for one prompt. Recurse over the bibliography
            # instead of truncating it: the flat path keeps the top 20 by a
            # keyword score, and that score has already been wrong once here.
            import iris
            n = load_literature(d["source_id"], ev["all_papers"])
            rec["route"] = "rlm"
            rec["papers_loaded"] = n
            verdict = iris.cls("Gaia.LiteratureAudit").Adjudicate(
                d["source_id"], prompt)
            rec["verdict"] = verdict
            print(f"  {d['source_id']} = {ev['main_id']}: RLM over {n} papers "
                  f"-> {str(verdict)[:60]}")
        else:
            import iris
            rec["route"] = "flat"
            verdict = iris.cls("Gaia.Adjudicator").Adjudicate(prompt)
            rec["verdict"] = verdict
            print(f"  {d['source_id']} = {ev['main_id']}: flat "
                  f"-> {str(verdict)[:60]}")
        verdicts.append(rec)

    _write(disputes, verdicts)


def _write(disputes, verdicts):
    os.makedirs(OUT_DIR, exist_ok=True)
    p = os.path.join(OUT_DIR, "disputes.json")
    with open(p, "w") as fh:
        json.dump({"n_disputes": len(disputes),
                   "disputes": disputes, "verdicts": verdicts}, fh, indent=2)
    print(f"\nwrote {p}")


if __name__ == "__main__":
    main()
