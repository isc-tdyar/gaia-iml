/// The published literature about one disputed source, as an RLM decomposition
/// source.
///
/// WHY THIS EXISTS RATHER THAN A LONGER PROMPT
///
/// Gaia.Adjudicator asks a model to weigh what has been published about a star
/// whose classification the classifier and the DR3 catalogue disagree on. For
/// most sources that is a handful of papers and a single Chat() call is the
/// right shape. For the well-studied ones it is not: HD 283572 carries 311
/// references, 72 of them relevant after filtering, and the flat adjudicator
/// handles that by sorting on a relevance score and truncating to the top 20.
///
/// Truncation is the failure this class exists to remove. The score is a
/// keyword heuristic, so the papers it drops are chosen by a rule that has never
/// read them -- and on this data the rule was wrong once already: "rotation"
/// matched galactic rotation curves and maser kinematics, and because those
/// papers are recent they displaced a 1993 paper with the star's own name in the
/// title. Fixing the heuristic made the verdict correct, which is exactly the
/// evidence that the heuristic decides the answer.
///
/// Recursing instead means nothing is dropped. The root peeks at aggregates over
/// all 72 papers -- how they spread across decades, journals and topics -- picks
/// a decomposition, and each leaf reads only its own slice. Context depth stays
/// constant whether a star has six papers or three hundred.
///
/// Reads Gaia.GaiaLiterature, which the adjudicator repopulates from SIMBAD
/// with one source's papers immediately before each run.
///
/// Scoping is by the extent, not by a filter. RLM.Source.Table decomposes a whole
/// class extent and its only WHERE clause is the slice predicate the engine
/// builds, so there is no per-instance restriction hook to hang a source_id on --
/// and the two ways to fake one are both worse than reloading the table.
/// Overriding SQLTable() to return a parenthesised subquery works only for as
/// long as every call site interpolates it the same way, and declaring source_id
/// as a dimension would let a decomposition split by star, which is not a
/// question anyone asked. One source's papers, one table, one run.
Class Gaia.Literature Extends RLM.Source.Table
{

/// The source whose bibliography this instance decomposes. Recorded for the
/// report; the scoping is done by what is in the table.
Property SourceId As %Integer;

/// Papers below this and a slice is summarized rather than subdivided. Low on
/// purpose: a bibliography is small compared with a survey table, and the
/// interesting disagreements are often three papers that contradict each other.
Parameter SPLITMINROWS = 4;

/// `sourceId` is typed %String to match RLM.Source.Table's %OnNew signature --
/// IRIS requires an override to keep the superclass's argument types -- and is
/// used as a number everywhere below.
Method %OnNew(
	sourceId As %String = "",
	unused As %String = "") As %Status
{
    // Gaia.LiteratureRow, not User.GaiaLiterature: the class sets
    // SqlTableName = GaiaLiterature but lives in the Gaia package, so the table
    // is Gaia.GaiaLiterature. RLM.Source.Table is given the *class* name and
    // derives the table from the dictionary, which is the only place the two
    // are reliably connected.
    //
    // Dimensions below are declared with CamelCase *property* names, not the
    // lowercase ones Gaia.Source uses. Both are right: that class decomposes a
    // table created by DDL, where the property really is `rejectfraction`,
    // while this one is a persistent class whose properties are `PubYear` and
    // `ClaimType`. AddDimension validates against %Dictionary.CompiledProperty
    // and the lookup is case-sensitive, so the wrong case fails %OnNew with an
    // empty error status and the source comes back as a string.
    Set sc = ##super("Gaia.LiteratureRow")
    If $$$ISERR(sc) { Quit sc }
    Set ..SourceId = +sourceId
    Set ..Name = "published literature for Gaia DR3 "_(+sourceId)

    // Epoch matters because instrumentation does. A 1960s photographic plate, a
    // 1990s CCD campaign and a 2020s all-sky survey are different kinds of
    // evidence about the same star, and the model is told to weigh them
    // differently. Boundaries are chosen on that, not on round numbers.
    Set sc = ..AddBucketedDimension("epoch", "PubYear",
        $ListBuild(1980, 2000, 2015),
        $ListBuild(
            "photographic era (before 1980)",
            "early CCD era (1980-1999)",
            "digital survey era (2000-2014)",
            "all-sky survey era (2015+)"))
    If $$$ISERR(sc) { Quit sc }

    // What kind of claim the paper makes about why the star varies. Derived when
    // the row is inserted, from the title, so the model never has to be trusted
    // to parse a title into a category.
    Set sc = ..AddDimension("claim", "ClaimType")
    If $$$ISERR(sc) { Quit sc }

    // Targeted study or bulk catalogue. This is the single most useful axis for
    // the weighing rules in Gaia.Adjudicator's instructions: a paper about this
    // star outranks a catalogue that included it among a million others.
    Set sc = ..AddDimension("study_type", "StudyType")
    Quit sc
}

/// Render a slice as the papers it contains, not just how many.
///
/// RLM.Source.Table describes a slice as "label: n=12", optionally with min/max
/// of a numeric measure. That is the right rendering for a survey table, where
/// the aggregate *is* the finding -- 52,301 sources with a mean reject fraction
/// says something on its own. It is the wrong rendering for a bibliography,
/// where the content is the evidence: a leaf told only "targeted: n=60" has
/// nothing to read and will answer from whatever else is in its context, which
/// is exactly what happened before this override existed. The leaves reasoned
/// entirely from the light-curve features in the question and cited no bibcode.
///
/// So a slice is rendered as its papers, oldest first, with the year, journal,
/// bibcode and title. Capped at MAXPAPERSPERSLICE: the cap is what makes the
/// recursion worth having, because a slice that overflows it is a slice the
/// engine should subdivide rather than a list the model should skim.
Method Describe(
	label As %String,
	peek As %DynamicObject) As %String
{
    If peek.error '= "" { Quit label_": unavailable ("_peek.error_")" }
    Set out = label_": "_peek.n_" paper"_$Select(peek.n=1:"", 1:"s")

    Set where = ..Where(..LastPredicate, .args)
    Set sql = "SELECT TOP "_..#MAXPAPERSPERSLICE_" PubYear, Journal, Bibcode, "
        _"Title FROM "_..SQLTable()_where_" ORDER BY PubYear"
    // Query(sql, .sc, args): the status is the SECOND argument and the bound
    // parameters are the third.
    Set rs = ..Query(sql, .sc, args)
    If $$$ISERR(sc) || '$IsObject($Get(rs)) {
        Quit out_" (titles unavailable)"
    }

    Set nl = $Char(10), shown = 0
    While rs.%Next() {
        Set out = out_nl_"    "_rs.PubYear_" "_rs.Journal_" ["_rs.Bibcode_"] "
            _rs.Title
        Set shown = shown + 1
    }
    If peek.n > shown {
        Set out = out_nl_"    ... "_(peek.n - shown)_" more, not shown"
    }
    Quit out
}

