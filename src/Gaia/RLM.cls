/// Recursive Language Model (RLM) analyst over the Gaia survey tables.
///
/// The tables are far larger than any context window - 74,998 rows in
/// GaiaQualityScored, 57,099 in the result set. Handing an agent a SQL toolset and
/// letting it explore was tried first in Gaia.Analyst and does not work:
/// %AI.Tools.SQL's ListTables alone returns ~50KB of namespace metadata, every
/// tool result is re-sent on each subsequent call, and gpt-4o-mini re-attempts
/// discovery until %AICore raises LoopDetected.
///
/// The RLM pattern inverts that. The data is never *in* the prompt; it stays in
/// SQL, and the language model interacts with it the way a programmer would with
/// a REPL - peek at a summary, decide how to decompose, recurse into each part,
/// then aggregate the answers. Each call sees only a few hundred characters
/// describing its own slice, so context depth is constant no matter how large
/// the table grows.
///
///     ROOT      peek at survey-wide aggregates (never the rows)
///               choose a decomposition from the whitelist
///        |- LEAF(slice 1)   -> finding
///        |- LEAF(slice 2)   -> still heterogeneous, so recurse
///        |     |- LEAF(sub-slice a)
///        |     '- LEAF(sub-slice b)
///        '- LEAF(slice 3)   -> finding
///     REDUCE    synthesize the findings into the report
///
/// Two properties make this safe to put in a shipped pipeline. First, the model
/// never writes SQL: it picks a decomposition *key* from a fixed whitelist (see
/// Dimensions()) and this class owns the predicates, so there is no injection
/// surface and no malformed-query retry loop. Second, cost is bounded before the
/// first call: recursion stops at MAXDEPTH and at MAXCALLS, and every call is a
/// single Chat() round-trip rather than a tool loop, so LoopDetected cannot occur
/// and wall-clock is predictable.
///
/// The recursion is adaptive rather than a fixed fan-out. A slice is subdivided
/// only when its reject-fraction STDDEV is still at least as large as the whole
/// survey's, meaning slicing bought no homogeneity and one summary sentence would
/// misrepresent the slice.
///
/// Reads GaiaQualityScored, the table ^RunScript writes with the two NGBoost
/// predictions materialized as stored columns. Slicing must never call PREDICT()
/// itself: in an aggregate or ORDER BY the model is re-invoked per row-comparison
/// and the query effectively never returns.
Class Gaia.RLM Extends %AI.Agent
{

Parameter PROVIDER = "openai";

Parameter MODEL = "gpt-4o-mini";

Parameter APIKEY = "@{env.OPENAI_API_KEY}";

/// Hard recursion ceiling. Depth 1 is the root's own children.
Parameter MAXDEPTH = 3;

/// Hard ceiling on total LLM calls per report, across all depths. Checked before
/// every call so a wide decomposition cannot blow past it.
///
/// One of these is reserved for the final synthesis and cannot be spent on
/// exploration - see Ask(). A depth-3 recursion over 4-way dimensions can want far
/// more calls than this, so the ceiling is what decides where the recursion
/// stops; the trace in every report records what was reached.
Parameter MAXCALLS = 18;

/// A slice is subdivided when its reject-fraction spread is at least this
/// multiple of the survey-wide spread - when slicing has not made the population
/// any more homogeneous than it was to begin with, so a single summary sentence
/// would misrepresent it.
///
/// Expressed relative to the data rather than as an absolute standard deviation
/// on purpose: an absolute threshold is a magic number that silently stops
/// working the moment the input distribution changes.
Parameter SPLITRATIO = 1.0;

/// ...and only if the slice still has enough rows for the subdivision to say
/// anything. Deliberately low: the interesting heterogeneous populations here are
/// the badly-behaved tails, which are small by construction.
Parameter SPLITMINROWS = 400;

/// Running count of LLM calls for the current report. Reset by Report().
ClassMethod CallCount(increment As %Integer = 0) As %Integer
{
    Set count = $Get(^||GaiaRLMCalls, 0) + increment
    Set ^||GaiaRLMCalls = count
    Quit count
}

/// The decomposition whitelist. The root LLM chooses a key from this list; the
/// SQL predicates are ours, never the model's.
///
/// Each entry: key, a description the model sees, and the child slices with the
/// SQL predicate that defines each one.
ClassMethod Dimensions() As %DynamicObject
{
    Quit {
        "reject_level": {
            "describe": "how heavily ESA's pipeline rejected the source's epochs (the target being modelled)",
            "children": [
                {"token":"clean","label":"clean (ESA rejected under 5% of epochs)","where":"reject_fraction < 0.05"},
                {"token":"moderate","label":"moderate (5-20% rejected)","where":"reject_fraction >= 0.05 AND reject_fraction < 0.20"},
                {"token":"heavy","label":"heavy (20-50% rejected)","where":"reject_fraction >= 0.20 AND reject_fraction < 0.50"},
                {"token":"severe","label":"severe (over half of all epochs rejected)","where":"reject_fraction >= 0.50"}
            ]
        },
        "epoch_count": {
            "describe": "how many usable epochs the source has, i.e. how much evidence each measurement rests on",
            "children": [
                {"token":"veryfew","label":"very few epochs (under 5 in BP)","where":"n_bp < 5"},
                {"token":"few","label":"few epochs (5-19 in BP)","where":"n_bp >= 5 AND n_bp < 20"},
                {"token":"sampled","label":"well sampled (20-59 in BP)","where":"n_bp >= 20 AND n_bp < 60"},
                {"token":"dense","label":"densely sampled (60+ in BP)","where":"n_bp >= 60"}
            ]
        },
        "signal_quality": {
            "describe": "photometric signal-to-noise, mean flux divided by mean flux error",
            "children": [
                {"token":"verylow","label":"very low SNR (under 50)","where":"bp_snr < 50"},
                {"token":"low","label":"low SNR (50-199)","where":"bp_snr >= 50 AND bp_snr < 200"},
                {"token":"good","label":"good SNR (200-999)","where":"bp_snr >= 200 AND bp_snr < 1000"},
                {"token":"high","label":"high SNR (1000+)","where":"bp_snr >= 1000"}
            ]
        },
        "model_confidence": {
            "describe": "how confident the NGBoost model is in its own reject-fraction prediction (its predicted sigma)",
            "children": [
                {"token":"confident","label":"model confident (sigma under 0.04)","where":"pred_sigma < 0.04"},
                {"token":"moderate","label":"model moderately confident (sigma 0.04-0.08)","where":"pred_sigma >= 0.04 AND pred_sigma < 0.08"},
                {"token":"unsure","label":"model unsure (sigma 0.08-0.15)","where":"pred_sigma >= 0.08 AND pred_sigma < 0.15"},
                {"token":"veryunsure","label":"model very unsure (sigma 0.15+)","where":"pred_sigma >= 0.15"}
            ]
        },
        "variability": {
            "describe": "the relative flux swing that the challenge itself asks about - above 100% is a variable-star detection",
            "children": [
                {"token":"stable","label":"not variable (swing under 100%)","where":"pct_change <= 100"},
                {"token":"modest","label":"variable, modest swing (100-1000%)","where":"pct_change > 100 AND pct_change <= 1000"},
                {"token":"large","label":"variable, large swing (1000-100000%)","where":"pct_change > 1000 AND pct_change <= 100000"},
                {"token":"extreme","label":"extreme swing (over 100000%, almost certainly instrumental)","where":"pct_change > 100000"}
            ]
        }
    }
}

/// Compact numeric profile of one slice. This is the "peek" primitive: it returns
/// a few hundred characters of aggregates, never rows, so the prompt size is
/// independent of how many sources the slice contains.
///
/// Returns a %DynamicObject so callers can branch on the numbers (the recursion
/// decision) as well as render them into a prompt.
ClassMethod Peek(where As %String = "1=1") As %DynamicObject
{
    // n_pred is reported alongside n: the two prediction columns are
    // materialized by the pipeline, and if that step were ever partial then AVG()
    // would quietly average whatever rows it did reach. A visible count makes an
    // incomplete materialization an obvious discrepancy instead of a silent one.
    Set sql = "SELECT COUNT(*) AS n, COUNT(pred_reject) AS n_pred, "
        _"AVG(reject_fraction) AS avg_rej, "
        _"STDDEV(reject_fraction) AS sd_rej, MIN(reject_fraction) AS min_rej, "
        _"MAX(reject_fraction) AS max_rej, AVG(pred_reject) AS avg_pred, "
        _"AVG(pred_sigma) AS avg_sigma, MAX(pred_sigma) AS max_sigma, "
        _"AVG(n_bp) AS avg_n_bp, MIN(n_bp) AS min_n_bp, AVG(bp_snr) AS avg_snr, "
        _"AVG(bp_cv) AS avg_cv, MAX(pct_change) AS max_pct, "
        _"SUM(CASE WHEN pct_change > 100 THEN 1 ELSE 0 END) AS n_variable, "
        _"SUM(CASE WHEN bp_min < 1 OR rp_min < 1 THEN 1 ELSE 0 END) AS n_nearzero "
        _"FROM SQLUser.GaiaQualityScored WHERE "_where

    Set rs = ##class(%SQL.Statement).%ExecDirect(, sql)
    Set out = {}
    If rs.%SQLCODE < 0 {
        Set out.error = rs.%Message
        Quit out
    }
    If 'rs.%Next() { Set out.n = 0  Quit out }
    Set cols = rs.%ResultColumnCount
    Set md = rs.%GetMetadata()
    For c = 1:1:cols {
        Set name = $ZConvert(md.columns.GetAt(c).colName, "L")
        Set value = rs.%GetData(c)
        // A slice can legitimately be empty; report 0 rather than "".
        Set:value="" value = 0
        Do out.%Set(name, +value)
    }
    Quit out
}

/// Render a peek as the compact evidence block a single LLM call receives.
ClassMethod Describe(label As %String, peek As %DynamicObject) As %String
{
    If peek.n = 0 {
        Quit "Slice: "_label_$Char(10)_"This slice contains no sources."_$Char(10)
    }
    // Every line is self-labelling and carries its units. An earlier version used
    // bare labels ("predicted sigma", "coefficient of variation") and the
    // synthesis step cross-quoted one figure under the other's name - so the
    // names have to be unmistakable at the point the model reads them.
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

/// One bounded LLM round-trip. Chat(), never Run(): the evidence is already
/// gathered, so a tool loop would add latency and LoopDetected risk for nothing.
/// Returns "" when the call budget is exhausted, which callers treat as "stop
/// recursing" rather than as an error.
///
/// The final synthesis passes reserved=1 to spend the one slot that exploration is
/// not allowed to touch. Without that reservation a deep recursion spends the
/// whole budget on leaves and the report arrives with no synthesis at all - which
/// is the least useful way to run out of budget.
ClassMethod Ask(instructions As %String, prompt As %String, reserved As %Boolean = 0) As %String
{
    Set ceiling = ..#MAXCALLS - $Select(reserved: 0, 1: 1)
    If ..CallCount() >= ceiling { Quit "" }
    Do ..CallCount(1)
    Set agent = ..%New()
    $$$ThrowOnError(agent.%Init())
    Set session = agent.CreateSession()
    Set response = agent.Chat(session, instructions_$Char(10,10)_prompt)
    Quit response.Content
}

/// Survey-wide reject-fraction spread, cached for the duration of a report.
/// The recursion threshold is relative to this, so it is the yardstick against
/// which a slice counts as "still heterogeneous".
ClassMethod BaselineSpread() As %Double
{
    If $Data(^||GaiaRLMBaseline) { Quit ^||GaiaRLMBaseline }
    Set sd = ..Peek("1=1")."sd_rej"
    Set:sd'>0 sd = 1
    Set ^||GaiaRLMBaseline = sd
    Quit sd
}

/// Should this slice be subdivided rather than summarized directly?
/// True only when the slice is both heterogeneous enough that one summary would
/// be misleading and large enough for the split to mean something - and when
/// depth and call budget still allow it.
///
/// Budget check reserves 2 calls: one for the reduce, one so a slice that has
/// decided to split can still afford at least one child.
ClassMethod ShouldRecurse(peek As %DynamicObject, depth As %Integer) As %Boolean
{
    If depth >= ..#MAXDEPTH { Quit 0 }
    If ..CallCount() >= (..#MAXCALLS - 2) { Quit 0 }
    If peek.n < ..#SPLITMINROWS { Quit 0 }
    Quit (peek."sd_rej" >= (..#SPLITRATIO * ..BaselineSpread()))
}

/// Ask the model to choose a decomposition for a slice it has just peeked at.
/// The reply is constrained to a whitelist key; anything unrecognized falls back
/// to the caller's default, so a hallucinated key degrades gracefully instead of
/// failing the run.
ClassMethod ChooseDimension(sliceDesc As %String, exclude As %String = "", default As %String = "epoch_count") As %String
{
    Set dims = ..Dimensions()
    Set menu = "", it = dims.%GetIterator(), valid = ""
    While it.%GetNext(.key, .spec) {
        Continue:(","_exclude_",")[(","_key_",")
        Set menu = menu_"- "_key_": "_spec.describe_$Char(10)
        Set valid = valid_$Select(valid="":"",1:",")_key
    }
    If valid = "" { Quit "" }

    Set instructions = "You are choosing how to break a large astronomical dataset "
        _"into parts for closer analysis. You will be shown summary statistics for "
        _"one slice of the data, and a menu of ways to subdivide it."_$Char(10,10)
        _"Choose the ONE subdivision that is most likely to explain the variation "
        _"within this slice. Reply with the key only - no punctuation, no "
        _"explanation. Valid keys: "_valid

    Set reply = ..Ask(instructions, sliceDesc_$Char(10)_"Available subdivisions:"_$Char(10)_menu)
    // Normalize: the model occasionally wraps the key in backticks or quotes.
    Set reply = $ZStrip($ZConvert(reply, "L"), "<>WC", """'`.")
    If (","_valid_",")[(","_reply_",") { Quit reply }
    // Hallucinated or empty key: fall back to a dimension we know is available.
    If (","_valid_",")[(","_default_",") { Quit default }
    Quit $Piece(valid, ",", 1)
}

/// The recursive step.
///
/// Peek at the slice; if it is heterogeneous enough to warrant it, let the model
/// choose a decomposition, recurse into each child, and return the children's
/// findings. Otherwise summarize this slice in one call and return that.
///
/// `used` carries the dimension keys already consumed on this branch, so a
/// branch never subdivides twice by the same key.
ClassMethod Recurse(label As %String, where As %String, depth As %Integer = 1, used As %String = "", ByRef trace As %String) As %String
{
    Set peek = ..Peek(where)
    If peek.%IsDefined("error") {
        Quit "- **"_label_"**: slice query failed: "_peek.error_$Char(10)
    }
    If peek.n = 0 { Quit "" }

    Set indent = ""
    For i = 1:1:depth { Set indent = indent_"  " }
    Set trace = $Get(trace)_indent_"- "_label_" (n="_peek.n_", sd="_$FNumber(peek."sd_rej",,4)_")"
    Set desc = ..Describe(label, peek)

    If '..ShouldRecurse(peek, depth) {
        Set trace = trace_" -> summarized"_$Char(10)
        Set instructions = "You are an astronomer summarizing one slice of Gaia DR3 "
            _"epoch photometry. Write ONE tight paragraph, at most three sentences, "
            _"about this slice specifically."_$Char(10,10)
            _"Ground every claim in the numbers given. Note when the numbers suggest "
            _"instrumental artifacts rather than real astrophysical variability - a "
            _"near-zero minimum flux makes a relative change explode, and a low epoch "
            _"count means one bad measurement drives the whole result. If "
            _"NGBoost_predicted_sigma is large, say that the model itself is "
            _"uncertain here; if NGBoost_prediction_error is large, say the model is "
            _"actually wrong here, which is a different claim."_$Char(10,10)
            _"Quote only figures listed above, under the exact metric name they were "
            _"given under, and never compute a new one."
        Set finding = ..Ask(instructions, desc)
        If finding = "" {
            // Say so rather than dropping the slice. A silently omitted slice reads
            // as "nothing to report here", which is a different claim entirely.
            Set finding = "not analyzed - the "_..#MAXCALLS_"-call budget was "
                _"exhausted before reaching this slice. Its measured spread was sd "
                _$FNumber(peek."sd_rej",,4)_" over "_peek.n_" sources."
            Set trace = $Extract(trace, 1, *-1)_" (budget exhausted)"_$Char(10)
        }
        Quit "- **"_label_"** (n="_peek.n_"): "_finding_$Char(10)
    }

    // Heterogeneous: let the model decide how to split, then recurse.
    Set dim = ..ChooseDimension(desc, used, "epoch_count")
    If dim = "" {
        Set trace = trace_" -> no dimension left"_$Char(10)
        Quit "- **"_label_"** (n="_peek.n_"): slice is heterogeneous but no unused "
            _"subdivision remains at this depth."_$Char(10)
    }
    Set trace = trace_" -> split by "_dim_$Char(10)

    Set spec = ..Dimensions().%Get(dim)
    Set out = "- **"_label_"** (n="_peek.n_", sd="_$FNumber(peek."sd_rej",,4)
        _") was too heterogeneous to summarize as one population, so it was "
        _"subdivided by `"_dim_"`:"_$Char(10)
    For i = 1:1:spec.children.%Size() {
        Set child = spec.children.%Get(i - 1)
        Set childWhere = "("_where_") AND ("_child.where_")"
        Set childOut = ..Recurse(child.label, childWhere, depth + 1,
            used_$Select(used="":"",1:",")_dim, .trace)
        Continue:childOut=""
        Set out = out_..Indent(childOut)
    }
    Quit out
}

/// Indent every line of a multi-line finding by one Markdown nesting level.
///
/// Every line, including the first: a child that itself split returns several
/// lines, and indenting only the first flattens the whole subtree back to depth 1
/// in the rendered report - the nesting is then invisible exactly where the
/// recursion did the most work.
ClassMethod Indent(text As %String) As %String
{
    Set out = "", rest = text
    While rest '= "" {
        Set nl = $Find(rest, $Char(10))
        If nl = 0 { Set out = out_"  "_rest  Quit }
        Set out = out_"  "_$Extract(rest, 1, nl - 1)
        Set rest = $Extract(rest, nl, *)
    }
    Quit out
}

/// Full RLM run: peek at the survey, let the root choose the first
/// decomposition, recurse, then reduce the collected findings into a report.
///
/// Never throws. The report is a bonus deliverable, so a missing API key or an
/// LLM outage must not disturb the pipeline that produced result.csv.
ClassMethod Report(outPath As %String = "", question As %String = "", rootWhere As %String = "1=1", title As %String = "Recursive survey analysis") As %String
{
    Set report = ""
    Try {
        Kill ^||GaiaRLMCalls, ^||GaiaRLMBaseline
        Set trace = ""
        Set rootPeek = ..Peek(rootWhere)
        If rootPeek.%IsDefined("error") { Throw ##class(%Exception.General).%New("Peek failed: "_rootPeek.error) }
        If rootPeek.n = 0 { Throw ##class(%Exception.General).%New("No rows matched "_rootWhere) }
        // Fail loudly rather than reporting on a partially-predicted table: the
        // whole report is framed around the model's predictions, so silently
        // averaging over the subset that happens to have them would produce a
        // confident and wrong document.
        If rootPeek."n_pred" < rootPeek.n {
            Throw ##class(%Exception.General).%New("GaiaQualityScored has predictions "
                _"for only "_rootPeek."n_pred"_" of "_rootPeek.n_" rows - run ^RunScript "
                _"to completion first")
        }

        Set rootDesc = ..Describe("whole population under study", rootPeek)
        Write "  root peek: n=", rootPeek.n, " sd=", $FNumber(rootPeek."sd_rej",,4), !

        // The root's decomposition choice is the model's, from the whitelist.
        Set dim = ..ChooseDimension(rootDesc_$Char(10)_"Analysis question: "_question, "", "reject_level")
        Write "  root chose: ", dim, !

        Set spec = ..Dimensions().%Get(dim)
        Set findings = ""
        For i = 1:1:spec.children.%Size() {
            Set child = spec.children.%Get(i - 1)
            Set childWhere = "("_rootWhere_") AND ("_child.where_")"
            Set findings = findings_..Recurse(child.label, childWhere, 1, dim, .trace)
        }

        Write "  ", ..CallCount(), " LLM calls used, reducing", !

        // REDUCE: the only call that sees all the findings at once - and it sees
        // findings, not data, so its context stays small however big the table is.
        Set instructions = "You are an astronomer writing the final report for an "
            _"analysis of Gaia DR3 epoch photometry."_$Char(10,10)
            _"You will be given: the analysis question, survey-wide summary "
            _"statistics, and a set of findings about individual slices of the data "
            _"produced by separate analyses. Synthesize them into a coherent report."
            _$Char(10,10)
            _"Return only GitHub-flavored Markdown, no preamble, starting with "
            _"`## "_title_"`. Include:"_$Char(10)
            _"- a short answer to the analysis question up front"_$Char(10)
            _"- a `### What the slices show` section drawing the findings together, "
            _"noting where they agree and where they conflict"_$Char(10)
            _"- a `### Likely artifacts` section quantifying probable instrumental "
            _"contamination"_$Char(10)
            _"- a `### Where the model is least reliable` section using "
            _"NGBoost_predicted_sigma and NGBoost_prediction_error"_$Char(10,10)
            _"Rules about numbers, which matter more than fluency:"_$Char(10)
            _"- Quote only figures that appear verbatim in the material below."_$Char(10)
            _"- When you quote one, keep it attached to the exact metric name it was "
            _"given under. Do not report a coefficient_of_variation as a sigma, or a "
            _"prediction error as a reject fraction - they are different quantities."
            _$Char(10)
            _"- ESA_reject_fraction, NGBoost_predicted_reject_fraction, "
            _"NGBoost_prediction_error and NGBoost_predicted_sigma are all on a 0-1 "
            _"scale. If you state one of them as a percentage, convert it correctly "
            _"and say so."_$Char(10)
            _"- Do not compute new statistics. If something cannot be determined from "
            _"what you were given, say so plainly instead of estimating."

        Set prompt = "Analysis question: "_question_$Char(10,10)
            _"Survey-wide statistics:"_$Char(10)_rootDesc_$Char(10)
            _"The population was decomposed by `"_dim_"`. Findings per slice:"
            _$Char(10,10)_findings

        Set body = ..Ask(instructions, prompt, 1)
        If body = "" { Set body = "## "_title_$Char(10,10)_"Call budget was exhausted before the final synthesis. Slice findings follow."_$Char(10,10)_findings }

        // Append the recursion trace: this is what makes the run auditable, and
        // shows the depth reached rather than claiming a shape.
        Set report = body_$Char(10,10)
            _"### How this report was produced"_$Char(10,10)
            _"Generated by a recursive language model (RLM) pass over "
            _rootPeek.n_" sources. The data was never placed in a prompt: each call "
            _"received only aggregate statistics for its own slice, so context size "
            _"is independent of table size. The root chose to decompose by `"_dim
            _"`; a slice was subdivided further when its own reject-fraction spread "
            _"was still at least "_..#SPLITRATIO_"x the survey-wide spread of "
            _$FNumber(..BaselineSpread(),,4)_" - i.e. when slicing had not made the "
            _"population any more homogeneous - to a maximum depth of "_..#MAXDEPTH_"."
            _$Char(10,10)_"Recursion taken ("_..CallCount()
            _" LLM calls, ceiling "_..#MAXCALLS_"):"_$Char(10,10)
            _"```"_$Char(10)_trace_"```"_$Char(10)
    }
    Catch ex {
        Set report = "## "_title_$Char(10,10)_"RLM analyst unavailable: "_ex.DisplayString()
            _$Char(10,10)_"The IntegratedML pipeline and `result.csv` are unaffected."_$Char(10)
    }
    // UTF-8 explicitly: the default 8-bit table turns the model's em dashes and
    // Greek letters into "?" in the finished file.
    If outPath '= "" { Do ##class(Gaia.RLM2).WriteReport(outPath, report) }
    Quit report
}

/// Entry point: data-quality audit across the whole survey.
ClassMethod Audit(outPath As %String = "") As %String
{
    Quit ..Report(outPath,
        "Across this survey, where is the photometry untrustworthy - which "
        _"populations does ESA's pipeline reject most heavily, and where is our "
        _"own quality model least able to predict that?",
        "1=1",
        "Survey data-quality audit")
}

/// Entry point: triage of the variable-star detections that result.csv reports.
ClassMethod Triage(outPath As %String = "") As %String
{
    Quit ..Report(outPath,
        "Of the sources flagged as variable by the challenge rule (relative flux "
        _"swing above 100%), which are plausibly genuine variable stars and which "
        _"are instrumental artifacts?",
        "pct_change > 100",
        "Variable-star candidate triage")
}

}
