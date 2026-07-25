/// Unit tests for the delegating RLM (Gaia.RLM2) and its tool layer.
///
/// Everything here runs without an LLM. The point of the design is that the
/// safety properties live in ObjectScript rather than in the prompt, so they can
/// be tested directly: the slice grammar, the whitelist enforcement, the budget
/// ceiling and the trace. Only Report() needs a provider, and that path is
/// covered by ^RLM2Audit rather than here.
///
///     do ##class(%UnitTest.Manager).RunTest("Gaia","/noload/nodelete")
Class UnitTest.Gaia.RLM2 Extends %UnitTest.TestCase
{

Method TestSliceGrammarAcceptsWhitelistedKeys()
{
    Set sc = ##class(Gaia.Slice).Resolve("reject_level:severe", .where, .label)
    Do $$$AssertStatusOK(sc, "reject_level:severe resolves")
    Do $$$AssertNotEquals(where, "", "resolved slice has a predicate")
    Do $$$AssertTrue(where["reject_fraction", "predicate is the whitelisted one")
    Do $$$AssertTrue(label["severe", "label mentions the child")
}

Method TestSliceGrammarRejectsUnknownDimension()
{
    Set sc = ##class(Gaia.Slice).Resolve("no_such_dim:severe", .where, .label)
    Do $$$AssertStatusNotOK(sc, "unknown dimension is rejected")
    Do $$$AssertEquals(where, "", "no predicate is produced for a rejected spec")
}

Method TestSliceGrammarRejectsUnknownChild()
{
    Set sc = ##class(Gaia.Slice).Resolve("reject_level:no_such_band", .where, .label)
    Do $$$AssertStatusNotOK(sc, "unknown child is rejected")
}

/// The whole safety argument. Any attempt to smuggle SQL through the slice
/// string has to fail closed, because the model chooses this string.
Method TestSliceGrammarRejectsInjection()
{
    Set attempts = $ListBuild(
        "reject_level:severe' OR 1=1 --",
        "reject_level:severe; DROP TABLE GaiaQualityScored",
        "1=1",
        "reject_fraction > 0",
        "reject_level:severe AND 1=1",
        "",
        "reject_level",
        "reject_level:")
    For i = 1:1:$ListLength(attempts) {
        Set attempt = $List(attempts, i)
        Set where = "zzz"
        Set sc = ##class(Gaia.Slice).Resolve(attempt, .where, .label)
        Do $$$AssertStatusNotOK(sc, "rejected: "_attempt)
        Do $$$AssertEquals(where, "", "no predicate leaked for: "_attempt)
    }
}

/// Nested slices compose by AND, and each component still comes from the
/// whitelist, so depth cannot widen the grammar.
Method TestSliceGrammarComposesPath()
{
    Set sc = ##class(Gaia.Slice).Resolve("reject_level:severe/epoch_count:few", .where, .label)
    Do $$$AssertStatusOK(sc, "two-level path resolves")
    Do $$$AssertTrue(where["reject_fraction", "keeps the parent predicate")
    Do $$$AssertTrue(where["n_bp", "adds the child predicate")
    Do $$$AssertTrue(where[" AND ", "components are ANDed")
}

Method TestSliceGrammarRejectsRepeatedDimension()
{
    Set sc = ##class(Gaia.Slice).Resolve("reject_level:severe/reject_level:clean", .where, .label)
    Do $$$AssertStatusNotOK(sc, "the same dimension twice is rejected")
}

Method TestSliceGrammarEnforcesDepth()
{
    Set path = "reject_level:severe/epoch_count:few/signal_quality:low/variability:modest"
    Set sc = ##class(Gaia.Slice).Resolve(path, .where, .label)
    Do $$$AssertStatusNotOK(sc, "a path deeper than MAXDEPTH is rejected")
}

/// The menu the model is shown must be exactly the keys the grammar accepts.
/// A drift between the two is how a whitelist quietly stops being one.
Method TestMenuMatchesGrammar()
{
    Set menu = ##class(Gaia.Slice).Menu()
    Set dims = ##class(Gaia.RLM).Dimensions()
    Set it = dims.%GetIterator()
    While it.%GetNext(.key, .spec) {
        Do $$$AssertTrue(menu[key, "menu advertises dimension "_key)
        For i = 1:1:spec.children.%Size() {
            Set token = ##class(Gaia.Slice).ChildToken(spec.children.%Get(i - 1))
            Do $$$AssertTrue(menu[token, "menu advertises child token "_token)
            Set sc = ##class(Gaia.Slice).Resolve(key_":"_token, .w, .l)
            Do $$$AssertStatusOK(sc, "advertised token resolves: "_key_":"_token)
        }
    }
}

/// Child tokens have to be unique within a dimension, otherwise Resolve()
/// silently picks whichever matched first and the model's choice is not the
/// slice it gets.
Method TestChildTokensAreUnique()
{
    Set dims = ##class(Gaia.RLM).Dimensions()
    Set it = dims.%GetIterator()
    While it.%GetNext(.key, .spec) {
        Kill seen
        For i = 1:1:spec.children.%Size() {
            Set token = ##class(Gaia.Slice).ChildToken(spec.children.%Get(i - 1))
            Do $$$AssertNotTrue($Data(seen(token)), "token "_token_" is unique in "_key)
            Set seen(token) = ""
        }
    }
}

/// The budget is enforced in ObjectScript, not requested in the prompt, so an
/// agent that ignores its instructions still cannot overspend.
Method TestBudgetCeilingStopsDelegation()
{
    Do ##class(Gaia.RLM2).ResetBudget()
    Set spent = 0
    For i = 1:1:50 {
        If '##class(Gaia.RLM2).TrySpend() { Quit }
        Set spent = spent + 1
    }
    Do $$$AssertEquals(spent, ##class(Gaia.RLM2).#MAXCALLS, "delegation stops at exactly MAXCALLS")
    Do $$$AssertNotTrue(##class(Gaia.RLM2).TrySpend(), "still refused after the ceiling")
}

Method TestBudgetResets()
{
    Do ##class(Gaia.RLM2).ResetBudget()
    Do $$$AssertTrue(##class(Gaia.RLM2).TrySpend(), "a fresh budget allows a call")
    Do $$$AssertEquals(##class(Gaia.RLM2).Spent(), 1, "one call recorded")
    Do ##class(Gaia.RLM2).ResetBudget()
    Do $$$AssertEquals(##class(Gaia.RLM2).Spent(), 0, "reset clears the count")
}

/// Peek is shared with Gaia.RLM and must stay aggregate-only: the tool returns
/// statistics, never rows, which is what keeps context independent of table size.
Method TestPeekToolReturnsAggregatesOnly()
{
    Set tool = ##class(Gaia.Tools.Survey).%New()
    // %AI.Tool.%Invoke returns the method's own return value, a plain string here.
    Set text = tool.%Invoke("PeekSlice", {"slice": "reject_level:severe"})
    Do $$$AssertTrue(text["sources in slice", "reports a row count")
    Do $$$AssertNotTrue(text["source_id", "does not leak identifiers")
}

Method TestPeekToolRefusesRawPredicate()
{
    Set tool = ##class(Gaia.Tools.Survey).%New()
    Set text = tool.%Invoke("PeekSlice", {"slice": "reject_fraction > 0.5"})
    Do $$$AssertTrue(text["not a valid slice", "raw SQL is refused with an explanation")
}

/// A refusal has to name the valid keys. An agent that gets "invalid" with no
/// menu retries at random and burns the budget.
Method TestRefusalIsActionable()
{
    Set tool = ##class(Gaia.Tools.Survey).%New()
    Set text = tool.%Invoke("PeekSlice", {"slice": "bogus:thing"})
    Do $$$AssertTrue(text["reject_level", "refusal lists the valid dimensions")
}

/// Reports are Markdown written by a model, so they contain em dashes and Greek
/// letters. A file stream defaults to the local 8-bit table, which turns those into
/// "?" - a corruption that only shows up in the finished artifact.
Method TestReportWriteRoundTripsUnicode()
{
    Set path = "/tmp/unittest_rlm2_unicode.md"
    Set text = "## t"_$Char(10,10)_"heavy"_$Char(8212)_"severe, sigma "_$Char(963)_"."
    Do $$$AssertStatusOK(##class(Gaia.RLM2).WriteReport(path, text), "the report writes")
    Set in = ##class(%Stream.FileCharacter).%New()
    Do in.LinkToFile(path)
    Set in.TranslateTable = "UTF8"
    Set back = in.Read(1000)
    Do $$$AssertNotTrue(back["?", "no character was replaced with a question mark")
    Do $$$AssertTrue(back[$Char(8212), "the em dash survives")
    Do $$$AssertTrue(back[$Char(963), "the sigma survives")
    Do ##class(%File).Delete(path)
}

/// The plan is the model's, so it arrives as free text and has to be filtered to
/// slices the grammar accepts before anything is spawned.
Method TestParsePlanKeepsOnlyValidSlices()
{
    Set plan = ##class(Gaia.RLM2).ParsePlan("reject_level:severe, nonsense:thing, epoch_count:few")
    Do $$$AssertEquals($ListLength(plan), 2, "the invalid slice is dropped")
    Do $$$AssertEquals($List(plan, 1), "reject_level:severe", "valid slices survive in order")
    Do $$$AssertEquals($List(plan, 2), "epoch_count:few", "second valid slice survives")
}

/// Models like to answer in prose and in bullets. Neither should change the plan.
Method TestParsePlanToleratesFormatting()
{
    Set text = "Here is my plan:"_$Char(10)_"- `reject_level:severe`"_$Char(10)
        _"1. epoch_count:few."_$Char(10)_"* signal_quality:low"
    Set plan = ##class(Gaia.RLM2).ParsePlan(text)
    Do $$$AssertEquals($ListLength(plan), 3, "bullets, backticks and numbering are stripped")
    Do $$$AssertEquals($List(plan, 1), "reject_level:severe", "backticks removed")
    Do $$$AssertEquals($List(plan, 2), "epoch_count:few", "trailing period removed")
}

Method TestParsePlanDedupes()
{
    Set plan = ##class(Gaia.RLM2).ParsePlan("reject_level:severe, reject_level:severe")
    Do $$$AssertEquals($ListLength(plan), 1, "the same slice is not analyzed twice")
}

/// The budget is a ceiling on spawns, so the plan must be truncated before the
/// first one rather than after the last one is refused.
Method TestParsePlanTruncatesToBudget()
{
    Set text = "reject_level:clean, reject_level:moderate, reject_level:heavy, "
        _"reject_level:severe, epoch_count:veryfew, epoch_count:few, "
        _"epoch_count:sampled, signal_quality:low"
    Set plan = ##class(Gaia.RLM2).ParsePlan(text)
    Do $$$AssertEquals($ListLength(plan), ##class(Gaia.RLM2).#MAXCALLS, "the plan is capped at MAXCALLS")
}

/// An empty or unusable plan must not produce an empty report: the fallback is the
/// same whitelist the model was choosing from.
Method TestParsePlanFallsBackWhenEmpty()
{
    Set plan = ##class(Gaia.RLM2).ParsePlan("I would rather not.")
    Do $$$AssertTrue($ListLength(plan) > 0, "an unusable answer still yields slices")
    For i = 1:1:$ListLength(plan) {
        Set sc = ##class(Gaia.Slice).Resolve($List(plan, i), .w, .l)
        Do $$$AssertStatusOK(sc, "every fallback slice is a valid one")
    }
}

/// %AI.Agent.CreateSubAgent copies the parent's Model into the child, then calls
/// ConfigureSubAgent, so the hook is what decides what the children cost. The root
/// does the planning and the children each summarize one slice, which is the
/// cheaper job, so they should not be on the root's model.
Method TestSubAgentUsesCheaperModel()
{
    Set delegate = ##class(Gaia.Tools.SliceAnalyst).%New()
    Set child = ##class(Gaia.RLM2).%New()
    Set child.Model = ##class(Gaia.RLM2).#MODEL
    Do delegate.ConfigureSubAgent(child)
    Do $$$AssertEquals(child.Model, ##class(Gaia.Tools.SliceAnalyst).#MODEL, "the child is moved onto the analyst model")
    Do $$$AssertNotEquals(##class(Gaia.Tools.SliceAnalyst).#MODEL, ##class(Gaia.RLM2).#MODEL, "which is not the root's model")
}

/// ConfigureSubAgent still has to give the child its tools; a cheaper model with no
/// PeekSlice would answer from nothing.
Method TestSubAgentKeepsItsTools()
{
    Set delegate = ##class(Gaia.Tools.SliceAnalyst).%New()
    Set child = ##class(Gaia.RLM2).%New()
    $$$ThrowOnError(child.%Init())
    Do delegate.ConfigureSubAgent(child)
    Set names = ""
    Set statuses = child.ToolManager.GetToolStatuses()
    For i = 1:1:statuses.%Size() {
        Set names = names_","_statuses.%Get(i - 1).name
    }
    Do $$$AssertTrue(names["PeekSlice", "the child still has the survey toolset")
}

Method TestToolsAreDiscoverable()
{
    Set tool = ##class(Gaia.Tools.Survey).%New()
    Set spec = tool.%Discover()
    Set names = ""
    For i = 1:1:spec.tools.%Size() {
        Set names = names_","_spec.tools.%Get(i - 1).name
    }
    Do $$$AssertTrue(names["PeekSlice", "PeekSlice is advertised")
    Do $$$AssertTrue(names["ListDimensions", "ListDimensions is advertised")
}

/// Delegation is recorded as it happens, so the report can show what the model
/// actually explored rather than asserting a shape.
Method TestTraceRecordsDelegation()
{
    Do ##class(Gaia.RLM2).ResetBudget()
    Do ##class(Gaia.RLM2).Trace("reject_level:severe", 645)
    Do ##class(Gaia.RLM2).Trace("epoch_count:few", 12)
    Set trace = ##class(Gaia.RLM2).TraceText()
    Do $$$AssertTrue(trace["reject_level:severe", "first delegation recorded")
    Do $$$AssertTrue(trace["645", "slice size recorded")
    Do $$$AssertTrue(trace["epoch_count:few", "second delegation recorded")
}

/// An analyst may peek at sub-slices of its own slice, and those peeks are its
/// working, not delegations. Recording them alongside the delegations made the trace
/// claim 8 lines against a 6-slice plan, which reads as a budget violation.
Method TestTraceSeparatesDelegationsFromPeeks()
{
    Do ##class(Gaia.RLM2).ResetBudget()
    Do ##class(Gaia.RLM2).Trace("reject_level:severe", 645)
    Do ##class(Gaia.RLM2).Peeked("reject_level:severe/epoch_count:few", 12)
    Set trace = ##class(Gaia.RLM2).TraceText()
    Do $$$AssertEquals($Length(trace, $Char(10)) - 1, 1, "only the delegation is a trace line")
    Do $$$AssertTrue(trace["reject_level:severe", "the delegated slice is listed")
    Do $$$AssertNotTrue(trace["epoch_count:few", "the analyst's own sub-peek is not")
    Do $$$AssertEquals(##class(Gaia.RLM2).PeekCount(), 1, "sub-peeks are counted separately")
}

}
