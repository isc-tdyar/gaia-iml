/// Adjudicate a disputed classification by recursing over the star's literature.
///
/// The flat path is Gaia.Adjudicator: one Chat() call holding the top 20 papers
/// by a keyword relevance score. That is the right shape for most disputed
/// sources, which carry a handful of references. It is the wrong shape for the
/// well-studied ones -- HD 283572 has 72 relevant papers of 311 total -- because
/// the twenty that reach the prompt are chosen by a heuristic that has not read
/// them. On this data that heuristic was wrong once already: "rotation" matched
/// galactic rotation curves and maser kinematics, and those papers displaced a
/// 1993 study with the star's own name in the title. Correcting it changed the
/// verdict, which is the evidence that truncation decides the answer.
///
/// Here the bibliography is a SQL table and the engine decomposes it. The root
/// peeks at aggregates over every paper -- how they spread across epochs, claim
/// types and targeted-versus-survey -- picks a decomposition, and each leaf reads
/// only its own slice. Nothing is dropped, and the context a model sees is a few
/// hundred characters per call however large the bibliography is.
///
/// Same three constructions as Gaia.RLM: RLM.Engine for the recursion,
/// RLM.Budget for the ceiling, Gaia.Literature for the source. The claim and
/// study-type categories are derived in Python at insert time rather than by the
/// model, because a model asked to categorise its own evidence can categorise it
/// into whatever supports the answer it already holds.
Class Gaia.LiteratureAudit
{

/// Depth 1 is the root's own peek, so 3 allows two levels of subdivision. A
/// bibliography is shallower than a survey table: epoch then claim is usually
/// enough to separate "four teams agree" from "four teams disagree".
Parameter MAXDEPTH = 3;

/// Call ceiling. Lower than the survey audits because the population is smaller
/// and every call costs the same as one over 75,000 rows.
Parameter MAXCALLS = 12;

/// Recurse over one source's bibliography and return a verdict.
///
/// `pContext` is the same evidence block the flat adjudicator gets -- the two
/// claims, their confidences and the light-curve feature comparison. It frames
/// the question; the literature is what the engine decomposes.
///
/// GaiaLiterature must already hold this source's papers and no others. Loading
/// is the caller's job (adjudicate_disputes.load_literature) because the table is
/// scoped by content rather than by a predicate -- see Gaia.Literature.
ClassMethod Adjudicate(
	pSourceId As %Integer,
	pContext As %String,
	pOutPath As %String = "",
	pLLM As RLM.LLM = "") As %String
{
    Set verdict = ""
    Try {
        Set n = 0
        &sql(SELECT COUNT(*) INTO :n FROM Gaia.GaiaLiterature WHERE SourceId = :pSourceId)
        If SQLCODE '= 0 || (n = 0) {
            Quit  // no papers loaded; caller falls back to the flat path
        }

        If '$IsObject(pLLM) { Set pLLM = ##class(Gaia.LLM.AIHub).%New() }
        Set engine = ##class(RLM.Engine).%New(
            ##class(Gaia.Literature).%New(pSourceId), pLLM,
            ##class(RLM.Budget).%New(..#MAXCALLS))
        Set engine.MaxDepth = ..#MAXDEPTH
        Set engine.ReportStyle = "markdown"

        Set question = ..Question(pContext)
        Set verdict = engine.Run(question, .traceId)
        If pOutPath '= "" {
            Do ##class(RLM.Report).WriteTextToFile(verdict, pOutPath)
        }
    }
    Catch ex {
        // A failed adjudication is a verdict saying so. The classifier's
        // predictions do not depend on whether an LLM or CDS is reachable, and
        // throwing here would lose the deterministic stages with it.
        Set verdict = "agent unavailable: "_ex.DisplayString()
    }
    Quit verdict
}

/// The question put to the root, carrying the dispute as context.
///
/// The weighing rules live here rather than in the leaves because the root is
/// what chooses the decomposition, and a decomposition chosen without knowing
/// that targeted studies outrank catalogues is a decomposition that separates
/// the evidence on the wrong axis.
ClassMethod Question(pContext As %String) As %String
{
    Set nl = $Char(10)
    Quit "A machine-learning classifier trained on Gaia DR3 labels disagrees "
        _"with the published DR3 classification for one star. Decide which is "
        _"right, using the published literature."_nl_nl
        _pContext_nl
        _"## How to weigh what you find"_nl_nl
        _"- A paper about this star outranks a catalogue that included it among "
        _"a million others. The study_type dimension separates those."_nl
        _"- Spectroscopy beats photometry; a machine-learned identification from "
        _"sparse data is the weakest evidence."_nl
        _"- Later usually beats earlier, but not always: a dedicated 1984 "
        _"photometric campaign outranks a 2018 automated pipeline on a question "
        _"about rotation. The epoch dimension is about what instruments were "
        _"available, not about who is more modern."_nl
        _"- Repeated independent detection of the same behaviour is strong. One "
        _"paper describing starspot modulation is suggestive; a dozen across "
        _"four decades is not a coincidence."_nl
        _"- A star can legitimately be more than one thing. A young star with "
        _"large starspots is both, and the catalogue simply had to pick one "
        _"label. Say so when that is what the evidence shows, rather than "
        _"forcing a winner."_nl_nl
        _"## Answer with"_nl_nl
        _"**Verdict**: catalogue, model, both defensible, or insufficient "
        _"evidence"_nl
        _"**Confidence**: high, medium or low"_nl
        _"**Reasoning**: two to four sentences, citing bibcodes."_nl
        _"**Recommended follow-up**: one sentence, or none."
}

}
