/// Gaia.LLM.AIHub: %AI.Agent reached only through RLM.LLM.Complete().
///
/// The claim under test is narrow and load-bearing. RLM.Engine has no reference to
/// %AI.* anywhere, so the entire AI Hub dependency of this project sits behind one
/// method with one signature -- and if that method can throw, the failure mode is
/// not a missing report but a broken pipeline: the report is a bonus deliverable
/// and `result.csv` is the contest answer.
///
/// So the failure tests matter more than the success test. A live call needs a key
/// and a network and is skipped without them; a call with no key must come back as
/// "" and a status, on a machine with no key and no network, every time.
///
/// Every assertion macro is on one source line: $$$macro(...) cannot span lines,
/// and %UnitTest reports a wrapped one as a silently skipped class.
Class UnitTest.Gaia.LLM Extends %UnitTest.TestCase
{

/// True when a live provider call is worth attempting. Without a key the
/// round-trip tests have nothing to talk to, and asserting they fail would be
/// asserting the absence of a key rather than anything about this class.
ClassMethod HasKey() As %Boolean
{
    Quit ($System.Util.GetEnviron("OPENAI_API_KEY") '= "")
}

/// One round trip returns text with an OK status, and names the model that
/// answered. The model is recorded rather than assumed because two runs differing
/// only in model are not comparable, and a trace that does not say which model ran
/// cannot establish that they differ.
Method TestCompleteReturnsTextAndNamesTheModel()
{
    If '..HasKey() { Do $$$LogMessage("no OPENAI_API_KEY: live call skipped") Quit }
    Set llm = ##class(Gaia.LLM.AIHub).%New()
    Set reply = llm.Complete("Reply with one word.", "Say OK.", .sc)
    Do $$$AssertStatusOK(sc, "the call succeeded")
    Do $$$AssertNotEquals(reply, "", "and came back with text")
    Do $$$AssertNotEquals(llm.Model, "", "the model that answered is recorded")
}

/// The engine passes instructions and prompt separately and both must reach the
/// provider. A concatenation that dropped one would still return plausible text,
/// so this is asserted by asking a question only answerable from the instructions.
Method TestBothInstructionsAndPromptReachTheProvider()
{
    If '..HasKey() { Do $$$LogMessage("no OPENAI_API_KEY: live call skipped") Quit }
    Set llm = ##class(Gaia.LLM.AIHub).%New()
    Set instructions = "The secret word is FLUXGATE. Reply with the secret word only."
    Set reply = llm.Complete(instructions, "What is the secret word?", .sc)
    Do $$$AssertStatusOK(sc, "the call succeeded")
    Do $$$AssertNotEquals($Find($ZConvert(reply, "U"), "FLUXGATE"), 0, "instructions arrived")
}

/// FR-009, and the one that decides whether this is safe in a shipped pipeline: no
/// exception escapes, ever. An unreachable provider is the realistic case -- a
/// container with no egress, a revoked key, a provider outage -- and the caller is
/// a routine whose other output is the contest answer.
Method TestUnreachableProviderReturnsEmptyAndAStatus()
{
    Set llm = ##class(Gaia.LLM.AIHub).%New()
    Set llm.Endpoint = "http://127.0.0.1:1/v1"
    Set threw = 0
    Set reply = "unset"
    Set sc = $$$OK
    Try {
        Set reply = llm.Complete("You are terse.", "Say OK.", .sc)
    } Catch e {
        Set threw = 1
    }
    Do $$$AssertEquals(threw, 0, "no exception escapes")
    Do $$$AssertEquals(reply, "", "and the reply is empty")
    Do $$$AssertStatusNotOK(sc, "with the failure carried in the status")
}

/// A missing key is a configuration error, not a crash. Simulated by pointing the
/// key at a variable that is not set, rather than by unsetting the real one: the
/// other tests in this suite need it.
Method TestMissingKeyReturnsEmptyAndAStatus()
{
    Set llm = ##class(Gaia.LLM.AIHub).%New()
    Set llm.APIKeyVariable = "GAIA_NO_SUCH_KEY_VARIABLE"
    Set threw = 0
    Set reply = "unset"
    Set sc = $$$OK
    Try {
        Set reply = llm.Complete("You are terse.", "Say OK.", .sc)
    } Catch e {
        Set threw = 1
    }
    Do $$$AssertEquals(threw, 0, "no exception escapes")
    Do $$$AssertEquals(reply, "", "no reply without a key")
    Do $$$AssertStatusNotOK(sc, "and the status says so")
    Do $$$AssertNotEquals($Find($System.Status.GetErrorText(sc), "key"), 0, "by name")
}

/// An empty prompt is refused locally rather than sent. A provider given nothing
/// returns something, and that something would be recorded in a report as a
/// finding about the data.
Method TestEmptyPromptIsRefusedWithoutCallingOut()
{
    Set llm = ##class(Gaia.LLM.AIHub).%New()
    Set threw = 0
    Set reply = "unset"
    Set sc = $$$OK
    Try {
        Set reply = llm.Complete("You are terse.", "", .sc)
    } Catch e {
        Set threw = 1
    }
    Do $$$AssertEquals(threw, 0, "no exception escapes")
    Do $$$AssertEquals(reply, "", "nothing comes back")
    Do $$$AssertStatusNotOK(sc, "and it is reported as a failure")
}

/// A failed call costs the run one slot, not the report: the same instance must be
/// usable afterwards. A provider adapter that left a half-initialised session
/// behind would fail every subsequent call in the run, turning one network blip
/// into an empty report.
Method TestAFailedCallDoesNotPoisonTheInstance()
{
    Set llm = ##class(Gaia.LLM.AIHub).%New()
    Do llm.Complete("You are terse.", "", .bad)
    Do $$$AssertStatusNotOK(bad, "the first call failed")
    If '..HasKey() { Do $$$LogMessage("no OPENAI_API_KEY: recovery call skipped") Quit }
    Set reply = llm.Complete("Reply with one word.", "Say OK.", .sc)
    Do $$$AssertStatusOK(sc, "and the next one still works")
    Do $$$AssertNotEquals(reply, "", "with text")
}

/// It is an RLM.LLM, which is the whole point: the engine holds the parent type and
/// never learns which provider it got.
Method TestAIHubIsAnRLMLLM()
{
    Set llm = ##class(Gaia.LLM.AIHub).%New()
    Do $$$AssertTrue(llm.%IsA("RLM.LLM"), "the engine's declared type")
}

/// SC-005, by search rather than by inspection. Principle VI says RLM.Engine
/// depends on Source/LLM/Budget/Trace/Report and nothing else; the whole AI Hub
/// dependency of this project is the one class above. A grep is the only form of
/// this claim that stays true as the engine changes.
Method TestEngineContainsNoAIReference()
{
    Set path = "/home/irisowner/dev/lib/rlm-core/src/RLM/Engine.cls"
    Do $$$AssertTrue(##class(%File).Exists(path), "the engine source is where expected")
    Set hits = ..CodeReferencesAI(path, .lines)
    Do $$$AssertTrue(lines > 0, "and it was actually read")
    Do $$$AssertEquals(hits, 0, "no %AI. reference in the engine's code")
}

/// The same search across the whole library, because an %AI. reference in any of
/// the classes the engine calls would break the portable module just as surely as
/// one in the engine itself.
///
/// The file count is asserted too. A walk that found nothing would pass this test
/// for the wrong reason, and "no offenders" and "no files" are the same string.
Method TestNoLibraryClassReferencesAIHub()
{
    Set dir = "/home/irisowner/dev/lib/rlm-core/src/RLM"
    Set offenders = "", scanned = 0
    Do ..ScanForAI(dir, .offenders, .scanned)
    Do $$$AssertTrue(scanned > 5, "the walk actually reached the library: "_scanned_" file(s)")
    Do $$$AssertEquals(offenders, "", "the library is free of %AI. references")
}

/// Non-comment lines in one file that mention %AI.
///
/// Comments are excluded, and that exclusion is the whole subtlety of this test.
/// Both RLM.Engine and RLM.LLM *document* the claim -- "contains no reference to
/// %AI.*" -- so a naive grep reports the sentence asserting the property as a
/// violation of it, and the only way to make the test pass would be to delete the
/// documentation. What matters is whether the compiled code names the class.
ClassMethod CodeReferencesAI(
	path As %String,
	Output lines As %Integer) As %Integer
{
    Set lines = 0, hits = 0
    Set f = ##class(%Stream.FileCharacter).%New()
    If $$$ISERR(f.LinkToFile(path)) { Quit 0 }
    While 'f.AtEnd {
        Set line = f.ReadLine()
        Set lines = lines + 1
        If '$Find(line, "%AI.") { Continue }
        // Leading `//`, `///` or `;` -- a whole-line comment. A trailing comment on
        // a line of code still counts, which errs toward reporting.
        Set stripped = $ZStrip(line, "<W")
        If $Extract(stripped, 1, 2) = "//" { Continue }
        If $Extract(stripped) = ";" { Continue }
        Set hits = hits + 1
    }
    Quit hits
}

/// Recursive walk over the library sources.
///
/// %ResultSet over the %File:FileSet query rather than `CALL %File_FileSet` -- the
/// procedure is not projected into SQLUser, so the SQL form returns SQLCODE -428
/// and the walk finds nothing. Which is why the caller asserts the file count: a
/// walk that reached nothing reports the same empty offender list as a clean one.
///
/// Directories come back as type "D" and files as "F".
ClassMethod ScanForAI(
	dir As %String,
	ByRef offenders As %String,
	ByRef scanned As %Integer) As %Status
{
    Set scanned = $Get(scanned, 0)
    Set rs = ##class(%ResultSet).%New("%File:FileSet")
    Set sc = rs.Execute(dir, "*")
    If $$$ISERR(sc) { Quit sc }
    While rs.Next() {
        Set name = rs.Get("Name"), type = rs.Get("Type")
        If type = "D" { Do ..ScanForAI(name, .offenders, .scanned) Continue }
        If $ZConvert($Piece(name, ".", *), "L") '= "cls" { Continue }
        Set scanned = scanned + 1
        If ..CodeReferencesAI(name, .lines) {
            Set offenders = offenders_$Piece(name, "/", *)_" "
        }
    }
    Quit $$$OK
}

}
