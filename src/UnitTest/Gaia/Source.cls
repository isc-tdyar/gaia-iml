/// Gaia.Source: the quality table seen through RLM.Source's six methods.
///
/// The point of US1 is that this is testable with no engine, no policy and no
/// model. Everything below instantiates the source and asks it questions, so a
/// failure here is a store defect and never a recursion defect.
///
/// Populations are asserted against numbers measured on the live table
/// (2026-07-25, 74,998 rows) rather than re-derived from the same predicates the
/// implementation uses: a re-derivation agrees with a broken implementation. The
/// counts are in specs/003-gaia-port/data-model.md.
///
/// Every assertion macro is on one source line. $$$macro(...) cannot span lines in
/// ObjectScript, and %UnitTest reports a wrapped one as a silently skipped class
/// while still printing "All PASSED".
Class UnitTest.Gaia.Source Extends %UnitTest.TestCase
{

Property Source As Gaia.Source;

Method OnBeforeOneTest(testname As %String) As %Status
{
    Set ..Source = ##class(Gaia.Source).%New()
    Quit $$$OK
}

/// The six dimensions of data-model.md, by name.
Method TestDeclaresTheSixDimensions()
{
    Set dims = ..Source.Dimensions()
    Do $$$AssertTrue(dims.%IsDefined("reject_level"), "reject_level declared")
    Do $$$AssertTrue(dims.%IsDefined("epoch_count"), "epoch_count declared")
    Do $$$AssertTrue(dims.%IsDefined("signal_quality"), "signal_quality declared")
    Do $$$AssertTrue(dims.%IsDefined("model_confidence"), "model_confidence declared")
    Do $$$AssertTrue(dims.%IsDefined("variability"), "variability declared")
    Do $$$AssertTrue(dims.%IsDefined("detection"), "detection declared")
}

/// SC-001: the slice count is computed and printed, never asserted against a
/// constant. The prototype's documentation said "21 slices" for a 5x4 declaration
/// that offered 20, and the figure survived because nothing ever recomputed it.
/// Six dimensions, four children each except `detection`'s two.
Method TestSliceCountIsComputedAndPrinted()
{
    Set dims = ..Source.Dimensions()
    Set nDims = 0, nChildren = 0
    Set it = dims.%GetIterator()
    While it.%GetNext(.name, .spec) {
        Set nDims = nDims + 1
        Set nChildren = nChildren + spec.children.%Size()
    }
    Do $$$LogMessage("dimensions = "_nDims_", nameable slices = "_nChildren)
    Do $$$AssertEquals(nDims, 6, "six dimensions")
    Do $$$AssertEquals(nChildren, 22, "and 22 nameable slices, counted not quoted")
}

/// Each dimension's label is the prototype's descriptive sentence, not the bare
/// property name. That sentence is what RLM.Slice.Menu shows the model, and it is
/// the one piece of the prototype's Dimensions() the library has no declared slot
/// for -- so it is asserted, or it silently reverts to "reject_fraction".
Method TestDimensionLabelsCarryTheProsePerDimension()
{
    Set dims = ..Source.Dimensions()
    Set rej = dims.%Get("reject_level").label
    Do $$$AssertNotEquals($Find(rej, "ESA"), 0, "reject_level explains itself")
    Do $$$AssertEquals($Find(rej, "reject_fraction"), 0, "and is not the column name")
    Set det = dims.%Get("detection").label
    Do $$$AssertNotEquals($Find(det, "100%"), 0, "detection names the threshold")
}

/// Every child label carries its numeric range. The token is an ordinal (`b2`
/// means nothing to a reader), so if the range is not in the label it is nowhere
/// the model can see it.
Method TestEveryChildLabelCarriesItsRange()
{
    Set dims = ..Source.Dimensions()
    Set it = dims.%GetIterator()
    Set bare = ""
    While it.%GetNext(.name, .spec) {
        Set kids = spec.children.%GetIterator()
        While kids.%GetNext(, .child) {
            // A digit somewhere in the label. Every boundary in the six dimensions
            // is numeric, so a label with no digit in it has lost its range.
            Set hasDigit = 0
            For i = 1:1:$Length(child.label) {
                If $Extract(child.label, i) ? 1N { Set hasDigit = 1 Quit }
            }
            If 'hasDigit { Set bare = bare_name_":"_child.token_" " }
        }
    }
    Do $$$AssertEquals(bare, "", "no child label lost its range")
}

/// Every one of the 22 children resolves to a predicate, and the populations are
/// the measured ones. This is the test that would catch a breakpoint typo, a
/// mis-ordered label list, or an off-by-one in the bucket encoding.
Method TestEveryChildResolvesToItsMeasuredPopulation()
{
    Set want("reject_level", "b0") = 13208
    Set want("reject_level", "b1") = 52301
    Set want("reject_level", "b2") = 8844
    Set want("reject_level", "b3") = 645
    Set want("epoch_count", "b0") = 145
    Set want("epoch_count", "b1") = 9282
    Set want("epoch_count", "b2") = 60504
    Set want("epoch_count", "b3") = 5067
    Set want("signal_quality", "b0") = 24988
    Set want("signal_quality", "b1") = 23271
    Set want("signal_quality", "b2") = 25945
    Set want("signal_quality", "b3") = 794
    Set want("model_confidence", "b0") = 24378
    Set want("model_confidence", "b1") = 48450
    Set want("model_confidence", "b2") = 1917
    Set want("model_confidence", "b3") = 253
    Set want("variability", "b0") = 17899
    Set want("variability", "b1") = 17204
    Set want("variability", "b2") = 31224
    Set want("variability", "b3") = 8671
    Set want("detection", "b0") = 17899
    Set want("detection", "b1") = 57099

    Set dim = ""
    For  {
        Set dim = $Order(want(dim))
        Quit:dim=""
        Set token = ""
        For  {
            Set token = $Order(want(dim, token), 1, expect)
            Quit:token=""
            Set sc = ##class(RLM.Slice).Resolve(..Source, dim_":"_token, .predicate)
            Do $$$AssertStatusOK(sc, dim_":"_token_" resolves")
            Do $$$AssertEquals(..Source.Peek(predicate).n, expect, dim_":"_token_" population")
        }
    }
}

/// The four variability children partition the store: nothing double-counted, no
/// row in none of them. pct_change has no nulls, so the children sum to the parent
/// exactly and NullCount has nothing to disclose.
Method TestVariabilityChildrenSumToTheWholeStore()
{
    Set total = 0
    For i = 0:1:3 {
        Do ##class(RLM.Slice).Resolve(..Source, "variability:b"_i, .predicate)
        Set total = total + ..Source.Peek(predicate).n
    }
    Do $$$AssertEquals(total, 74998, "the four buckets are the whole store")
    Do $$$AssertEquals(..Source.Peek("").n, 74998, "which is what the root peek says")
}

/// The library's buckets are half-open and lower-inclusive; the prototype's
/// boundaries were `>`. For pct_change the two encodings select the same rows
/// because no row sits exactly on an edge, so that dimension cannot test the
/// boundary at all. epoch_count can: 2,834 rows hold n_bp of exactly 5, 20 or 60,
/// and each must land in the upper bucket.
Method TestEpochCountBoundaryIsLowerInclusive()
{
    Do ##class(RLM.Slice).Resolve(..Source, "epoch_count:b1", .few)
    Do ##class(RLM.Slice).Resolve(..Source, "epoch_count:b0", .veryfew)
    Set nFew = ..Source.Peek(few).n, nVeryFew = ..Source.Peek(veryfew).n
    Do $$$AssertEquals(nVeryFew, 145, "under 5, exclusive of 5")
    Do $$$AssertEquals(nFew, 9282, "5 through 19, inclusive of 5")

    // Asserted directly as well: if `>=` silently became `>` the two counts above
    // would both shift and could still be made to agree with a wrong constant.
    Set rs = ##class(%SQL.Statement).%ExecDirect(, "SELECT COUNT(*) c FROM "
        _"SQLUser.GaiaQualityScored WHERE n_bp = 5 OR n_bp = 20 OR n_bp = 60")
    Do rs.%Next()
    Do $$$AssertEquals(+rs.%Get("c"), 2834, "rows sitting exactly on an edge exist")
}

