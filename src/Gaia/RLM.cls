/// Recursive Language Model (RLM) analyst over the Gaia survey tables.
///
/// The tables are far larger than any context window -- 74,998 rows in
/// GaiaQualityScored, 57,099 in the result set. Handing an agent a SQL toolset and
/// letting it explore was tried first in Gaia.Analyst and does not work:
/// %AI.Tools.SQL's ListTables alone returns ~50KB of namespace metadata, every tool
/// result is re-sent on each subsequent call, and gpt-4o-mini re-attempts discovery
/// until %AICore raises LoopDetected.
///
/// The RLM pattern inverts that. The data is never *in* the prompt; it stays in SQL,
/// and the language model interacts with it the way a programmer would with a REPL
/// -- peek at a summary, decide how to decompose, recurse into each part, then
/// aggregate the answers. Each call sees only a few hundred characters describing
/// its own slice, so context depth is constant no matter how large the table grows.
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
/// None of that is implemented here any more. This class was 513 lines and is now
/// three constructions of RLM.Engine: the recursion, the budget arithmetic, the
/// trace, the report assembly and the file write all moved to the rlm-core library,
/// which drives this survey through the same code it drives any other store with.
/// What stays is the domain knowledge -- which questions are worth asking, and where
/// the answers go. The survey's statistics moved too, to Gaia.Source.
///
/// The two properties that made the prototype safe to ship still hold, and now hold
/// because the library enforces them rather than because this class was careful. The
/// model never writes SQL: it names a dimension from an enumerated whitelist and
/// RLM.Slice owns the predicates, so there is no injection surface and no
/// malformed-query retry loop. And cost is bounded before the first call: RLM.Budget
/// holds a slot back for the final synthesis, so no amount of exploration can leave
/// a run unable to answer.
///
/// Reads GaiaQualityScored through Gaia.Source, the table ^RunScript writes with the
/// two NGBoost predictions materialized as stored columns. Slicing must never call
/// PREDICT() itself: in an aggregate or ORDER BY the model is re-invoked per
/// row-comparison and the query effectively never returns.
Class Gaia.RLM Extends %RegisteredObject
{

/// Hard recursion ceiling, handed to RLM.Engine.MaxDepth. Depth 1 is the root's own
/// children.
///
/// Still a parameter on this class, and not because it was missed: ^RLMAudit prints
/// it before starting, so a run announces its own ceiling. What changed is what it
/// means. The prototype checked it on every recursion step; it is now read once,
/// handed to the engine, and never consulted again.
Parameter MAXDEPTH = 3;

/// Hard ceiling on total LLM calls per report, across all depths, handed to
/// RLM.Budget.
///
/// One of these is reserved for the final synthesis and cannot be spent on
/// exploration -- that rule is RLM.Budget's now, which is where it belongs, because
/// a run that spends its last call on one more peek has nothing left to answer with.
/// A depth-3 recursion over 4-way dimensions can want far more calls than this, so
/// the ceiling is what decides where the recursion stops; whatever it did not reach
/// is named in the report's own caveats.
Parameter MAXCALLS = 18;

/// The audit's question. A parameter so a test can assert that Audit() and Triage()
/// ask different things without duplicating the prose.
Parameter AUDITQUESTION = "Across this survey, where is the photometry untrustworthy - which populations does ESA's pipeline reject most heavily, and where is our own quality model least able to predict that?";

/// The triage's question.
Parameter TRIAGEQUESTION = "Of the sources flagged as variable by the challenge rule (relative flux swing above 100%), which are plausibly genuine variable stars and which are instrumental artifacts?";

/// One decomposition. The whole of what this class does.
///
/// `rootPath` scopes the run, and it is a slice *name* -- `detection:b1` -- not a
/// WHERE clause. That is the substantive change the port makes: the prototype's
/// Triage handed `pct_change > 100` to its own recursion as a string, and a string
/// that reaches SQL is a string someone can be persuaded to write. The engine
/// resolves the name through RLM.Slice against the dimensions Gaia.Source declares,
/// so a scope the store does not offer is refused before anything is spent.
///
/// `llm` is injectable, which is the only reason any of this is testable. With
/// RLM.LLM.Null the store's arithmetic stays real while the model's answers are
/// fixed, so a report becomes a pure function of the code and two runs can be
/// compared byte for byte. That is also why this class no longer extends %AI.Agent:
/// an entry point that is itself the provider cannot be handed a different one.
///
/// Returns the report text and writes it to `outPath` as a side effect. Not a
/// %Status, though that is the more usual shape: ^RLMAudit prints $Length(report),
/// and a status would print as a one-character document. A failed run is a report
/// saying what failed -- RLM.Engine.Run catches its own failures and writes them
/// into the document, because the caller asked for a document.
ClassMethod Analyze(
	question As %String,
	rootPath As %String = "",
	outPath As %String = "",
	llm As RLM.LLM = "",
	maxCalls As %Integer = {..#MAXCALLS}) As %String
{
    If '$IsObject(llm) { Set llm = ##class(Gaia.LLM.AIHub).%New() }
    Set engine = ##class(RLM.Engine).%New(##class(Gaia.Source).%New(), llm,
        ##class(RLM.Budget).%New(maxCalls))
    Set engine.MaxDepth = ..#MAXDEPTH
    Set engine.ReportStyle = "markdown"
    Set text = engine.Run(question, .traceId, rootPath)
    If outPath '= "" { Do ##class(RLM.Report).WriteTextToFile(text, outPath) }
    Quit text
}

/// Entry point: data-quality audit across the whole survey.
ClassMethod Audit(outPath As %String = "") As %String
{
    Quit ..Analyze(..#AUDITQUESTION, "", outPath)
}

/// Entry point: triage of the variable-star detections that result.csv reports.
///
/// Scoped by name. `detection:b1` is the dimension Gaia.Source declares for exactly
/// this population -- the 57,099 sources whose flux swing exceeds 100%, the binary
/// question the challenge itself asks -- and it exists as its own dimension because
/// the union of variability's upper three buckets is not nameable in the slice
/// grammar.
ClassMethod Triage(outPath As %String = "") As %String
{
    Quit ..Analyze(..#TRIAGEQUESTION, "detection:b1", outPath)
}

}
