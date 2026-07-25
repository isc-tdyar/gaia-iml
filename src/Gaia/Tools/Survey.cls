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

/// The store both tools read. Not a property: %AI.Tool instances are created per
/// invocation, so there is nothing for an instance to cache.
ClassMethod Store() As Gaia.Source
{
    Quit ##class(Gaia.Source).%New()
}

/// List the ways the Gaia survey can be sliced. Returns each dimension, what it
/// means, and the exact child tokens accepted by PeekSlice. Call this first.
Method ListDimensions() As %String
{
    // RLM.Slice.Menu states the grammar itself, from the store, so the sentence the
    // prototype wrote here is gone rather than reworded: two statements of one
    // grammar is how the menu and the resolver come to disagree.
    Quit ##class(RLM.Slice).Menu(..Store())
}

/// Get summary statistics for one slice of the Gaia survey. `slice` must be a
/// slice name from ListDimensions, such as `reject_level:severe` or
/// `reject_level:severe/epoch_count:few`. Returns aggregate statistics only, never
/// individual sources. SQL is not accepted.
Method PeekSlice(slice As %String) As %String
{
    Set store = ..Store()
    Set sc = ##class(RLM.Slice).Resolve(store, slice, .where, .label)
    If $$$ISERR(sc) {
        // Refuse with the grammar attached, which RLM.Slice already puts in the
        // status. A bare "invalid" makes the agent retry at random, and random
        // retries are what exhaust the call budget.
        Quit "Refused: "_$System.Status.GetErrorText(sc)
    }
    Set peek = store.Peek(where)
    If peek.%IsDefined("error") { Quit "Query failed: "_peek.error }
    // Counted as a peek, not a delegation. Gaia.RLM2.Report traces the slices it
    // delegates; what an analyst peeks at inside its own slice is its working.
    Do ##class(Gaia.RLM2).Peeked(slice, peek.n)
    Quit store.Describe(label, peek)
}

}