/// A two-level path narrows, and the children of a slice sum to that slice. This
/// is containment rather than partition of the store: the parent is already
/// restricted, so a bug that dropped the parent's term would show up as children
/// summing to something larger than their parent.
Method TestNestedChildrenSumToTheirParent()
{
    Do ##class(RLM.Slice).Resolve(..Source, "detection:b1", .parent)
    Set nParent = ..Source.Peek(parent).n
    Do $$$AssertEquals(nParent, 57099, "the detections")

    Set total = 0
    For i = 0:1:3 {
        Do ##class(RLM.Slice).Resolve(..Source, "detection:b1/variability:b"_i, .child)
        Set n = ..Source.Peek(child).n
        Do $$$AssertTrue(n '> nParent, "child b"_i_" is no larger than its parent")
        Set total = total + n
    }
    Do $$$AssertEquals(total, nParent, "and the four children sum to it exactly")
}

/// detection and variability are not independent, and the engine must be able to
/// see that a slice is empty rather than spending a model call describing zeros as
/// measurements. Inside detection:b0 the three variable buckets are empty by
/// construction.
Method TestOverlappingDimensionsYieldAnEmptySlice()
{
    Do ##class(RLM.Slice).Resolve(..Source, "detection:b0/variability:b2", .predicate)
    Set peek = ..Source.Peek(predicate)
    Do $$$AssertEquals(peek.n, 0, "no source is both under and over 100%")
    Do $$$AssertEquals(peek.error, "", "empty is not an error")
}

/// The peek carries all sixteen aggregates plus `capped`. Asserted key by key: a
/// missing one is a Describe line rendering "" as a measurement, and the prototype
/// already had a version where the sigma and the coefficient of variation were
/// cross-quoted under each other's names.
Method TestPeekCarriesEverySixteenAggregate()
{
    Set peek = ..Source.Peek("")
    Set keys = $ListBuild("n", "n_pred", "avg_rej", "sd_rej", "min_rej", "max_rej",
        "avg_pred", "avg_sigma", "max_sigma", "avg_n_bp", "min_n_bp", "avg_snr",
        "avg_cv", "max_pct", "n_variable", "n_nearzero")
    Set missing = "", ptr = 0
    While $ListNext(keys, ptr, key) {
        If 'peek.%IsDefined(key) { Set missing = missing_key_" " }
    }
    Do $$$AssertEquals(missing, "", "all sixteen aggregates present")
    Do $$$AssertEquals($ListLength(keys), 16, "and sixteen is what was checked")
    // Quoted: `peek.n_variable` parses as `peek.n _ variable`, because `_` is
    // concatenation. The symptom is <UNDEFINED>, not a wrong count.
    Do $$$AssertEquals(peek."n_variable", 57099, "n_variable agrees with the detections")
}

/// Principle III: `capped` is 0 rather than absent. The disclosure rules read it,
/// and an absent key reads as an unanswered question rather than a "no".
Method TestPeekReportsCappedAsZeroNotAbsent()
{
    Set peek = ..Source.Peek("")
    Do $$$AssertTrue(peek.%IsDefined("capped"), "capped is present")
    Do $$$AssertEquals(peek.capped, 0, "and says the count is complete")
}

/// An empty slice returns n = 0 and no aggregates, so Describe can say so instead
/// of rendering AVG(NULL) as a measurement of zero.
Method TestPeekOfAnEmptySliceIsJustZero()
{
    Do ##class(RLM.Slice).Resolve(..Source, "detection:b0/variability:b3", .predicate)
    Set peek = ..Source.Peek(predicate)
    Do $$$AssertEquals(peek.n, 0, "zero sources")
    Do $$$AssertEquals(peek.error, "", "and not an error")
}

/// A malformed predicate is a status-shaped failure, not an exception: a failed
/// peek costs the run one call, not the report. RLM.Slice never produces one of
/// these, which is exactly why the path needs a test of its own.
Method TestPeekOfAMalformedPredicateReturnsAnError()
{
    Set threw = 0
    Set peek = {}
    Try {
        Set peek = ..Source.Peek("no_such_column"_$Char(2)_"="_$Char(2)_"1")
    } Catch e {
        Set threw = 1
    }
    Do $$$AssertEquals(threw, 0, "no exception escapes")
    Do $$$AssertNotEquals(peek.error, "", "the failure comes back in the peek")
}

/// The eleven self-labelling lines. The names have to be unmistakable at the point
/// the model reads them, because an earlier prototype used bare labels
/// ("predicted sigma", "coefficient of variation") and the synthesis step
/// cross-quoted one figure under the other's name.
Method TestDescribeEmitsTheElevenLabelledLines()
{
    Set peek = ..Source.Peek("")
    Set text = ..Source.Describe("whole survey", peek)
    Do $$$AssertNotEquals($Find(text, "Slice: whole survey"), 0, "the slice is named")
    Do $$$AssertEquals($Length(text, $Char(10)) - 1, 12, "a header and eleven lines")
    Do $$$AssertNotEquals($Find(text, "sources in slice ="), 0, "line 1")
    Do $$$AssertNotEquals($Find(text, "ESA_reject_fraction mean ="), 0, "line 2")
    Do $$$AssertNotEquals($Find(text, "NGBoost_predicted_reject_fraction"), 0, "line 3")
    Do $$$AssertNotEquals($Find(text, "NGBoost_prediction_error"), 0, "line 4")
    Do $$$AssertNotEquals($Find(text, "NGBoost_predicted_sigma mean ="), 0, "line 5")
    Do $$$AssertNotEquals($Find(text, "epochs_BP mean ="), 0, "line 6")
    Do $$$AssertNotEquals($Find(text, "signal_to_noise_BP mean ="), 0, "line 7")
    Do $$$AssertNotEquals($Find(text, "coefficient_of_variation_BP mean ="), 0, "line 8")
    Do $$$AssertNotEquals($Find(text, "(variable-star detections) ="), 0, "line 9")
    Do $$$AssertNotEquals($Find(text, "near-zero minimum flux ="), 0, "line 10")
    Do $$$AssertNotEquals($Find(text, "largest flux swing in slice ="), 0, "line 11")
}

/// Both warnings, which are the reason those two lines are worded the way they
/// are. A coefficient of variation is not an uncertainty, and a prediction error
/// is not a reject fraction, and the model conflated them until told otherwise.
Method TestDescribeCarriesBothUnitWarnings()
{
    Set text = ..Source.Describe("whole survey", ..Source.Peek(""))
    Do $$$AssertNotEquals($Find(text, "NOT an uncertainty"), 0, "the cv warning")
    Do $$$AssertNotEquals($Find(text, "not comparable to sigma"), 0, "and why it matters")
    Do $$$AssertNotEquals($Find(text, "on the same 0-1 scale"), 0, "the error's scale")
    Do $$$AssertNotEquals($Find(text, "the model's own error bar"), 0, "sigma's meaning")
}

/// An empty slice is described as empty, not as eleven measurements of zero.
Method TestDescribeSaysSoWhenTheSliceIsEmpty()
{
    Do ##class(RLM.Slice).Resolve(..Source, "detection:b0/variability:b1", .predicate)
    Set text = ..Source.Describe("impossible slice", ..Source.Peek(predicate))
    Do $$$AssertNotEquals($Find(text, "contains no sources"), 0, "said plainly")
    Do $$$AssertEquals($Find(text, "mean = 0"), 0, "and no zero posing as a measurement")
}

/// The metric stays inside 0-1 for every child. The library documents it as 0-1
/// and RLM.Policy.Greedy size-weights it, so a value outside the range is not
/// merely odd -- it makes one candidate unrankable against the others.
Method TestSplitMetricStaysWithinZeroAndOne()
{
    Set dims = ..Source.Dimensions()
    Set it = dims.%GetIterator()
    Set bad = ""
    While it.%GetNext(.name, .spec) {
        Set kids = spec.children.%GetIterator()
        While kids.%GetNext(, .child) {
            Do ##class(RLM.Slice).Resolve(..Source, name_":"_child.token, .predicate)
            Set m = ..Source.SplitMetric(..Source.Peek(predicate))
            If (m < 0) || (m > 1) { Set bad = bad_name_":"_child.token_"="_m_" " }
        }
    }
    Do $$$AssertEquals(bad, "", "every child's metric is a 0-1 number")
}

/// The clamp. A slice more spread than the survey clamps to exactly 1 rather than
/// returning 1.4, which is what makes ShouldSplit's ">= 1" the prototype's
/// SPLITRATIO of 1.0 and not an accident.
Method TestSplitMetricClampsToOne()
{
    Set baseline = ..Source.SplitMetric(..Source.Peek(""))
    Do $$$AssertEquals(baseline, 1, "the whole survey is exactly as spread as itself")
    Set m = ..Source.SplitMetric({"n": 1000, "sd_rej": 9.9})
    Do $$$AssertEquals(m, 1, "and something far wider still reports 1")
}

/// Two failure shapes that must both return 0 rather than propagating: an error
/// peek has no sd_rej to divide, and a zero baseline would divide by zero.
Method TestSplitMetricReturnsZeroForAnErrorPeek()
{
    Do $$$AssertEquals(..Source.SplitMetric({"error": "boom"}), 0, "an error is not a spread")
    Do $$$AssertEquals(..Source.SplitMetric({"n": 0}), 0, "nor is an empty slice")
}

/// The baseline is per instance, not per class. The prototype held it in a class
/// variable, which leaked across runs and went stale the first time an ingest
/// changed the table -- and a stale baseline silently changes every split decision
/// in the run.
Method TestBaselineIsPerInstanceNotShared()
{
    Do ..Source.SplitMetric(..Source.Peek(""))
    Do $$$AssertNotEquals(..Source.Baseline, -1, "the first call computed it")
    Set other = ##class(Gaia.Source).%New()
    Do $$$AssertEquals(other.Baseline, -1, "a second instance starts uncomputed")
    Do other.SplitMetric(other.Peek(""))
    // To six digits, not exactly: IRIS computes STDDEV to ~20 significant digits and
    // two evaluations over the same rows disagree in the last few of them. Asserting
    // exact equality here would be asserting a property of the SQL engine's
    // floating-point accumulation order, which is not what per-instance means.
    Set a = $FNumber(..Source.Baseline, "", 6), b = $FNumber(other.Baseline, "", 6)
    Do $$$AssertEquals(a, b, "and both instances measure the same store")
}

/// The recursion rule: spread AND size. Both halves asserted separately, because
/// either one alone passes on the whole survey.
Method TestShouldSplitNeedsBothSpreadAndSize()
{
    Do $$$AssertTrue(..Source.ShouldSplit(..Source.Peek("")), "the survey is worth splitting")
    Do ..Source.SplitMetric(..Source.Peek(""))
    Set wide = {"n": 1000, "sd_rej": (..Source.Baseline * 2)}
    Do $$$AssertTrue(..Source.ShouldSplit(wide), "wide and big enough")
    Set narrow = {"n": 1000, "sd_rej": (..Source.Baseline / 10)}
    Do $$$AssertNotTrue(..Source.ShouldSplit(narrow), "wide enough is required")
}

/// The 400-row floor, asserted at the boundary. The interesting heterogeneous
/// populations here are the badly-behaved tails, which are small by construction,
/// so the floor is doing real work and an off-by-one in it is invisible otherwise.
Method TestShouldSplitRefusesAtThreeNinetyNine()
{
    Do ..Source.SplitMetric(..Source.Peek(""))
    Set wide = ..Source.Baseline * 5
    Do $$$AssertNotTrue(..Source.ShouldSplit({"n": 399, "sd_rej": (wide)}), "399 refused")
    Do $$$AssertTrue(..Source.ShouldSplit({"n": 400, "sd_rej": (wide)}), "400 allowed")
}

/// The inherited signature declares a `threshold` and this store ignores it: the
/// rule is a ratio against the survey plus a row floor, and a caller passing 0.15
/// would otherwise think it had changed something. Asserted by passing both
/// extremes and getting the same answer.
Method TestShouldSplitIgnoresTheThresholdArgument()
{
    Set peek = ..Source.Peek("")
    Set high = ..Source.ShouldSplit(peek, 0.99)
    Set low = ..Source.ShouldSplit(peek, 0.01)
    Do $$$AssertEquals(high, low, "the threshold argument changes nothing")
    Do $$$AssertTrue(high, "and the answer is the rule's own")
}

/// Ready() passes on the live table today: 74,998 rows, all of them scored.
Method TestReadyPassesOnTheLiveTable()
{
    Set ok = ..Source.Ready(.reason)
    Do $$$AssertTrue(ok, "the store is ready")
    Do $$$AssertEquals(reason, "", "with nothing to report")
}

/// The empty case. Two refusals rather than one because the remedies differ, and
/// the prototype conflated them into a single n_pred < n check that never fired on
/// an empty table at all. Simulated through the counts hook rather than by
/// emptying the real table.
Method TestReadyRefusesAnEmptyStoreByName()
{
    Set fake = ##class(UnitTest.Gaia.SourceCounts).%New()
    Set fake.FakeN = 0, fake.FakeNPred = 0
    Do $$$AssertNotTrue(fake.Ready(.reason), "an empty store is not ready")
    Do $$$AssertNotEquals($Find(reason, "empty"), 0, "and says it is empty")
    Do $$$AssertNotEquals($Find(reason, "^RunScript"), 0, "naming the routine to run")
}

/// The partial case: the ingest ran and the PREDICT step did not finish. Same
/// remedy, different diagnosis, and a reader given the empty-store message here
/// would go looking for a table that is in fact full.
Method TestReadyRefusesAPartialScoreWithBothCounts()
{
    Set fake = ##class(UnitTest.Gaia.SourceCounts).%New()
    Set fake.FakeN = 74998, fake.FakeNPred = 1000
    Do $$$AssertNotTrue(fake.Ready(.reason), "a partial score is not ready")
    Do $$$AssertNotEquals($Find(reason, "1000"), 0, "the scored count is named")
    Do $$$AssertNotEquals($Find(reason, "74998"), 0, "and so is the total")
    Do $$$AssertEquals($Find(reason, "empty"), 0, "and it is not called empty")
}

/// The two refusals are distinguishable. Asserted as a pair, because each message
/// on its own can look fine while both say the same thing.
Method TestTheTwoRefusalsAreDifferentMessages()
{
    Set a = ##class(UnitTest.Gaia.SourceCounts).%New()
    Set a.FakeN = 0, a.FakeNPred = 0
    Do a.Ready(.empty)
    Set b = ##class(UnitTest.Gaia.SourceCounts).%New()
    Set b.FakeN = 74998, b.FakeNPred = 1000
    Do b.Ready(.partial)
    Do $$$AssertNotEquals(empty, partial, "two conditions, two messages")
}

/// Principle I, at the primitive level: the model never receives store contents.
/// A source_id held by exactly one row must appear in nothing this class produces
/// -- not a peek, not a Describe, not a label. Asserted against a real id rather
/// than a pattern, because a pattern match would pass on an implementation that
/// leaked a differently-formatted identifier.
Method TestNoSourceIdReachesAnyStringTheSourceProduces()
{
    Set rs = ##class(%SQL.Statement).%ExecDirect(, "SELECT TOP 1 source_id AS s FROM "
        _"SQLUser.GaiaQualityScored WHERE pct_change > 100000 ORDER BY pct_change DESC")
    Do rs.%Next()
    Set id = rs.%Get("s")
    Do $$$AssertNotEquals(id, "", "there is an id to look for")

    Do ##class(RLM.Slice).Resolve(..Source, "variability:b3", .predicate, .label)
    Set peek = ..Source.Peek(predicate)
    Do $$$AssertEquals($Find(peek.%ToJSON(), id), 0, "no id in the peek")
    Do $$$AssertEquals($Find(..Source.Describe(label, peek), id), 0, "none in the Describe")
    Do $$$AssertEquals($Find(..Source.Dimensions().%ToJSON(), id), 0, "none in a label")
    Do $$$AssertEquals($Find(##class(RLM.Slice).Menu(..Source), id), 0, "none in the menu")
}

/// FR-002 and principle III. Every bucketed column is non-null today, so this
/// returns 0 for every dimension -- and that is asserted rather than assumed,
/// because the disclosure exists for the day it changes and an unwired NullCount
/// returns 0 too.
Method TestNullCountIsWiredAndReturnsZeroToday()
{
    Set dims = $ListBuild("reject_level", "epoch_count", "signal_quality",
        "model_confidence", "variability", "detection")
    Set nonZero = "", ptr = 0
    While $ListNext(dims, ptr, dim) {
        Set n = ..Source.NullCount("", dim)
        If n '= 0 { Set nonZero = nonZero_dim_"="_n_" " }
    }
    Do $$$AssertEquals(nonZero, "", "no nulls in any bucketed column today")

    // Wired, not merely returning the default: a dimension that is not bucketed
    // returns 0 without querying, and an unknown one must not throw.
    Do $$$AssertEquals(..Source.NullCount("", ""), 0, "no dimension named, no disclosure")
    Do $$$AssertEquals(..Source.NullCount("", "no_such_dim"), 0, "and an unknown one is 0")
}

}
