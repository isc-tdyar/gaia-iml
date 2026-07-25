/// The Gaia quality table as an RLM decomposition source.
///
/// This is the whole of what the prototype's Gaia.RLM knew about the data: six
/// dimensions, a peek, a way to render one, and the rule for when a slice is still
/// too mixed to summarize in a sentence. The recursion, the budget, the trace and
/// the report all moved to rlm-core, and none of them appear here -- which is the
/// test of whether RLM.Source is the right contract. If a recursion concern had to
/// leak back into this class, the split would be in the wrong place.
///
/// Reads SQLUser.GaiaQualityScored, the table ^RunScript writes with both NGBoost
/// predictions materialized as stored columns. Slicing must never call PREDICT()
/// itself: in an aggregate or an ORDER BY the model is re-invoked per row
/// comparison and the query effectively never returns.
///
/// The data never reaches a prompt. Every method here returns aggregates over a
/// slice, so the string a model sees is a few hundred characters regardless of
/// whether the slice holds 400 sources or 75,000.
Class Gaia.Source Extends RLM.Source.Table
{

/// Survey-wide STDDEV(reject_fraction), the denominator of the split metric.
/// -1 means not yet computed.
///
/// An instance property, not a class variable. The engine holds one source for the
/// life of a run, so instance scope is run scope; the prototype's class variable
/// survived the run that computed it and went stale the first time an ingest
/// changed the table -- and a stale baseline silently changes every split decision
/// in the next run rather than failing.
Property Baseline As %Numeric [ InitialExpression = -1 ];

/// The row floor for subdividing. Deliberately low: the interesting heterogeneous
/// populations here are the badly-behaved tails, which are small by construction.
Parameter SPLITMINROWS = 400;

Method %OnNew() As %Status
{
    Set sc = ##super("User.GaiaQualityScored", "reject_fraction")
    If $$$ISERR(sc) { Quit sc }
    Set ..Name = "Gaia DR3 quality-scored sources"

    // Every status is checked. A dimension that failed to declare would otherwise
    // leave the store advertising five dimensions where the report says six, and
    // the only symptom would be a decomposition that never chose the missing one.
    Set sc = ..AddBucketedDimension("reject_level", "rejectfraction",
        $ListBuild(0.05, 0.20, 0.50),
        $ListBuild(
            "clean (ESA rejected under 5% of epochs)",
            "moderate (5-20% rejected)",
            "heavy (20-50% rejected)",
            // "over half" spelled as 50% as well: every other label carries its
            // boundary as a number, and a reader comparing two children should not
            // have to convert one of them.
            "severe (50%+ rejected -- over half of all epochs)"))
    If $$$ISERR(sc) { Quit sc }

    Set sc = ..AddBucketedDimension("epoch_count", "nbp",
        $ListBuild(5, 20, 60),
        $ListBuild(
            "very few epochs (under 5 in BP)",
            "few epochs (5-19 in BP)",
            "well sampled (20-59 in BP)",
            "densely sampled (60+ in BP)"))
    If $$$ISERR(sc) { Quit sc }

    Set sc = ..AddBucketedDimension("signal_quality", "bpsnr",
        $ListBuild(50, 200, 1000),
        $ListBuild(
            "very low SNR (under 50)",
            "low SNR (50-199)",
            "good SNR (200-999)",
            "high SNR (1000+)"))
    If $$$ISERR(sc) { Quit sc }

    Set sc = ..AddBucketedDimension("model_confidence", "predsigma",
        $ListBuild(0.04, 0.08, 0.15),
        $ListBuild(
            "model confident (sigma under 0.04)",
            "model moderately confident (sigma 0.04-0.08)",
            "model unsure (sigma 0.08-0.15)",
            "model very unsure (sigma 0.15+)"))
    If $$$ISERR(sc) { Quit sc }

    // The prototype's boundaries were `>` and these buckets are `>=`, which is a
    // different partition in general. Here it is the same one: no row holds
    // pct_change exactly equal to 100, 1,000 or 100,000, verified rather than
    // assumed -- `> 100` and `>= 100` both return 57,099.
    Set sc = ..AddBucketedDimension("variability", "pctchange",
        $ListBuild(100, 1000, 100000),
        $ListBuild(
            "not variable (swing under 100%)",
            "variable, modest swing (100-1000%)",
            "variable, large swing (1000-100000%)",
            "extreme swing (over 100000%, almost certainly instrumental)"))
    If $$$ISERR(sc) { Quit sc }

    // The sixth dimension, which the prototype did not have and needed.
    //
    // Triage asks about the sources whose flux swing exceeds 100% -- the binary
    // question the challenge itself asks. In the prototype that population was the
    // union of variability's upper three buckets, and a union of siblings is not
    // nameable: the slice grammar names one child per dimension by construction,
    // which is what makes every name a model produces resolvable. Giving the
    // population its own dimension is how it becomes nameable without weakening
    // that guarantee. variability stays available to subdivide it by swing size.
    Set sc = ..AddBucketedDimension("detection", "pctchange",
        $ListBuild(100),
        $ListBuild(
            "not a detection (flux swing under 100%)",
            "variable-star detection (flux swing over 100%)"))
    Quit sc
}

/// The dimension whitelist, with each dimension's own sentence of prose.
///
/// The library emits the property name as a dimension's label, because that is all
/// AddBucketedDimension is told. The prototype's dimensions each carried a sentence
/// explaining what the dimension means, RLM.Slice.Menu renders `spec.label` exactly
/// where that sentence belongs, and there is no declared slot for it -- so it is
/// written in here. Children are left untouched: they are the library's, and
/// rewriting them here would be two places to change one label.
Method Dimensions() As %DynamicObject
{
    Set out = ##super()
    Set prose("reject_level") = "how heavily ESA's pipeline rejected the source's "
        _"epochs (the target being modelled)"
    Set prose("epoch_count") = "how many usable epochs the source has, i.e. how "
        _"much evidence each measurement rests on"
    Set prose("signal_quality") = "photometric signal-to-noise, mean flux divided "
        _"by mean flux error"
    Set prose("model_confidence") = "how confident the NGBoost model is in its own "
        _"reject-fraction prediction (its predicted sigma)"
    Set prose("variability") = "the relative flux swing that the challenge itself "
        _"asks about - above 100% is a variable-star detection"
    Set prose("detection") = "whether the source is a variable-star detection at "
        _"all: the 100% flux-swing threshold the challenge asks about"

    Set dim = ""
    For  {
        Set dim = $Order(prose(dim), 1, text)
        Quit:dim=""
        If 'out.%IsDefined(dim) { Continue }
        Set out.%Get(dim).label = text
    }
    Quit out
}

/// Compact numeric profile of one slice: the peek primitive.
///
/// A few hundred characters of aggregates, never rows, so prompt size is
/// independent of how many sources the slice contains.
///
/// Built on the inherited Where(), which decodes the term list the same way
/// NullCount does. Assembling a WHERE clause here as text would let the two
/// disagree about which rows a predicate names -- and the null count exists
/// precisely to reconcile against these counts.
Method Peek(predicate As %String = "") As %DynamicObject
{
    Set where = ..Where(predicate, .args)

    // n_pred alongside n: the prediction columns are materialized by the pipeline,
    // and if that step were ever partial then AVG() would quietly average whatever
    // rows it did reach. A visible count makes an incomplete materialization an
    // obvious discrepancy rather than a silent one.
    Set sql = "SELECT COUNT(*) AS n, COUNT(pred_reject) AS n_pred, "
        _"AVG(reject_fraction) AS avg_rej, "
        _"STDDEV(reject_fraction) AS sd_rej, MIN(reject_fraction) AS min_rej, "
        _"MAX(reject_fraction) AS max_rej, AVG(pred_reject) AS avg_pred, "
        _"AVG(pred_sigma) AS avg_sigma, MAX(pred_sigma) AS max_sigma, "
        _"AVG(n_bp) AS avg_n_bp, MIN(n_bp) AS min_n_bp, AVG(bp_snr) AS avg_snr, "
        _"AVG(bp_cv) AS avg_cv, MAX(pct_change) AS max_pct, "
        _"SUM(CASE WHEN pct_change > 100 THEN 1 ELSE 0 END) AS n_variable, "
        _"SUM(CASE WHEN bp_min < 1 OR rp_min < 1 THEN 1 ELSE 0 END) AS n_nearzero "
        _"FROM "_..SQLTable()_where

    Set rs = ..Query(sql, .sc, args)
    // An error comes back inside the peek rather than as an exception: a failed
    // peek costs the run one call, not the report.
    If $$$ISERR(sc) { Quit {"error": ($System.Status.GetErrorText(sc))} }
    If 'rs.%Next() { Quit {"error": "aggregate returned no row"} }

    // An empty slice returns n and nothing else, so Describe can say the slice is
    // empty instead of rendering AVG(NULL) as a measurement of zero.
    If +rs.%Get("n") = 0 { Quit {"n": 0, "capped": 0} }

    // capped is 0 rather than absent: the disclosure rules read it, and an absent
    // key reads as an unanswered question rather than a "no". The query is a full
    // aggregate and is never TOP-limited, so the answer is always no.
    Set peek = {"capped": 0}
    Set md = rs.%GetMetadata()
    For c = 1:1:md.columns.Count() {
        Set name = $ZConvert(md.columns.GetAt(c).colName, "L")
        Set value = rs.%GetData(c)
        Set:value="" value = 0
        Do peek.%Set(name, +value)
    }
    Quit peek
}

/// Render a peek as the compact evidence block a single LLM call receives.
///
/// Every line is self-labelling and carries its units. An earlier version used
/// bare labels ("predicted sigma", "coefficient of variation") and the synthesis
/// step cross-quoted one figure under the other's name -- so the names have to be
/// unmistakable at the point the model reads them, and the two warnings below are
/// there because the model conflated those two quantities until told not to.
Method Describe(
	label As %String,
	peek As %DynamicObject) As %String
{
    If peek.error '= "" { Quit "Slice: "_label_$Char(10)_"Unavailable ("_peek.error_")."_$Char(10) }
    If peek.n = 0 {
        Quit "Slice: "_label_$Char(10)_"This slice contains no sources."_$Char(10)
    }
    Set r(1) = "sources in slice = "_peek.n
    Set r(2) = "ESA_reject_fraction mean = "_$FNumber(peek."avg_rej",,4)
        _" (sd "_$FNumber(peek."sd_rej",,4)
        _", range "_$FNumber(peek."min_rej",,4)_" to "_$FNumber(peek."max_rej",,4)_")"
    Set r(3) = "NGBoost_predicted_reject_fraction mean = "_$FNumber(peek."avg_pred",,4)
    Set r(4) = "NGBoost_prediction_error (|predicted - ESA|, on the same 0-1 scale) = "
        _$FNumber($ZAbs(peek."avg_rej" - peek."avg_pred"),,4)
    Set r(5) = "NGBoost_predicted_sigma mean = "_$FNumber(peek."avg_sigma",,4)
        _", max = "_$FNumber(peek."max_sigma",,4)
        _" (the model's own error bar, also on the 0-1 scale)"
    Set r(6) = "epochs_BP mean = "_$FNumber(peek."avg_n_bp",,1)_", min = "_peek."min_n_bp"
    Set r(7) = "signal_to_noise_BP mean = "_$FNumber(peek."avg_snr",,1)
    Set r(8) = "coefficient_of_variation_BP mean = "_$FNumber(peek."avg_cv",,4)
        _" (a flux scatter ratio - NOT an uncertainty, and not comparable to sigma)"
    Set r(9) = "sources with flux swing over 100% (variable-star detections) = "_peek."n_variable"
    Set r(10) = "sources with a near-zero minimum flux = "_peek."n_nearzero"
    Set r(11) = "largest flux swing in slice = "_$FNumber(peek."max_pct",,1)_"%"

    Set out = "Slice: "_label_$Char(10)
    For i = 1:1:11 { Set out = out_"- "_r(i)_$Char(10) }
    Quit out
}

/// How mixed the slice still is, as a 0-1 number: its reject-fraction spread
/// relative to the whole survey's.
///
/// Expressed relative to the data rather than as an absolute standard deviation on
/// purpose: an absolute threshold is a magic number that silently stops working the
/// moment the input distribution changes.
///
/// Clamped, because the library documents the metric as 0-1 and RLM.Policy.Greedy
/// size-weights it. The clamp costs something -- two slices both more spread than
/// the survey both report 1 and cannot be ranked against each other -- and it is
/// paid because the port runs RLM.Policy.LLM, as the prototype did, so nothing that
/// depended on ranking them regresses.
Method SplitMetric(peek As %DynamicObject) As %Numeric
{
    // Quoted, every time. `peek.sd_rej` parses as `peek.sd _ rej` -- `_` is
    // concatenation, so an unquoted key with an underscore in it is a reference to
    // a property that does not exist concatenated with an undefined local, and the
    // symptom is <UNDEFINED> rather than a wrong number.
    If peek.error '= "" { Quit 0 }
    If peek."sd_rej" = "" { Quit 0 }
    If ..Baseline < 0 { Do ..ComputeBaseline() }
    If +..Baseline = 0 { Quit 0 }

    // Rounded before it is compared, and this is not cosmetic. IRIS computes
    // STDDEV to ~20 significant digits and two evaluations of the same STDDEV over
    // the same rows do not agree in the last few of them. The whole survey's spread
    // divided by the whole survey's spread therefore comes back as 0.99999999999996
    // rather than 1 -- and ShouldSplit's `>= 1` then declines to split the root,
    // which ends the run before it starts. Six digits is far finer than any real
    // difference in spread and coarse enough that the arithmetic is stable.
    // Unary + on the way out: $FNumber returns a string, and "1.000000" does not
    // compare equal to 1 -- so the clamp below would miss and every caller
    // comparing the metric to a number would be doing a string comparison.
    Set ratio = +$FNumber(peek."sd_rej" / ..Baseline, "", 6)
    Quit $Select(ratio > 1:1, 1:ratio)
}

/// Compute the survey-wide spread once and keep it on the instance.
///
/// Its own method rather than three lines inside SplitMetric because it is a query
/// and SplitMetric is called for every candidate of every decision -- so the one
/// thing worth being sure of is that it happens once, and that is easier to see
/// when the query has a name.
Method ComputeBaseline() As %Status
{
    Set rs = ..Query("SELECT STDDEV(reject_fraction) AS sd FROM "_..SQLTable(), .sc)
    If $$$ISERR(sc) { Set ..Baseline = 0 Quit sc }
    If 'rs.%Next() { Set ..Baseline = 0 Quit $$$OK }
    Set ..Baseline = +rs.%Get("sd")
    Quit $$$OK
}

/// Whether subdividing this slice is worth a model call.
///
/// Two questions kept apart: SplitMetric ranks candidates, this decides whether to
/// spend anything on the winner. A slice is subdivided only when its spread is at
/// least the whole survey's -- slicing bought no homogeneity, so one summary
/// sentence would misrepresent it -- and only if it still has enough rows for the
/// subdivision to say anything.
///
/// `threshold` is declared by RLM.Source and deliberately ignored here. The rule is
/// a ratio against the survey plus a row floor, and there is no scalar a caller
/// could pass that would express it; accepting the argument and quietly honouring
/// it halfway would be worse than ignoring it visibly.
Method ShouldSplit(
	peek As %DynamicObject,
	threshold As %Numeric = 0.15) As %Boolean
{
    If peek.n = "" { Quit 0 }
    If peek.n < ..#SPLITMINROWS { Quit 0 }
    Quit (..SplitMetric(peek) >= 1)
}

/// The two counts readiness is decided from.
///
/// Separate from Ready() so a test can substitute them: the two refusals describe a
/// store mid-load, and the only way to produce those states on the real table is to
/// destroy the pipeline's output.
Method Counts(
	Output n As %Integer,
	Output nPred As %Integer) As %Status
{
    Set n = 0, nPred = 0
    Set rs = ..Query("SELECT COUNT(*) AS n, COUNT(pred_reject) AS np FROM "
        _..SQLTable(), .sc)
    If $$$ISERR(sc) { Quit sc }
    If 'rs.%Next() { Quit $$$OK }
    Set n = +rs.%Get("n"), nPred = +rs.%Get("np")
    Quit $$$OK
}

/// Is the store worth starting a run against?
///
/// Its own small COUNT rather than a peek, because the engine calls this before the
/// root peek precisely because that peek is the expensive call on a store mid-load
/// and the one most likely to fail.
///
/// Two distinguishable refusals rather than one. The remedies differ, and a single
/// message would mislead in whichever case it did not describe -- the prototype
/// conflated them into one `n_pred < n` throw that never fired on an empty table at
/// all.
Method Ready(Output reason As %String) As %Boolean
{
    Set reason = ""
    Set sc = ..Counts(.n, .nPred)
    If $$$ISERR(sc) {
        Set reason = "the store could not be read: "_$System.Status.GetErrorText(sc)
        Quit 0
    }
    If n = 0 {
        Set reason = "SQLUser.GaiaQualityScored is empty -- the ingest has not run; "
            _"run `do ^RunScript` first"
        Quit 0
    }
    If nPred < n {
        Set reason = "only "_nPred_" of "_n_" rows are scored -- the PREDICT step "
            _"ran partially; re-run `do ^RunScript`"
        Quit 0
    }
    Quit 1
}

}
