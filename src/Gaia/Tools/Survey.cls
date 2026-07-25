/// The survey toolset the delegating RLM hands its agents.
///
/// Two tools, both aggregate-only. Neither accepts SQL and neither returns rows,
/// so the context an agent accumulates is bounded by the number of calls it makes
/// rather than by the size of the table: 74,998 sources and 74 sources produce the
/// same ~500 characters of evidence.
///
/// This is what Gaia.Analyst's %AI.Tools.SQL attempt got wrong. ListTables alone
/// returned ~50KB of namespace metadata, every tool result was re-sent on the next
/// call, and gpt-4o-mini re-attempted discovery until %AICore raised LoopDetected.
/// A narrow toolset over a fixed grammar has no discovery phase to loop on.
///
/// %AI.Tool exposes public methods as tools by introspection, using the doc
/// comment as the description, so the comments below are load-bearing: they are
/// the tool descriptions the model actually reads.
Class Gaia.Tools.Survey Extends %AI.Tool
{

/// List the ways the Gaia survey can be sliced. Returns each dimension, what it
/// means, and the exact child tokens accepted by PeekSlice. Call this first.
Method ListDimensions() As %String
{
    Quit "Slices are named `dimension:child`, and nest with `/` up to "
        _##class(Gaia.Slice).#MAXDEPTH_" levels "
        _"(for example `reject_level:severe/epoch_count:few`). Each dimension may "
        _"appear once in a path."_$Char(10,10)_##class(Gaia.Slice).Menu()
}

/// Get summary statistics for one slice of the Gaia survey. `slice` must be a
/// slice name from ListDimensions, such as `reject_level:severe` or
/// `reject_level:severe/epoch_count:few`. Returns aggregate statistics only, never
/// individual sources. SQL is not accepted.
Method PeekSlice(slice As %String) As %String
{
    Set sc = ##class(Gaia.Slice).Resolve(slice, .where, .label)
    If $$$ISERR(sc) {
        // Refuse with the grammar attached. A bare "invalid" makes the agent retry
        // at random, and random retries are what exhaust the call budget.
        Quit "Refused: "_$System.Status.GetErrorText(sc)
    }
    Set peek = ##class(Gaia.RLM).Peek(where)
    If peek.%IsDefined("error") { Quit "Query failed: "_peek.error }
    // Counted as a peek, not a delegation. Gaia.RLM2.Report traces the slices it
    // delegates; what an analyst peeks at inside its own slice is its working.
    Do ##class(Gaia.RLM2).Peeked(slice, peek.n)
    Quit ##class(Gaia.RLM).Describe(label, peek)
}

}
