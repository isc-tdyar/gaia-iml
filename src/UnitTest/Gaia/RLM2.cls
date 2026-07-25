/// Unit tests for the delegating RLM (Gaia.RLM2) and its tool layer.
///
/// Everything here runs without an LLM. The point of the design is that the
/// safety properties live in ObjectScript rather than in the prompt, so they can
/// be tested directly: the slice grammar, the whitelist enforcement, the budget
/// ceiling and the trace. Only Report() needs a provider, and that path is
/// covered by ^RLM2Audit rather than here.
///
///     do ##class(%UnitTest.Manager).RunTest("Gaia","/noload/nodelete")
///
/// The grammar tests used to run against Gaia.Slice, a second copy of the same
/// whitelist walk. They now run against RLM.Slice, and every accept/refuse verdict
/// is unchanged -- only the token spelling moved, from the derived word
/// (reject_level:severe) to the library's bucket ordinal (reject_level:b3). A
/// verdict that changed would mean the grammar changed, which is the one thing
/// deleting the duplicate was not allowed to do.
Class UnitTest.Gaia.RLM2 Extends %UnitTest.TestCase
{

/// The store the grammar resolves against.
///
/// RLM.Slice takes it as an argument rather than looking one up, and that is what
/// let the second copy go: the old grammar had to know which class held the
/// whitelist, so it could only ever serve one store.
ClassMethod Store() As Gaia.Source
{
    Quit ##class(Gaia.Source).%New()
}

Method TestSliceGrammarAcceptsWhitelistedKeys()
{
    Set sc = ##class(RLM.Slice).Resolve(..Store(), "reject_level:b3", .where, .label)
    Do $$$AssertStatusOK(sc, "reject_level:b3 resolves")
    Do $$$AssertNotEquals(where, "", "resolved slice has a predicate")
    Do $$$AssertTrue(where["reject_fraction", "predicate is the whitelisted one")
    Do $$$AssertTrue(label["severe", "label mentions the child")
}

Method TestSliceGrammarRejectsUnknownDimension()
{
    Set sc = ##class(RLM.Slice).Resolve(..Store(), "no_such_dim:b3", .where, .label)
    Do $$$AssertStatusNotOK(sc, "unknown dimension is rejected")
    Do $$$AssertEquals(where, "", "no predicate is produced for a rejected spec")
}

Method TestSliceGrammarRejectsUnknownChild()
{
    Set sc = ##class(RLM.Slice).Resolve(..Store(), "reject_level:b9", .where, .label)
    Do $$$AssertStatusNotOK(sc, "unknown child is rejected")
    Do $$$AssertEquals(where, "", "and no predicate leaks")
}

/// SC-006, and the whole safety argument. Any attempt to smuggle SQL through the
/// slice string has to fail closed, because the model chooses this string.
///
/// The empty string is the one case the old list held that is not here: RLM.Slice
/// reads it as the whole store, which is the scope a root already has, so it widens
/// nothing. Every other name the old grammar refused is still refused.
Method TestSliceGrammarRejectsInjection()
{
    Set attempts = $ListBuild(
        "reject_level:b3' OR 1=1 --",
        "reject_level:b3; DROP TABLE GaiaQualityScored",
        "1=1",
        "reject_fraction > 0",
        "reject_level:b3 AND 1=1",
        "reject_level",
        "reject_level:")
    For i = 1:1:$ListLength(attempts) {
        Set attempt = $List(attempts, i)
        Set where = "zzz"
        Set sc = ##class(RLM.Slice).Resolve(..Store(), attempt, .where, .label)
        Do $$$AssertStatusNotOK(sc, "rejected: "_attempt)
        Do $$$AssertEquals(where, "", "no predicate leaked for: "_attempt)
    }
}

/// The injection case on its own, because it is the one a reader comes looking for.
/// The string is refused as a name the store does not offer -- not escaped, not
/// quoted -- and the refusal carries the grammar, so a model can correct itself
/// instead of retrying at random until the budget is gone.
Method TestInjectionIsRefusedAsAnUnknownName()
{
    Set where = "zzz"
    Set sc = ##class(RLM.Slice).Resolve(..Store(), "reject_level:severe' OR 1=1 --", .where, .label)
    Do $$$AssertStatusNotOK(sc, "the injected name is refused")
    Do $$$AssertEquals(where, "", "no query could be built from it")
    Set text = $System.Status.GetErrorText(sc)
    Do $$$AssertTrue(text["store offers", "refused as a name, not as syntax")
    Do $$$AssertTrue(text["dimension", "and the refusal carries the grammar")
}

/// Nested slices compose, and each component still comes from the whitelist, so
/// depth cannot widen the grammar.
///
/// The predicate is the library's encoded term list rather than SQL text -- turning
/// terms into a parameterized WHERE is Gaia.Source's job and is tested there -- so
/// what is asserted here is that both columns are restricted and both children are
/// named.
Method TestSliceGrammarComposesPath()
{
    Set sc = ##class(RLM.Slice).Resolve(..Store(), "reject_level:b3/epoch_count:b1", .where, .label)
    Do $$$AssertStatusOK(sc, "two-level path resolves")
    Do $$$AssertTrue(where["reject_fraction", "keeps the parent predicate")
    Do $$$AssertTrue(where["n_bp", "adds the child predicate")
    Do $$$AssertTrue(label["severe", "the label names the parent")
    Do $$$AssertTrue(label["few epochs", "and the child")
}

Method TestSliceGrammarRejectsRepeatedDimension()
{
    Set sc = ##class(RLM.Slice).Resolve(..Store(), "reject_level:b3/reject_level:b0", .where, .label)
    Do $$$AssertStatusNotOK(sc, "the same dimension twice is rejected")
}

Method TestSliceGrammarEnforcesDepth()
{
    Set path = "reject_level:b3/epoch_count:b1/signal_quality:b1/variability:b1"
    Set sc = ##class(RLM.Slice).Resolve(..Store(), path, .where, .label)
    Do $$$AssertStatusNotOK(sc, "a path deeper than MAXDEPTH is rejected")
}

/// The menu the model is shown must be exactly the keys the grammar accepts.
/// A drift between the two is how a whitelist quietly stops being one.
Method TestMenuMatchesGrammar()
{
    Set store = ..Store()
    Set menu = ##class(RLM.Slice).Menu(store)
    Set dims = store.Dimensions()
    Set it = dims.%GetIterator()
    While it.%GetNext(.key, .spec) {
        Do $$$AssertTrue(menu[key, "menu advertises dimension "_key)
        For i = 1:1:spec.children.%Size() {
            Set token = spec.children.%Get(i - 1).token
            Do $$$AssertTrue(menu[(key_":"_token), "menu advertises "_key_":"_token)
            Set sc = ##class(RLM.Slice).Resolve(store, key_":"_token, .w, .l)
            Do $$$AssertStatusOK(sc, "advertised token resolves: "_key_":"_token)
        }
    }
}

/// Child tokens have to be unique within a dimension, otherwise Resolve() silently
/// picks whichever matched first and the model's choice is not the slice it gets.
Method TestChildTokensAreUnique()
{
    Set dims = ..Store().Dimensions()
    Set it = dims.%GetIterator()
    While it.%GetNext(.key, .spec) {
        Kill seen
        For i = 1:1:spec.children.%Size() {
            Set token = spec.children.%Get(i - 1).token
            Do $$$AssertNotTrue($Data(seen(token)), "token "_token_" is unique in "_key)
            Set seen(token) = ""
        }
    }
}

/// FR-011, by search. One grammar means one place a name can be refused, so no live
/// reference to the deleted class may survive anywhere under src/, and the class
/// itself must be gone from the namespace.
///
/// Comment lines are excluded for the same reason the SC-005 scan excludes them:
/// this class's own doc comment says the tests moved off Gaia.Slice, and naming it
/// while saying so is not a use of it. This file is excluded outright, because the
/// name has to appear in the ban list and in the %ExistsId call below -- a search
/// cannot be its own last hit.
Method TestNoGaiaSliceReferenceRemains()
{
    Set offenders = "", scanned = 0
    Do ..ScanAll("/home/irisowner/dev/src", $ListBuild("Gaia.Slice"), .offenders, .scanned,
        "/home/irisowner/dev/src/UnitTest/Gaia/RLM2.cls")
    Do $$$AssertTrue(scanned > 8, "the walk reached the sources: "_scanned_" file(s)")
    Do $$$AssertEquals(offenders, "", "no live reference to the deleted grammar remains")
    Do $$$AssertNotTrue(##class(%Dictionary.CompiledClass).%ExistsId("Gaia.Slice"), "the class itself is gone")
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

/// The peek tool must stay aggregate-only: it returns statistics, never rows, which
/// is what keeps context independent of table size.
Method TestPeekToolReturnsAggregatesOnly()
{
    Set tool = ##class(Gaia.Tools.Survey).%New()
    // %AI.Tool.%Invoke returns the method's own return value, a plain string here.
    Set text = tool.%Invoke("PeekSlice", {"slice": "reject_level:b3"})
    Do $$$AssertTrue(text["sources in slice", "reports a row count")
    Do $$$AssertNotTrue(text["source_id", "does not leak identifiers")
}

Method TestPeekToolRefusesRawPredicate()
{
    Set tool = ##class(Gaia.Tools.Survey).%New()
    Set text = tool.%Invoke("PeekSlice", {"slice": "reject_fraction > 0.5"})
    Do $$$AssertTrue(text["Refused", "raw SQL is refused")
    Do $$$AssertTrue(text["store offers", "with an explanation")
}

/// A refusal has to name the valid keys. An agent that gets "invalid" with no menu
/// retries at random and burns the budget.
Method TestRefusalIsActionable()
{
    Set tool = ##class(Gaia.Tools.Survey).%New()
    Set text = tool.%Invoke("PeekSlice", {"slice": "bogus:thing"})
    Do $$$AssertTrue(text["dimension", "the refusal states the grammar")
    Set menu = tool.%Invoke("ListDimensions", {})
    Do $$$AssertTrue(menu["reject_level", "and the menu lists the valid dimensions")
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
    Set plan = ##class(Gaia.RLM2).ParsePlan("reject_level:b3, nonsense:thing, epoch_count:b1")
    Do $$$AssertEquals($ListLength(plan), 2, "the invalid slice is dropped")
    Do $$$AssertEquals($List(plan, 1), "reject_level:b3", "valid slices survive in order")
    Do $$$AssertEquals($List(plan, 2), "epoch_count:b1", "second valid slice survives")
}

/// Models like to answer in prose and in bullets. Neither should change the plan.
Method TestParsePlanToleratesFormatting()
{
    Set text = "Here is my plan:"_$Char(10)_"- `reject_level:b3`"_$Char(10)
        _"1. epoch_count:b1."_$Char(10)_"* signal_quality:b1"
    Set plan = ##class(Gaia.RLM2).ParsePlan(text)
    Do $$$AssertEquals($ListLength(plan), 3, "bullets, backticks and numbering are stripped")
    Do $$$AssertEquals($List(plan, 1), "reject_level:b3", "backticks removed")
    Do $$$AssertEquals($List(plan, 2), "epoch_count:b1", "trailing period removed")
}

Method TestParsePlanDedupes()
{
    Set plan = ##class(Gaia.RLM2).ParsePlan("reject_level:b3, reject_level:b3")
    Do $$$AssertEquals($ListLength(plan), 1, "the same slice is not analyzed twice")
}

/// The budget is a ceiling on spawns, so the plan must be truncated before the
/// first one rather than after the last one is refused.
Method TestParsePlanTruncatesToBudget()
{
    Set text = "reject_level:b0, reject_level:b1, reject_level:b2, "
        _"reject_level:b3, epoch_count:b0, epoch_count:b1, "
        _"epoch_count:b2, signal_quality:b1"
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
        Set sc = ##class(RLM.Slice).Resolve(..Store(), $List(plan, i), .w, .l)
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
    Do ##class(Gaia.RLM2).Trace("reject_level:b3", 645)
    Do ##class(Gaia.RLM2).Trace("epoch_count:b1", 12)
    Set trace = ##class(Gaia.RLM2).TraceText()
    Do $$$AssertTrue(trace["reject_level:b3", "first delegation recorded")
    Do $$$AssertTrue(trace["645", "slice size recorded")
    Do $$$AssertTrue(trace["epoch_count:b1", "second delegation recorded")
}

/// An analyst may peek at sub-slices of its own slice, and those peeks are its
/// working, not delegations. Recording them alongside the delegations made the trace
/// claim 8 lines against a 6-slice plan, which reads as a budget violation.
Method TestTraceSeparatesDelegationsFromPeeks()
{
    Do ##class(Gaia.RLM2).ResetBudget()
    Do ##class(Gaia.RLM2).Trace("reject_level:b3", 645)
    Do ##class(Gaia.RLM2).Peeked("reject_level:b3/epoch_count:b1", 12)
    Set trace = ##class(Gaia.RLM2).TraceText()
    Do $$$AssertEquals($Length(trace, $Char(10)) - 1, 1, "only the delegation is a trace line")
    Do $$$AssertTrue(trace["reject_level:b3", "the delegated slice is listed")
    Do $$$AssertNotTrue(trace["epoch_count:b1", "the analyst's own sub-peek is not")
    Do $$$AssertEquals(##class(Gaia.RLM2).PeekCount(), 1, "sub-peeks are counted separately")
}

/// Every .cls under `dir` scanned for banned tokens outside comments, except
/// `skip` -- a full path, compared as one, because two files under src/ are named
/// RLM2.cls and a basename comparison would silently exempt the wrong one.
///
/// Its own walk rather than UnitTest.Gaia.Port.ScanGaia because that one skips
/// Gaia/RLM2.cls -- correctly, for the recursion-machinery search FR-012 exempts it
/// from -- and Gaia/RLM2.cls is exactly the file this search has to cover.
ClassMethod ScanAll(
	dir As %String,
	banned As %List,
	ByRef offenders As %String,
	ByRef scanned As %Integer,
	skip As %String = "") As %Status
{
    Set scanned = $Get(scanned, 0)
    Set rs = ##class(%ResultSet).%New("%File:FileSet")
    Set sc = rs.Execute(dir, "*")
    If $$$ISERR(sc) { Quit sc }
    While rs.Next() {
        Set name = rs.Get("Name"), type = rs.Get("Type")
        If type = "D" { Do ..ScanAll(name, banned, .offenders, .scanned, skip) Continue }
        If $ZConvert($Piece(name, ".", *), "L") '= "cls" { Continue }
        If (skip '= "") && (name = skip) { Continue }
        Set scanned = scanned + 1
        Do ##class(UnitTest.Gaia.Port).ScanFile(name, banned, .offenders)
    }
    Quit $$$OK
}

}
