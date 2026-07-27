"""
Light-curve feature extraction for Gaia DR3 epoch photometry.

Turns the per-epoch flux/time arrays in an `epoch_photometry` row into the fixed
feature vector that `GaiaVariableType` classifies. Shared by the ingest pipeline
and the pre-training step, so both compute features the same way.

The feature set is the classical variability-statistics one: amplitude and
scatter measures, shape (skew/kurtosis), the Abbe parameter, a Stetson-style
correlation index, a Lomb-Scargle period and its peak power, and colour. That
choice is deliberate rather than nostalgic -- see the note in
gaia_variable_type_model.py on the StarEmbed benchmark.

The Lomb-Scargle periodogram runs on the G band only. BP and RP sample the same
star at nearly the same epochs, so their periodograms are near-duplicates of the
G one and cost three times as much to compute.
"""

import math

import numpy as np
from scipy.signal import lombscargle
from scipy.stats import kurtosis, skew

# Column indices in the epoch_photometry ECSV rows.
C_SOURCE_ID = 1
C_G_TIME, C_G_MAG = 4, 8
C_BP_TIME, C_BP_MAG = 10, 14
C_RP_TIME, C_RP_MAG = 15, 19
C_VAR_G_REJ, C_VAR_BP_REJ, C_VAR_RP_REJ = 45, 46, 47

# The model's feature vector, in order. Must match the WITH() list used in
# CREATE MODEL, and the column order of GaiaLightCurveFeatures.
FEATURES = [
    "g_n", "g_mean", "g_amp", "g_std", "g_mad", "g_iqr", "g_skew", "g_kurt",
    "g_abbe", "g_stetson", "g_span", "g_mad_succ", "g_p", "g_ppow",
    "bp_mean", "bp_amp", "bp_std", "bp_abbe",
    "rp_mean", "rp_amp", "rp_std", "rp_abbe",
    "bp_rp_colour", "amp_ratio_bp_rp", "rej_g", "rej_bp", "rej_rp",
]


def split_row(line):
    """Split an ECSV row on commas outside brackets.

    The array columns contain their own commas, so a plain line.split(",")
    shreds them.
    """
    out, buf, depth = [], [], 0
    for ch in line:
        if ch == "[":
            depth += 1
            buf.append(ch)
        elif ch == "]":
            depth -= 1
            buf.append(ch)
        elif ch == "," and depth == 0:
            out.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
    out.append("".join(buf))
    return out


def _raw(cell):
    """Parse a bracketed array cell, preserving NaN placeholders positionally."""
    cell = cell.strip().strip('"').strip("[]")
    out = []
    for tok in cell.split(","):
        tok = tok.strip()
        if not tok or tok in ("NaN", "null"):
            out.append(float("nan"))
        else:
            try:
                out.append(float(tok))
            except ValueError:
                out.append(float("nan"))
    return out


def paired(tcell, ycell):
    """Time/value arrays, keeping only epochs where both are finite.

    Positional alignment matters: dropping NaNs from each array independently
    would pair a time with the wrong measurement.
    """
    t, y = _raw(tcell), _raw(ycell)
    n = min(len(t), len(y))
    tt, yy = [], []
    for i in range(n):
        if t[i] == t[i] and y[i] == y[i]:
            tt.append(t[i])
            yy.append(y[i])
    return np.asarray(tt), np.asarray(yy)


def reject_frac(cell):
    """Fraction of True in a per-epoch boolean array."""
    s = cell.lower()
    t, f = s.count("true"), s.count("false")
    return (t / (t + f)) if (t + f) else float("nan")


def abbe(y):
    """von Neumann eta: ~1 for white noise, well below 1 for smooth variation."""
    n = len(y)
    if n < 3:
        return float("nan")
    var = np.var(y, ddof=1)
    if var <= 0:
        return float("nan")
    return float(np.sum(np.diff(y) ** 2) / (2 * (n - 1) * var))


def stetson_j(y):
    """Welch-Stetson style correlation index over successive pairs.

    The published Stetson J weights by photometric error; this variant uses the
    normalised deviations alone, which is what separates smoothly-varying
    sources (AGN, spotted stars) from epoch-to-epoch scatter.
    """
    n = len(y)
    if n < 4:
        return float("nan")
    m, s = np.mean(y), np.std(y, ddof=1)
    if s <= 0:
        return float("nan")
    d = (y - m) / s
    p = d[:-1] * d[1:]
    return float(np.sum(np.sign(p) * np.sqrt(np.abs(p))) / len(p))


