/// Delegating RLM: the same recursive-language-model idea as Gaia.RLM, built on
/// %AI.Agent.SubAgent instead of an ObjectScript recursion.
///
/// Both implementations exist because they answer the same question differently,
/// and the difference is the interesting part.
///
///     Gaia.RLM    ObjectScript owns the recursion. The model picks a dimension
///                 key; Recurse() decides whether to subdivide by comparing the
///                 slice's STDDEV to the survey baseline, and calls itself.
///                 Cost is knowable before the first call. Every run has the
///                 same shape.
///
///     Gaia.RLM2   The model owns the recursion. It is given a slice grammar and
///                 a Delegate tool, and it decides what to explore and how deep.
///                 The shape differs between runs. Cost is bounded but not
///                 predictable.
///
/// What carries over is the property that matters: the data is never in a prompt.
/// The toolset is aggregate-only (Gaia.Tools.Survey), so context is independent of
/// table size in both. What changes is who decides where to look.
///
/// The safety properties stay in ObjectScript rather than moving into the prompt:
///
/// - Slice names are whitelist lookups, not SQL. RLM.Slice resolves
///   `reject_level:b3` against the dimensions Gaia.Source declares and refuses
///   anything that is not a token path, so the model cannot express a predicate at
///   all. That resolver is the library's, and it is the same one Gaia.RLM's engine
///   uses: this class used to carry a second copy of the walk, which is one more
///   place a whitelist could quietly stop being one.
/// - The call budget is enforced here, in TrySpend(), not requested in the prompt.
///   An agent that ignores its instructions still cannot overspend; it gets a
///   refusal and the report records the truncation.
/// - Delegation depth is one. SliceAnalyst gives its child the tools but not
///   another SliceAnalyst, so there is no unbounded spawn.
///
/// Runs as `do ^RLM2Audit`. Both implementations read GaiaQualityScored and write
/// to data/out, so their reports on the same data can be compared directly.
Class Gaia.RLM2 Extends %AI.Agent
{

Parameter PROVIDER = "openai";

Parameter MODEL = "gpt-4o-mini";

Parameter APIKEY = "@{env.OPENAI_API_KEY}";

/// Iterations of the root's agentic loop. Each iteration is one LLM turn, in which
/// the root may call Delegate or one of the survey tools.
Parameter MAXITERATIONS = 12;

/// Hard ceiling on delegations per report. Every delegation is a child agent
/// running its own loop, so this is the number that decides the cost of a run.
///
/// Enforced in TrySpend() rather than stated in the prompt: instructions are a
/// request, and the whole reason to prefer this design over a raw SQL toolset is
/// that the limits do not depend on the model complying.
Parameter MAXCALLS = 6;

/// The store, as the delegating path sees it.
///
/// A fresh Gaia.Source per call rather than a cached one. It is cheap to build --
/// %OnNew only declares dimensions -- and the alternative is process-wide state
/// holding a cached statistical baseline, which is the kind of thing that makes two
/// runs in one session differ.
ClassMethod Store() As Gaia.Source
{
    Quit ##class(Gaia.Source).%New()
}

/// Delegations spent on the current report.
ClassMethod Spent() As %Integer
{
    Quit $Get(^||GaiaRLM2Calls, 0)
}

ClassMethod ResetBudget()
{
    Kill ^||GaiaRLM2Calls, ^||GaiaRLM2Trace, ^||GaiaRLM2Peeks
}

/// Claim one delegation. Returns 0 when the budget is gone, which callers surface
/// to the model as a refusal rather than as an error.
ClassMethod TrySpend() As %Boolean
{
    If ..Spent() >= ..#MAXCALLS { Quit 0 }
    Set ^||GaiaRLM2Calls = ..Spent() + 1
    Quit 1
}

/// Record that a slice was delegated. The model chooses the decomposition, so the
/// trace is the only way to know afterwards what it actually asked for.
ClassMethod Trace(slice As %String, n As %Integer)
{
    Set ^||GaiaRLM2Trace($Increment(^||GaiaRLM2Trace)) = slice_" (n="_n_")"
}

/// Record a peek an analyst made on its own initiative.
///
/// Counted, not traced. An analyst that sub-slices its own slice is doing its job,
/// but listing those peeks next to the delegations made the trace show more lines
/// than the plan had slices, which reads as the budget having been exceeded.
ClassMethod Peeked(slice As %String, n As %Integer)
{
    Set ^||GaiaRLM2Peeks = $Get(^||GaiaRLM2Peeks, 0) + 1
}

ClassMethod PeekCount() As %Integer
{
    Quit $Get(^||GaiaRLM2Peeks, 0)
}

ClassMethod TraceText() As %String
{
    Set out = "", i = ""
    For {
        Set i = $Order(^||GaiaRLM2Trace(i))
        Quit:i=""
        Set out = out_"  "_^||GaiaRLM2Trace(i)_$Char(10)
    }
    Quit out
}

/// Write a report to disk as UTF-8.
///
/// The translate table has to be set explicitly. A %Stream.FileCharacter defaults to
/// the local 8-bit table, and the reports are model-written Markdown full of em
/// dashes and Greek letters, so the default silently replaces them with "?" in the
/// finished file.
ClassMethod WriteReport(outPath As %String, report As %String) As %Status
{
    Set file = ##class(%Stream.FileCharacter).%New()
    $$$ThrowOnError(file.LinkToFile(outPath))
    Set file.TranslateTable = "UTF8"
    Do file.Write(report)
    Quit file.%Save()
}

/// Turn the root's free-text plan into a $List of slice names worth spawning for.
///
/// The plan is the model's, so it arrives as prose, bullets, backticks or all three,
/// and may name slices that do not exist. Everything here is filtering: each
/// candidate has to resolve against RLM.Slice, duplicates are dropped, and the
/// result is capped at MAXCALLS before the first spawn rather than being refused
/// after the last one. An unusable answer falls back to the first dimension's
/// children, so a report still gets written.
ClassMethod ParsePlan(text As %String) As %List
{
    Set plan = "", seen = "", store = ..Store()
    // Commas, newlines and spaces are all plausible separators, so normalize to one.
    Set text = $Translate(text, $Char(10, 13, 9)_",", "    ")
    For i = 1:1:$Length(text, " ") {
        Set cand = $ZStrip($ZConvert($Piece(text, " ", i), "L"), "<>WC", "`'""*-.:;()[]")
        Continue:cand=""
        Continue:'cand[":"
        Continue:$$$ISERR(##class(RLM.Slice).Resolve(store, cand, .w, .l))
        Continue:(","_seen_",")[(","_cand_",")
        Set seen = seen_$Select(seen="":"",1:",")_cand
        Set plan = plan_$ListBuild(cand)
        Quit:$ListLength(plan)>=..#MAXCALLS
    }
    If $ListLength(plan) > 0 { Quit plan }

    // Nothing usable. Fall back to subdividing by the first dimension, which is the
    // decomposition Gaia.RLM would have started from anyway.
    Set dims = store.Dimensions(), it = dims.%GetIterator()
    If 'it.%GetNext(.key, .spec) { Quit "" }
    For c = 1:1:spec.children.%Size() {
        Quit:$ListLength(plan)>=..#MAXCALLS
        Set plan = plan_$ListBuild(key_":"_spec.children.%Get(c - 1).token)
    }
    Quit plan
}

/// Ask the root model which slices to analyze, given the survey-wide statistics and
/// the slice menu. Returns whatever it says; ParsePlan is what makes it safe.
ClassMethod AskForPlan(question As %String, rootDesc As %String) As %String
{
    Set agent = ..%New()
    $$$ThrowOnError(agent.%Init())
    Set agent.SystemPrompt = "You are planning an analysis of Gaia DR3 epoch "
        _"photometry. You will be shown survey-wide statistics and the ways the "
        _"survey can be sliced. Choose at most "_..#MAXCALLS_" slices whose separate "
        _"analysis is most likely to answer the question, and reply with their names "
        _"only, comma-separated, nothing else. Slices may be nested with '/'."
    Set session = agent.CreateSession()
    Set reply = agent.Chat(session, "Analysis question: "_question_$Char(10,10)
        _"Survey-wide statistics:"_$Char(10)_rootDesc_$Char(10,10)
        _"Ways to slice the survey:"_$Char(10)_##class(RLM.Slice).Menu(..Store()))
    Quit reply.Content
}

/// Full run: the model plans the decomposition, then each slice it chose is handed
/// to a SliceAnalyst subagent, then the findings are reduced into the report.
///
/// Never throws. The report is a bonus deliverable, so a missing API key or an LLM
/// outage must not disturb the pipeline that produced result.csv.
ClassMethod Report(outPath As %String = "", question As %String = "", title As %String = "Delegated survey analysis") As %String
{
    Set report = ""
    Try {
        Do ..ResetBudget()

        // Same completeness guard as Gaia.RLM. The report is framed around the
        // NGBoost predictions, so averaging over whichever rows happen to have them
        // would produce a confident and wrong document.
        // The store, not Gaia.RLM. The peek, the description and the slice
        // arithmetic are all Gaia.Source's now, so both implementations read the
        // survey through one class and cannot disagree about what a slice contains.
        Set store = ..Store()
        Set rootPeek = store.Peek()
        If rootPeek.%IsDefined("error") {
            Throw ##class(%Exception.General).%New("Peek failed: "_rootPeek.error)
        }
        If rootPeek.n = 0 { Throw ##class(%Exception.General).%New("GaiaQualityScored is empty") }
        If rootPeek."n_pred" < rootPeek.n {
            Throw ##class(%Exception.General).%New("GaiaQualityScored has predictions for only "
                _rootPeek."n_pred"_" of "_rootPeek.n_" rows - run ^RunScript to completion first")
        }

        Set rootDesc = store.Describe("whole survey", rootPeek)

        // The root. It is the ParentAgent every subagent is spawned from, and it also
        // writes the final report.
        Set agent = ..%New()
        $$$ThrowOnError(agent.%Init())
        Set agent.MaxIterations = ..#MAXITERATIONS

        // PLAN: the model's, not ours. It sees the survey statistics and the slice
        // menu and names the slices worth analyzing separately.
        Set planText = ..AskForPlan(question, rootDesc)
        Set plan = ..ParsePlan(planText)
        Write "  plan: ", $ListToString(plan, ", "), !

        // SPAWN: one SliceAnalyst subagent per planned slice.
        //
        // Called directly rather than added to the root's ToolManager for its model to
        // invoke. %AI.Agent.SubAgent is a %AI.Tool, so that arrangement compiles and
        // reads better, but on 2026.3.0AI Build 126U it hangs: a tool that spawns a
        // child agent never returns when the parent's own loop dispatches it, and only
        // when the child has tools attached. A child with no tools is fine through the
        // parent's loop, and this same child is fine called from here, in about 3
        // seconds. Reported as ai-hub-eap#26; re-check before restructuring.
        Set findings = ""
        For i = 1:1:$ListLength(plan) {
            Set slice = $List(plan, i)
            If '..TrySpend() { Quit }
            // ParsePlan already proved this resolves, so the size is free to record.
            Do ##class(RLM.Slice).Resolve(store, slice, .sliceWhere, .sliceLabel)
            Do ..Trace(slice, store.Peek(sliceWhere).n)
            Set delegate = ##class(Gaia.Tools.SliceAnalyst).%New()
            Set delegate.ParentAgent = agent
            Set answer = delegate.%Invoke("Execute", {"userRequest": (
                "Analyze the slice `"_slice_"`. Peek at it first.")})
            Write "  delegated ", slice, !
            Set findings = findings_"Slice `"_slice_"`: "
                _$Select($IsObject(answer):answer.output, 1:answer)_$Char(10,10)
        }

        // REDUCE: one call that sees the findings, never the data.
        Set agent.SystemPrompt = "You are an astronomer writing the final report for "
            _"an analysis of Gaia DR3 epoch photometry, from findings produced by "
            _"separate analysts who each looked at one slice."
        Set goal = "Analysis question: "_question_$Char(10,10)
            _"Survey-wide statistics for all "_rootPeek.n_" sources:"_$Char(10)
            _rootDesc_$Char(10)
            _"Findings from the slice analysts:"_$Char(10,10)_findings
            _"Write the final report. Return only GitHub-flavored Markdown, no "
            _"preamble, starting with `## "_title_"`. Include:"_$Char(10)
            _"- a short answer to the analysis question up front"_$Char(10)
            _"- a `### What the slices show` section drawing the analysts' findings "
            _"together, noting where they agree and where they conflict"_$Char(10)
            _"- a `### Likely artifacts` section quantifying probable instrumental "
            _"contamination"_$Char(10)
            _"- a `### Where the model is least reliable` section using "
            _"NGBoost_predicted_sigma and NGBoost_prediction_error"_$Char(10,10)
            _"Rules about numbers, which matter more than fluency. Quote only "
            _"figures that appear in the findings above, and keep "
            _"each attached to the exact metric name it was given under: a "
            _"coefficient_of_variation is not a sigma, and a prediction error is not "
            _"a reject fraction. ESA_reject_fraction, "
            _"NGBoost_predicted_reject_fraction, NGBoost_prediction_error and "
            _"NGBoost_predicted_sigma are all on a 0-1 scale; convert correctly if "
            _"you state one as a percentage, and say that you did. Do not compute new "
            _"statistics, and if something cannot be determined from what you were "
            _"given, say so plainly."

        Set session = agent.CreateSession()
        Set response = agent.Chat(session, goal)
        Set body = response.Content

        Set truncated = ""
        If ..Spent() >= ..#MAXCALLS {
            Set truncated = " The delegation budget was fully spent, so the "
                _"exploration stopped where the trace ends rather than where the "
                _"model chose to stop."
        }

        Set report = body_$Char(10,10)
            _"### How this report was produced"_$Char(10,10)
            _"Generated by a delegating recursive language model over "_rootPeek.n
            _" sources. The data was never placed in a prompt: the only way to see it "
            _"was a tool returning aggregate statistics for one slice, so context "
            _"size is independent of table size."_$Char(10,10)
            _"Unlike `Gaia.RLM`, the decomposition here is the model's. It was shown "
            _"the slice grammar and named the slices to analyze; each one was then "
            _"handed to a `%AI.Agent.SubAgent` with the same tools, whose conclusion "
            _"came back as one paragraph. Slice names are whitelist "
            _"lookups rather than SQL, and the "_..#MAXCALLS_"-delegation ceiling is "
            _"enforced in ObjectScript, so neither depends on the model following "
            _"instructions."_truncated_$Char(10,10)
            _"Slices delegated ("_..Spent()_" of "_..#MAXCALLS_" allowed), across "
            _..PeekCount()_" aggregate queries:"
            _$Char(10,10)_"```"_$Char(10)_..TraceText()_"```"_$Char(10)
    }
    Catch ex {
        Set report = "## "_title_$Char(10,10)_"Delegating RLM unavailable: "_ex.DisplayString()
            _$Char(10,10)_"The IntegratedML pipeline and `result.csv` are unaffected."_$Char(10)
    }
    If outPath '= "" { Do ..WriteReport(outPath, report) }
    Quit report
}

/// Entry point: the same data-quality audit Gaia.RLM.Audit() answers, so the two
/// reports are directly comparable.
ClassMethod Audit(outPath As %String = "") As %String
{
    Quit ..Report(outPath,
        "Across this survey, where is the photometry untrustworthy - which "
        _"populations does ESA's pipeline reject most heavily, and where is our own "
        _"quality model least able to predict that?",
        "Survey data-quality audit (delegated)")
}

}
