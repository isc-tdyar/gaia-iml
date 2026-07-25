/// The two entry points, running on the library.
///
/// Every test here drives the real store -- 74,998 rows of Gaia DR3 -- through the
/// real engine with a *scripted* model. That combination is the point: the store's
/// arithmetic is real, so a caveat about rows falling in no bucket is a fact about
/// the survey, while the model's answers are fixed, so the report is a pure
/// function of the code and can be compared byte for byte.
///
/// The seam is Gaia.RLM.Analyze(question, rootPath, outPath, llm). Audit() and
/// Triage() are two calls to it with different arguments, so testing Analyze with
/// a Null provider tests both entry points minus their argument lists -- and the
/// argument lists are asserted separately, cheaply, by what the report says it
/// described.
///
/// Every assertion macro sits on one source line. A wrapped $$$macro(...) is a
/// <SYNTAX> error that %UnitTest reports as a skipped class while printing
/// "All PASSED".
Class UnitTest.Gaia.Port Extends %UnitTest.TestCase
{

/// A model that always names the same dimension and always says the same thing
/// about a slice.
///
/// Long enough for any traversal the budget can fund: the Null provider returns an
/// error rather than throwing past the end of its script, and an under-scripted run
/// would produce "sub-call failed" caveats that read as a provider problem instead
/// of a test-fixture one.
ClassMethod Scripted(dimension As %String = "reject_level") As RLM.LLM.Null
{
    Set script = ""
    For i = 1:1:40 {
        // Odd entries can be read as a dimension name by the split policy; even
        // ones as a finding by a sub-call. Both kinds are valid for either use --
        // the policy takes the first non-empty line and checks it against the
        // candidate list, so a finding offered as a dimension is simply declined,
        // which is a legitimate outcome and not an error.
        Set script = script_$ListBuild(dimension)
        Set script = script_$ListBuild("This slice is unremarkable; nothing here contradicts the survey.")
    }
    Quit ##class(RLM.LLM.Null).%New(script)
}

/// SC-003. Two runs of the same decomposition with the same scripted model produce
/// the same report, byte for byte.
///
/// The claim that makes a report reviewable at all. Without it, a report that
/// changes between runs cannot be attributed to the change that caused it, and
/// every diff has to be read as prose rather than as a diff.
Method TestTwoIdenticalRunsProduceIdenticalReports()
{
    Set a = ##class(Gaia.RLM).Analyze("Where is quality worst?", , , ..Scripted())
    Set b = ##class(Gaia.RLM).Analyze("Where is quality worst?", , , ..Scripted())
    Do $$$AssertNotEquals(a, "", "the report has content: "_$Length(a)_" chars")
    Do $$$AssertEquals($Length(a), $Length(b), "both runs are the same length")
    Do $$$AssertEquals(a, b, "and byte-identical")
}

/// The report is complete: it names the store, the slices it examined, an answer,
/// the limits of the analysis, and what it spent.
///
/// Asserted as five separate presence checks rather than one text comparison. A
/// golden-text assertion over a real 74,998-row store fails on every reworded
/// label, which trains a reader to update the expectation without reading it.
Method TestReportNamesStoreSlicesAnswerLimitsAndCost()
{
    Set text = ##class(Gaia.RLM).Analyze("Where is quality worst?", , , ..Scripted())
    Do $$$AssertNotEquals($Find(text, "Store"), 0, "it names the store")
    Do $$$AssertNotEquals($Find(text, "Gaia DR3"), 0, "by name")
    Do $$$AssertNotEquals($Find(text, "Slices examined"), 0, "it lists the slices examined")
    Do $$$AssertNotEquals($Find(text, "Answer"), 0, "it gives an answer")
    Do $$$AssertNotEquals($Find(text, "model calls"), 0, "and says what it spent")
}

/// FR-010, and the difference the port makes. Triage's scope is the slice name
/// `detection:b1`, not a WHERE clause: the run is confined by a name the store
/// resolves, and the engine never receives SQL.
///
/// The population is asserted through the report rather than by re-querying,
/// because what matters is that the *report* describes the 57,099 detections and
/// not the whole survey. A scoped run that silently described everything would
/// still pass a query-side check.
Method TestTriageScopeIsASliceNameNotAPredicate()
{
    Set text = ##class(Gaia.RLM).Analyze("Which of these are real?", "detection:b1", , ..Scripted())
    Do $$$AssertNotEquals($Find(text, "57099"), 0, "the run describes the 57,099 detections")
    Do $$$AssertEquals($Find(text, "74998"), 0, "and not the whole survey")
    Do $$$AssertEquals($Find(text, "WHERE"), 0, "no SQL crossed into the report")
    Do $$$AssertEquals($Find(text, "pct_change"), 0, "nor did a column name")
}

/// Principle III. A budget too small to reach every slice must produce a report
/// that *names* what it dropped.
///
/// The failure this prevents is the quiet one: a report listing three slices out of
/// twenty-two, with no mention of the other nineteen, reads as "this is all there
/// was to find".
Method TestABudgetTooSmallNamesWhatItDropped()
{
    Set llm = ..Scripted()
    Set text = ##class(Gaia.RLM).Analyze("Where is quality worst?", , , llm, 3)
    Do $$$AssertNotEquals($Find(text, "budget"), 0, "the report mentions the budget")
    Do $$$AssertNotEquals($Find(text, "dropped"), 0, "and says slices were dropped")
    Do $$$AssertTrue(llm.Calls <= 3, "it stopped at the ceiling: "_llm.Calls_" call(s)")
}

/// An empty slice costs no model call.
///
/// `detection:b1/variability:b0` is empty by construction -- a source cannot both
/// swing more than 100% and less than 100% -- so it is the cheapest available
/// proof that the engine describes what it finds rather than what it expected.
Method TestAnEmptySliceIsDescribedAndCostsNothing()
{
    Set source = ##class(Gaia.Source).%New()
    Set sc = ##class(RLM.Slice).Resolve(source, "detection:b1/variability:b0", .predicate, .label)
    Do $$$AssertStatusOK(sc, "the empty slice is a nameable one")
    Set peek = source.Peek(predicate)
    Do $$$AssertEquals(+peek.n, 0, "and it is empty")
    Do $$$AssertNotEquals($Find(source.Describe(label, peek), "no sources"), 0, "described as empty")
    Do $$$AssertNotTrue(source.ShouldSplit(peek), "and not worth subdividing")
}

/// FR-009 at the entry point. With no provider reachable, Audit() returns a report
/// saying so rather than raising.
///
/// This is the one that decides whether the report is safe to leave in a shipped
/// pipeline: `^RLMAudit` runs in the same session as the routines that produce
/// `result.csv`, and an exception here is an exception there.
Method TestAnalyzeWithABrokenProviderStillReturnsAReport()
{
    Set llm = ##class(Gaia.LLM.AIHub).%New()
    Set llm.APIKeyVariable = "GAIA_NO_SUCH_KEY_VARIABLE"
    Set threw = 0, text = ""
    Try {
        Set text = ##class(Gaia.RLM).Analyze("Where is quality worst?", , , llm)
    } Catch e {
        Set threw = 1
    }
    Do $$$AssertEquals(threw, 0, "no exception escaped")
    Do $$$AssertNotEquals(text, "", "a report came back anyway")
    Do $$$AssertNotEquals($Find(text, "Store"), 0, "with the store's statistics in it")
}

/// The report is written where it was asked for, in UTF-8.
Method TestAnalyzeWritesTheReportToItsPath()
{
    Set path = "/tmp/gaia_port_test.md"
    Do ##class(%File).Delete(path)
    Set text = ##class(Gaia.RLM).Analyze("Where is quality worst?", , path, ..Scripted())
    Do $$$AssertTrue(##class(%File).Exists(path), "the file was written")
    Do $$$AssertEquals(##class(%File).GetFileSize(path), $Length(text), "with the whole report")
    Do ##class(%File).Delete(path)
}

/// Audit() and Triage() differ only in question and scope, and the difference shows
/// in the reports. Asserted without a model call: both are refused for want of a
/// key, and a refusal still carries the store description the scope produced.
Method TestAuditAndTriageDifferInScope()
{
    Set full = ##class(Gaia.RLM).Analyze(##class(Gaia.RLM).#AUDITQUESTION, , , ..Scripted())
    Set scoped = ##class(Gaia.RLM).Analyze(##class(Gaia.RLM).#TRIAGEQUESTION, "detection:b1", , ..Scripted())
    Do $$$AssertNotEquals(full, scoped, "two different runs, two different reports")
    Do $$$AssertNotEquals($Find(full, "74998"), 0, "the audit covers the survey")
    Do $$$AssertNotEquals($Find(scoped, "57099"), 0, "the triage covers the detections")
}

/// FR-008, by search. None of the machinery the library replaced may remain under
/// src/Gaia/ -- a second copy of a recursion budget is the duplication this whole
/// feature exists to remove, and it would go stale silently.
///
/// RLM2.cls is excluded by FR-012: the model owns the recursion there, so its
/// delegation budget is its own and has no library equivalent.
Method TestNoRecursionMachineryRemains()
{
    Set banned = $ListBuild("CallCount", "ChooseDimension", "ShouldRecurse",
        "BaselineSpread", "Indent(", "SPLITRATIO")
    Set offenders = ""
    Do ..ScanGaia("/home/irisowner/dev/src/Gaia", banned, .offenders, .scanned)
    Do $$$AssertTrue(scanned > 2, "the walk reached the sources: "_scanned_" file(s)")
    Do $$$AssertEquals(offenders, "", "no replaced machinery remains")
}

/// The row floor moved rather than went: the removal table replaces
/// `Parameter SPLITMINROWS` with "the >= 400 in ShouldSplit", and ShouldSplit is
/// Gaia.Source's. So the token must be absent from the entry point and present in
/// the store -- which is a different assertion from the one above, and worth making
/// separately, because a search that banned it everywhere would be demanding the
/// rule be deleted rather than relocated.
Method TestTheRowFloorMovedToTheStore()
{
    Set banned = $ListBuild("SPLITMINROWS")
    Set fromEntry = ""
    Do ..ScanFile("/home/irisowner/dev/src/Gaia/RLM.cls", banned, .fromEntry)
    Do $$$AssertEquals(fromEntry, "", "the entry point no longer holds the row floor")
    Set inStore = ""
    Do ..ScanFile("/home/irisowner/dev/src/Gaia/Source.cls", banned, .inStore)
    Do $$$AssertNotEquals(inStore, "", "and the store does")
    Do $$$AssertEquals(##class(Gaia.Source).#SPLITMINROWS, 400, "at the prototype's value")
}

/// Gaia.RLM is no longer an agent. An entry point that is also a provider cannot be
/// handed a scripted provider, which is what every test above depends on.
Method TestGaiaRLMIsNotAnAgent()
{
    Do $$$AssertNotTrue(##class(Gaia.RLM).%IsA("%AI.Agent"), "the entry point is not a provider")
}

/// Files under `dir` containing any banned token outside a comment.
///
/// Comments are excluded for the same reason the SC-005 scan excludes them: the
/// class doc explains what moved to the library and names it while doing so.
ClassMethod ScanGaia(
	dir As %String,
	banned As %List,
	ByRef offenders As %String,
	ByRef scanned As %Integer) As %Status
{
    Set scanned = $Get(scanned, 0)
    Set rs = ##class(%ResultSet).%New("%File:FileSet")
    Set sc = rs.Execute(dir, "*")
    If $$$ISERR(sc) { Quit sc }
    While rs.Next() {
        Set name = rs.Get("Name"), type = rs.Get("Type")
        If type = "D" { Do ..ScanGaia(name, banned, .offenders, .scanned) Continue }
        If $ZConvert($Piece(name, ".", *), "L") '= "cls" { Continue }
        // FR-012: RLM2 keeps its own delegation budget.
        If $Piece(name, "/", *) = "RLM2.cls" { Continue }
        Set scanned = scanned + 1
        Do ..ScanFile(name, banned, .offenders)
    }
    Quit $$$OK
}

/// Banned tokens found outside a comment in one file, appended as `file:token`.
ClassMethod ScanFile(
	path As %String,
	banned As %List,
	ByRef offenders As %String) As %Status
{
    Set f = ##class(%Stream.FileCharacter).%New()
    Set sc = f.LinkToFile(path)
    If $$$ISERR(sc) { Quit sc }
    While 'f.AtEnd {
        Set line = $ZStrip(f.ReadLine(), "<W")
        Continue:$Extract(line, 1, 2)="//"
        Continue:$Extract(line)=";"
        Set ptr = 0
        While $ListNext(banned, ptr, token) {
            If $Find(line, token) {
                Set offenders = offenders_$Piece(path, "/", *)_":"_token_" "
            }
        }
    }
    Quit $$$OK
}

}