/// Papers rendered per slice before the list is truncated. A slice larger than
/// this is one the engine should subdivide.
Parameter MAXPAPERSPERSLICE = 12;

/// The predicate of the most recent Peek(), so Describe() can re-query the same
/// slice for its titles.
///
/// The peek object carries n, capped and the measure summary, but not the
/// predicate that produced them, and Describe() is handed only the peek. The
/// engine calls Peek() then Describe() for the same slice in that order, so
/// recording it here is enough. An instance property rather than anything
/// shared: the engine holds one source per run.
Property LastPredicate As %String;

/// Record the predicate on the way past, then defer to the library.
Method Peek(predicate As %String = "") As %DynamicObject
{
    Set ..LastPredicate = predicate
    Quit ##super(predicate)
}

/// Dimension whitelist with a sentence of prose each, the same way Gaia.Source
/// does it: the library labels a dimension with its property name, which is not
/// what a model should be reading.
Method Dimensions() As %DynamicObject
{
    Set out = ##super()
    Set prose("epoch") = "when the paper was published, which stands in for what "
        _"instrument and method were available to it"
    Set prose("claim") = "what the paper says about why the star varies - "
        _"rotation and starspots, eclipses, pulsation, or something else"
    Set prose("study_type") = "whether the star was the subject of the paper or "
        _"one row in a survey catalogue"

    // Keyed by dimension name, not a numeric array. Indexing it 0..%Size()-1
    // returns null and the run dies with <INVALID OREF> inside this method,
    // which the engine reports as "the analysis stopped early" with no hint
    // that the fault is here.
    Set dim = ""
    For  {
        Set dim = $Order(prose(dim), 1, text)
        Quit:dim=""
        If 'out.%IsDefined(dim) { Continue }
        Set out.%Get(dim).label = text
    }
    Quit out
}

}