def ls_period(t, y, pmin=0.05, pmax=500.0, n=6000):
    """Best Lomb-Scargle period and its normalised peak power."""
    if len(t) < 8:
        return float("nan"), float("nan")
    span = float(t.max() - t.min())
    if span <= 0:
        return float("nan"), float("nan")
    hi = min(pmax, span)
    if hi <= pmin:
        return float("nan"), float("nan")
    yy = y - y.mean()
    if np.std(yy) == 0:
        return float("nan"), float("nan")
    periods = np.logspace(math.log10(pmin), math.log10(hi), n)
    try:
        power = lombscargle(t, yy, 2 * np.pi / periods, normalize=True)
    except Exception:
        return float("nan"), float("nan")
    i = int(np.argmax(power))
    return float(periods[i]), float(power[i])


def band_stats(t, y, tag, do_period=True):
    """Variability statistics for one band."""
    f = {}
    n = len(y)
    f[f"{tag}_n"] = n
    keys = ("mean", "amp", "std", "mad", "iqr", "skew", "kurt", "abbe",
            "stetson", "span", "mad_succ", "p", "ppow")
    if n < 3:
        for k in keys:
            f[f"{tag}_{k}"] = float("nan")
        return f
    med = float(np.median(y))
    f[f"{tag}_mean"] = float(np.mean(y))
    # 5th-95th percentile rather than max-min: one cosmic ray should not define
    # the amplitude of a light curve.
    f[f"{tag}_amp"] = float(np.percentile(y, 95) - np.percentile(y, 5))
    f[f"{tag}_std"] = float(np.std(y, ddof=1))
    f[f"{tag}_mad"] = float(np.median(np.abs(y - med)))
    f[f"{tag}_iqr"] = float(np.percentile(y, 75) - np.percentile(y, 25))
    f[f"{tag}_skew"] = float(skew(y))
    f[f"{tag}_kurt"] = float(kurtosis(y))
    f[f"{tag}_abbe"] = abbe(y)
    f[f"{tag}_stetson"] = stetson_j(y)
    f[f"{tag}_span"] = float(t.max() - t.min()) if len(t) else float("nan")
    f[f"{tag}_mad_succ"] = float(np.median(np.abs(np.diff(y))))
    p, pw = ls_period(t, y) if do_period else (float("nan"), float("nan"))
    f[f"{tag}_p"] = p
    f[f"{tag}_ppow"] = pw
    return f


def extract(cells):
    """Feature dict for one epoch_photometry row, or None if unusable."""
    try:
        sid = int(cells[C_SOURCE_ID])
    except (ValueError, IndexError):
        return None
    tg, g = paired(cells[C_G_TIME], cells[C_G_MAG])
    tb, b = paired(cells[C_BP_TIME], cells[C_BP_MAG])
    tr, r = paired(cells[C_RP_TIME], cells[C_RP_MAG])
    if len(g) < 5 and len(b) < 5 and len(r) < 5:
        return None
    f = {"source_id": sid}
    f.update(band_stats(tg, g, "g", do_period=True))
    f.update(band_stats(tb, b, "bp", do_period=False))
    f.update(band_stats(tr, r, "rp", do_period=False))
    f["bp_rp_colour"] = (f["bp_mean"] - f["rp_mean"]
                         if f["bp_n"] >= 3 and f["rp_n"] >= 3 else float("nan"))
    f["amp_ratio_bp_rp"] = (f["bp_amp"] / f["rp_amp"]
                            if f["rp_n"] >= 3 and f["rp_amp"] > 0 else float("nan"))
    # ESA's own per-epoch rejection rates, used here as features rather than as
    # a prediction target.
    f["rej_g"] = reject_frac(cells[C_VAR_G_REJ])
    f["rej_bp"] = reject_frac(cells[C_VAR_BP_REJ])
    f["rej_rp"] = reject_frac(cells[C_VAR_RP_REJ])
    return f


def feature_vector(f):
    """Feature dict -> list in FEATURES order."""
    return [f.get(k, float("nan")) for k in FEATURES]
