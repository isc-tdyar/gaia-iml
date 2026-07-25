/// Gaia.Source with the readiness counts substituted.
///
/// Ready()'s two refusals describe a store mid-load: empty, or ingested but only
/// partly scored. Both are states the real table is not in and must not be put
/// into -- emptying SQLUser.GaiaQualityScored to test a message would destroy the
/// pipeline's output and leave every other test in this suite asserting against a
/// table that no longer exists.
///
/// So the counts come from one overridable method and this subclass replaces it.
/// That is why Gaia.Source.Counts() is separate from Ready() at all: the query is
/// the part that cannot be faked safely, and the two messages are the part worth
/// testing.
Class UnitTest.Gaia.SourceCounts Extends Gaia.Source
{

Property FakeN As %Integer [ InitialExpression = 0 ];

Property FakeNPred As %Integer [ InitialExpression = 0 ];

Method Counts(
	Output n As %Integer,
	Output nPred As %Integer) As %Status
{
    Set n = ..FakeN, nPred = ..FakeNPred
    Quit $$$OK
}

}
