"""
SIMBAD evidence for disputed classifications.

When the classifier disagrees with the DR3 catalogue, the tie-breaker has to come
from outside both. SIMBAD carries independent object types and the bibliography
behind them, queried by Gaia DR3 source_id over TAP.

THE CIRCULARITY TRAP, and why the origin filter is not optional:

SIMBAD ingests the Gaia DR3 variability catalogue itself. Across all of SIMBAD,
61.6% of `EB*`, 38.6% of `LP*` and 32.1% of `RR*` classifications originate from
bibcode 2022yCat.1358....0G -- which is Gaia DR3 Part 4 (Variability), the same
table this project trains on. Using those as "independent evidence" would mean
adjudicating ESA's labels with ESA's labels and finding, unsurprisingly, that
ESA agrees with itself.

GAIA_VARI_BIBCODE below is filtered out of every otype query. On this project's
656 disputed sources the effect is smaller than the global rate -- 159 of 1,412
otype rows (11.3%) are Gaia-derived -- but it has to be measured rather than
assumed, so `fetch_otypes` returns both counts and the pipeline reports them.
"""

import csv
import io
import json
import urllib.parse
import urllib.request

TAP_URL = "https://simbad.cds.unistra.fr/simbad/sim-tap/sync"
GAIA_VARI_BIBCODE = "2022yCat.1358"
BATCH = 100
TIMEOUT = 120


def _query(adql, timeout=TIMEOUT):
    """Run an ADQL query against SIMBAD TAP, returning parsed CSV rows."""
    data = urllib.parse.urlencode({
        "REQUEST": "doQuery", "LANG": "ADQL", "FORMAT": "csv", "QUERY": adql,
    }).encode()
    with urllib.request.urlopen(TAP_URL, data=data, timeout=timeout) as resp:
        text = resp.read().decode()
    reader = csv.reader(io.StringIO(text))
    next(reader, None)  # header
    return [r for r in reader if r]


def _in_list(source_ids):
    return ",".join(f"'Gaia DR3 {int(s)}'" for s in source_ids)


def _strip(gaia_id):
    return int(gaia_id.replace("Gaia DR3 ", "").strip())


def fetch_identity(source_ids):
    """main_id, primary otype, spectral type and reference count per source."""
    out = {}
    for k in range(0, len(source_ids), BATCH):
        chunk = source_ids[k:k + BATCH]
        rows = _query(
            "SELECT i.id, b.main_id, b.otype_txt, b.sp_type, b.nbref "
            "FROM ident i JOIN basic b ON b.oid = i.oidref "
            f"WHERE i.id IN ({_in_list(chunk)})")
        for r in rows:
            if len(r) >= 5 and r[0].startswith("Gaia DR3 "):
                out[_strip(r[0])] = {
                    "main_id": r[1], "otype": r[2],
                    "sp_type": r[3], "nbref": int(r[4]) if r[4].isdigit() else 0,
                }
    return out


def fetch_otypes(source_ids):
    """All object types per source, split by whether the origin is Gaia's own.

    Returns (independent, circular_count) where independent maps
    source_id -> [otype, ...] with Gaia-derived classifications removed.
    """
    independent, circular = {}, 0
    for k in range(0, len(source_ids), BATCH):
        chunk = source_ids[k:k + BATCH]
        rows = _query(
            "SELECT i.id, o.otype_txt, o.origin "
            "FROM ident i JOIN otypes o ON o.oidref = i.oidref "
            f"WHERE i.id IN ({_in_list(chunk)})")
        for r in rows:
            if len(r) < 3 or not r[0].startswith("Gaia DR3 "):
                continue
            sid, otype, origin = _strip(r[0]), r[1], r[2]
            if GAIA_VARI_BIBCODE in origin:
                circular += 1
                continue
            independent.setdefault(sid, []).append(otype)
    return independent, circular


def fetch_papers(source_ids, keywords=None):
    """Bibliography per source: (bibcode, year, journal, title).

    `year` is an ADQL reserved word, hence the quoting. Pass `keywords` to
    restrict to titles mentioning any of them -- used to pull the papers that
    speak to a specific disputed behaviour rather than the whole bibliography,
    which for a well-studied star runs to hundreds of entries.
    """
    out = {}
    where_kw = ""
    if keywords:
        clauses = " OR ".join(f"r.title LIKE '%{k}%'" for k in keywords)
        where_kw = f" AND ({clauses})"
    for k in range(0, len(source_ids), BATCH):
        chunk = source_ids[k:k + BATCH]
        rows = _query(
            'SELECT i.id, r.bibcode, r."year", r.journal, r.title '
            "FROM ident i JOIN has_ref h ON h.oidref = i.oidref "
            "JOIN ref r ON r.oidbib = h.oidbibref "
            f"WHERE i.id IN ({_in_list(chunk)}){where_kw}")
        for r in rows:
            if len(r) >= 5 and r[0].startswith("Gaia DR3 "):
                out.setdefault(_strip(r[0]), []).append(
                    {"bibcode": r[1], "year": r[2], "journal": r[3], "title": r[4]})
    return out


# Titles that match a variability keyword for the wrong reason. "Rotation"
# especially: galactic rotation curves, maser kinematics and reference-frame
# papers all match, and because they tend to be recent they crowd out the
# targeted studies when the list is sorted by year. Measured on HD 283572, three
# of twenty slots went to galactic dynamics while a 1993 paper with the star's
# own name in the title did not make the cut.
OFF_TOPIC = ("galactic rotation", "rotation curve", "maser", "inertial coordinate",
             "reference frame", "hcrf", "vertical velocit", "oort")


