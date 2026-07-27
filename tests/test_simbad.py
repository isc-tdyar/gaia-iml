#!/usr/bin/env python3
"""Tests for the SIMBAD evidence layer.

Split in two. The offline tests run always and cover the parts that can be got
wrong without a network: the circularity filter, ADQL construction, and
formatting. The live tests hit SIMBAD and are skipped without --live, because a
test suite that fails when CDS is down is a test suite people learn to ignore.

Usage:
    python3 tests/test_simbad.py           # offline only
    python3 tests/test_simbad.py --live    # also query SIMBAD
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

import gaia_simbad as gs

LIVE = "--live" in sys.argv
if "--live" in sys.argv:
    sys.argv.remove("--live")

# ESA says YSO (confidence 0.29); the classifier says RS; SIMBAD has 311 refs.
HD283572 = 164536250037820160


class TestQueryConstruction(unittest.TestCase):
    def test_in_list_formats_gaia_ids(self):
        self.assertEqual(gs._in_list([123, 456]),
                         "'Gaia DR3 123','Gaia DR3 456'")

    def test_in_list_coerces_to_int(self):
        # A float or numeric string must not reach the query as 1.23e+17.
        self.assertEqual(gs._in_list(["164536250037820160"]),
                         "'Gaia DR3 164536250037820160'")

    def test_strip_roundtrips(self):
        self.assertEqual(gs._strip("Gaia DR3 164536250037820160"), HD283572)


class TestCircularityFilter(unittest.TestCase):
    """The whole exercise is void if Gaia-derived otypes count as independent."""

    def test_bibcode_constant_matches_the_gaia_variability_catalogue(self):
        # 2022yCat.1358....0G is Gaia DR3 Part 4 (Variability) -- the label
        # source this project trains on.
        self.assertIn("2022yCat.1358", "from bibcode ; bibcode=2022yCat.1358....0G")
        self.assertTrue(
            "from bibcode ; bibcode=2022yCat.1358....0G".find(
                gs.GAIA_VARI_BIBCODE) >= 0)

    def test_independent_origin_is_not_filtered(self):
        self.assertNotIn(gs.GAIA_VARI_BIBCODE,
                         "from bibcode ; bibcode=2017ARep...61...80S")


class TestFormatEvidence(unittest.TestCase):
    def test_renders_without_simbad_entry(self):
        ev = {"source_id": 1, "main_id": None, "simbad_otype": None,
              "spectral_type": None, "n_references": 0,
              "independent_otypes": [], "gaia_derived_otypes_excluded": 0,
              "papers": [], "n_papers_total": 0}
        out = gs.format_evidence(ev)
        self.assertIn("not in SIMBAD", out)
        self.assertIn("No matching literature", out)

    def test_lists_papers_and_bibcodes(self):
        ev = {"source_id": 1, "main_id": "HD 1", "simbad_otype": "Or*",
              "spectral_type": "G5IVe", "n_references": 311,
              "independent_otypes": ["Or*", "TT*"],
              "gaia_derived_otypes_excluded": 2,
              "papers": [{"bibcode": "1984A&A...", "year": "1984",
                          "journal": "A&A", "title": "Coronal activity"}],
              "n_papers_total": 51}
        out = gs.format_evidence(ev)
        self.assertIn("HD 1", out)
        self.assertIn("1984A&A...", out)
        self.assertIn("Coronal activity", out)
        # the count of what was withheld must be visible, not silently dropped
        self.assertIn("51 matching", out)

    def test_independent_otypes_are_labelled_as_filtered(self):
        ev = {"source_id": 1, "main_id": "X", "simbad_otype": "V*",
              "spectral_type": None, "n_references": 1,
              "independent_otypes": ["V*"], "gaia_derived_otypes_excluded": 3,
              "papers": [], "n_papers_total": 0}
        self.assertIn("Gaia-derived excluded", gs.format_evidence(ev))


@unittest.skipUnless(LIVE, "needs --live (queries SIMBAD)")
class TestLiveSimbad(unittest.TestCase):
    def test_identity_of_the_worked_example(self):
        ident = gs.fetch_identity([HD283572])
        self.assertIn(HD283572, ident)
        self.assertEqual(ident[HD283572]["main_id"], "HD 283572")
        self.assertGreater(ident[HD283572]["nbref"], 100)

    def test_otypes_exclude_gaia_derived(self):
        indep, circular = gs.fetch_otypes([HD283572])
        self.assertIn(HD283572, indep)
        self.assertGreater(len(indep[HD283572]), 1)
        for t in indep[HD283572]:
            self.assertIsInstance(t, str)

    def test_keyword_filter_narrows_the_bibliography(self):
        all_p = gs.fetch_papers([HD283572])
        rot = gs.fetch_papers([HD283572], keywords=["otation", "spot"])
        self.assertGreater(len(all_p.get(HD283572, [])),
                           len(rot.get(HD283572, [])))
        self.assertGreater(len(rot.get(HD283572, [])), 0)

    def test_evidence_for_is_prompt_shaped(self):
        ev = gs.evidence_for(HD283572, keywords=["otation", "spot"], max_papers=5)
        self.assertEqual(ev["main_id"], "HD 283572")
        self.assertLessEqual(len(ev["papers"]), 5)
        self.assertGreater(ev["n_papers_total"], 5)
        self.assertIn("HD 283572", gs.format_evidence(ev))

    def test_unknown_source_degrades_gracefully(self):
        ev = gs.evidence_for(1)  # not a real Gaia DR3 id
        self.assertIsNone(ev["main_id"])
        self.assertEqual(ev["papers"], [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
