#!/usr/bin/env python3
"""Unit tests for light-curve feature extraction.

No IRIS and no container: these test the pure-Python module that both the
pre-training step and the ingest pipeline depend on, so a regression here is
caught in a second rather than after a ten-minute rebuild.

Usage: python3 tests/test_lightcurve_features.py
"""
import math
import os
import sys
import unittest

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

import gaia_lightcurve_features as lf


class TestSplitRow(unittest.TestCase):
    """The array columns contain commas, so the row split must respect brackets."""

    def test_plain_row(self):
        self.assertEqual(lf.split_row("a,b,c"), ["a", "b", "c"])

    def test_commas_inside_brackets_are_not_separators(self):
        self.assertEqual(lf.split_row("1,[2,3,4],5"), ["1", "[2,3,4]", "5"])

    def test_multiple_arrays(self):
        self.assertEqual(
            lf.split_row("x,[1,2],[3,4],y"), ["x", "[1,2]", "[3,4]", "y"])

    def test_empty_array(self):
        self.assertEqual(lf.split_row("a,[],b"), ["a", "[]", "b"])


class TestPaired(unittest.TestCase):
    """Time and value must stay positionally aligned when NaNs are dropped."""

    def test_drops_epochs_missing_either_side(self):
        t, y = lf.paired("[1,2,3,4]", "[10,NaN,30,40]")
        np.testing.assert_array_equal(t, [1.0, 3.0, 4.0])
        np.testing.assert_array_equal(y, [10.0, 30.0, 40.0])

    def test_alignment_is_positional_not_independent(self):
        # If NaNs were dropped from each array independently, time 3 would be
        # paired with value 40 instead of 30.
        t, y = lf.paired("[1,NaN,3,4]", "[10,20,NaN,40]")
        np.testing.assert_array_equal(t, [1.0, 4.0])
        np.testing.assert_array_equal(y, [10.0, 40.0])

    def test_all_nan(self):
        t, y = lf.paired("[NaN,NaN]", "[NaN,NaN]")
        self.assertEqual(len(t), 0)
        self.assertEqual(len(y), 0)


class TestRejectFrac(unittest.TestCase):
    def test_counts_true_over_total(self):
        self.assertAlmostEqual(lf.reject_frac("[true,false,false,false]"), 0.25)

    def test_all_false_is_zero_not_missing(self):
        self.assertEqual(lf.reject_frac("[false,false]"), 0.0)

    def test_no_flags_is_nan(self):
        # An empty flag array means "ESA said nothing", which is not the same as
        # "ESA rejected nothing" and must not silently become 0.0.
        self.assertTrue(math.isnan(lf.reject_frac("[]")))


class TestAbbe(unittest.TestCase):
    """Abbe/von Neumann eta: ~1 for white noise, well below 1 when smooth."""

    def test_white_noise_near_one(self):
        y = np.random.default_rng(0).normal(0, 1, 400)
        self.assertGreater(lf.abbe(y), 0.8)
        self.assertLess(lf.abbe(y), 1.2)

    def test_smooth_ramp_well_below_one(self):
        self.assertLess(lf.abbe(np.linspace(0, 1, 200)), 0.1)

    def test_constant_is_nan(self):
        self.assertTrue(math.isnan(lf.abbe(np.ones(10))))

    def test_too_short_is_nan(self):
        self.assertTrue(math.isnan(lf.abbe(np.array([1.0, 2.0]))))


class TestLombScargle(unittest.TestCase):
    def test_recovers_a_known_period(self):
        rng = np.random.default_rng(1)
        true_p = 3.5
        t = np.sort(rng.uniform(0, 200, 120))
        y = np.sin(2 * np.pi * t / true_p) + rng.normal(0, 0.05, t.size)
        p, power = lf.ls_period(t, y)
        self.assertAlmostEqual(p, true_p, delta=0.05)
        self.assertGreater(power, 0.5)

    def test_too_few_epochs_is_nan(self):
        p, power = lf.ls_period(np.arange(4.0), np.arange(4.0))
        self.assertTrue(math.isnan(p))
        self.assertTrue(math.isnan(power))

    def test_constant_signal_is_nan(self):
        t = np.linspace(0, 100, 50)
        p, _ = lf.ls_period(t, np.ones_like(t))
        self.assertTrue(math.isnan(p))


class TestBandStats(unittest.TestCase):
    def test_short_series_yields_nan_but_keeps_count(self):
        f = lf.band_stats(np.array([1.0]), np.array([5.0]), "g")
        self.assertEqual(f["g_n"], 1)
        self.assertTrue(math.isnan(f["g_amp"]))

    def test_amplitude_is_percentile_based_not_minmax(self):
        # A single outlier must not define the amplitude.
        y = np.concatenate([np.full(99, 10.0), [1000.0]])
        t = np.arange(y.size, dtype=float)
        f = lf.band_stats(t, y, "g", do_period=False)
        self.assertLess(f["g_amp"], 1.0)

    def test_period_skipped_when_disabled(self):
        rng = np.random.default_rng(2)
        t = np.sort(rng.uniform(0, 100, 50))
        y = np.sin(2 * np.pi * t / 5.0)
        self.assertTrue(math.isnan(lf.band_stats(t, y, "bp", do_period=False)["bp_p"]))
        self.assertFalse(math.isnan(lf.band_stats(t, y, "g", do_period=True)["g_p"]))


class TestFeatureVector(unittest.TestCase):
    def test_length_and_order_match_FEATURES(self):
        f = {k: float(i) for i, k in enumerate(lf.FEATURES)}
        v = lf.feature_vector(f)
        self.assertEqual(len(v), len(lf.FEATURES))
        self.assertEqual(v, [float(i) for i in range(len(lf.FEATURES))])

    def test_missing_key_becomes_nan_not_error(self):
        v = lf.feature_vector({})
        self.assertEqual(len(v), len(lf.FEATURES))
        self.assertTrue(all(math.isnan(x) for x in v))

    def test_feature_list_has_no_duplicates(self):
        self.assertEqual(len(lf.FEATURES), len(set(lf.FEATURES)))


class TestTrainingSet(unittest.TestCase):
    """The committed training set must match the module's feature contract."""

    @classmethod
    def setUpClass(cls):
        import csv
        import gzip
        p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                         "variable_type_train.csv.gz")
        if not os.path.exists(p):
            raise unittest.SkipTest("variable_type_train.csv.gz not present")
        with gzip.open(p, "rt") as fh:
            cls.rows = list(csv.DictReader(fh))

    def test_columns_match_feature_list(self):
        cols = set(self.rows[0].keys())
        for f in lf.FEATURES:
            self.assertIn(f, cols, f"training set is missing feature {f}")
        self.assertIn("var_class", cols)

    def test_every_row_has_a_label(self):
        self.assertTrue(all(r["var_class"] for r in self.rows))

    def test_at_least_two_classes_and_none_dominant(self):
        from collections import Counter
        c = Counter(r["var_class"] for r in self.rows)
        self.assertGreaterEqual(len(c), 2)
        # Balanced by construction; guard against a resample that skews it.
        self.assertLess(max(c.values()) / len(self.rows), 0.5)


if __name__ == "__main__":
    unittest.main(verbosity=2)