def _relevance(paper, main_id=None):
    """Rank papers by how directly they bear on why *this* star varies.

    Recency is a weak signal here. A 1993 paper about this specific star settles
    more than a 2015 survey that included it in a table.
    """
    title = paper["title"].lower()
    score = 0
    if main_id and main_id.replace(" ", "").lower() in title.replace(" ", ""):
        score += 100                                    # names the star
    for kw, w in (("starspot", 25), ("spot", 20), ("rotational modulation", 25),
                  ("rotation period", 20), ("photometric variab", 15),
                  ("eclips", 15), ("binar", 12), ("pulsat", 12),
                  ("activity", 8), ("variab", 6), ("period", 5)):
        if kw in title:
            score += w
    try:
        score += min(int(paper["year"]) - 1950, 80) / 40.0   # mild recency tiebreak
    except (ValueError, TypeError):
        pass
    return score


def evidence_for(source_id, keywords=None, max_papers=25):
    """Everything SIMBAD knows about one source, shaped for a prompt.

    Trimmed to the `max_papers` most *relevant* -- not most recent. HD 283572
    alone has 311 references; the agent needs the ones that speak to the
    disputed behaviour, not the newest ones.
    """
    ident = fetch_identity([source_id]).get(source_id, {})
    indep, circular = fetch_otypes([source_id])
    papers = fetch_papers([source_id], keywords=keywords).get(source_id, [])
    main_id = ident.get("main_id")
    papers = [p for p in papers
              if not any(o in p["title"].lower() for o in OFF_TOPIC)]
    papers.sort(key=lambda p: _relevance(p, main_id), reverse=True)
    return {
        "source_id": source_id,
        "main_id": ident.get("main_id"),
        "simbad_otype": ident.get("otype"),
        "spectral_type": ident.get("sp_type"),
        "n_references": ident.get("nbref", 0),
        "independent_otypes": sorted(set(indep.get(source_id, []))),
        "gaia_derived_otypes_excluded": circular,
        "papers": papers[:max_papers],
        # The untruncated list, for the recursive path. `papers` above is what a
        # single prompt can hold; this is what actually exists, and the whole
        # point of Gaia.Literature is that nothing gets dropped by a keyword
        # score before the model sees it.
        "all_papers": papers,
        "n_papers_total": len(papers),
    }


# Claim categories, in priority order: a title matching several is filed under
# the first, so the more specific mechanisms are listed before the general ones.
# Derived here rather than asked of the model -- a model that categorises its own
# evidence can categorise it into whatever supports the answer it already holds,
# and these categories are what the decomposition is built on.
_CLAIM_RULES = (
    ("rotation", ("starspot", "star spot", "spot", "rotational modulation",
                  "rotation period", "rotation", "magnetic activity",
                  "chromospheric", "coronal", "flare", "by dra")),
    ("eclipse", ("eclipsing", "eclipse", "binary", "contact system")),
    ("pulsation", ("pulsat", "rr lyrae", "cepheid", "delta scuti", "scuti",
                   "mira", "long-period variable", "radial velocity curve")),
    ("youth", ("t tauri", "pre-main-sequence", "pre main sequence", "young stellar",
               "protoplanetary", "herbig", "orion population", "accretion disk")),
)

# A paper is a survey catalogue if it says so. Deliberately conservative: the
# weighing rules treat targeted studies as stronger evidence, so the cost of
# wrongly calling a catalogue "targeted" is higher than the reverse.
_SURVEY_MARKERS = ("catalog", "catalogue", "survey", "census", "data release",
                   "all-sky", "sample of", "atlas of", "identification list",
                   "variable stars in", "search for", "photometry of the")


def classify_paper(title):
    """(claim_type, study_type) for a paper title.

    Both are coarse on purpose. They exist so a bibliography can be decomposed
    into slices a model can reason about one at a time, not to be right about
    every paper -- a misfiled title still reaches the model, just in a different
    slice.
    """
    t = (title or "").lower()
    claim = "other"
    for name, markers in _CLAIM_RULES:
        if any(m in t for m in markers):
            claim = name
            break
    study = "survey" if any(m in t for m in _SURVEY_MARKERS) else "targeted"
    return claim, study


def format_evidence(ev):
    """Render one source's evidence as the text block handed to the agent."""
    lines = [
        f"SIMBAD identity : {ev['main_id'] or 'not in SIMBAD'}",
        f"SIMBAD type     : {ev['simbad_otype'] or '-'}",
        f"Spectral type   : {ev['spectral_type'] or '-'}",
        f"References      : {ev['n_references']}",
        f"Independent types (Gaia-derived excluded): "
        f"{', '.join(ev['independent_otypes']) or 'none'}",
    ]
    if ev["papers"]:
        lines.append(f"\nPublished literature ({ev['n_papers_total']} matching, "
                     f"showing {len(ev['papers'])}):")
        for p in ev["papers"]:
            lines.append(f"  {p['year']} {p['journal']:<10} {p['title']}")
            lines.append(f"       {p['bibcode']}")
    else:
        lines.append("\nNo matching literature.")
    return "\n".join(lines)


if __name__ == "__main__":
    # HD 283572: ESA says YSO (confidence 0.29), the classifier says RS.
    ev = evidence_for(164536250037820160,
                      keywords=["otation", "spot", "ctivity", "eriod"])
    print(format_evidence(ev))
    print("\n" + json.dumps({k: v for k, v in ev.items() if k != "papers"}, indent=2))
