/// AI Hub adjudicator for classifier/catalogue disagreements.
///
/// The classifier (GaiaVariableType, a custom IntegratedML IRISModel) disagrees
/// with the published DR3 classification on a few hundred sources. The question
/// "who is right" cannot be settled from the light curves, because both parties
/// already looked at the light curves and reached different answers. It needs
/// evidence from outside: what other astronomers have published about that
/// specific star.
///
/// WHY THIS IS AN LLM JOB AND THE REST OF THE PIPELINE IS NOT
///
/// The numeric half of the adjudication is not done here, on purpose. Centroid
/// distance already decides which of the two labels a disputed source sits
/// closer to (64% land nearer the classifier's answer), and k-means already
/// groups the disputes into a handful of recurring degeneracies. Those are five
/// lines of numpy, they are deterministic, and an agent asked to do the same job
/// would be slower, dearer and less reproducible. `Gaia.Dispute` runs them.
///
/// What is left over is genuinely textual. A well-studied star carries decades
/// of conflicting classifications from different teams -- HD 283572 has 311
/// references, 51 of them about rotation and starspots, the earliest from 1984.
/// Ranking a 2017 machine-learned identification against 2022 survey photometry
/// requires knowing how those methods compare, which is knowledge held in prose
/// and absent from every table in this database. No distance metric can do it.
///
/// The evidence is gathered deterministically in Python (gaia_simbad.py) and the
/// agent is asked once to weigh it, following the same pattern as Gaia.Analyst:
/// bounded cost, one round-trip, no tool loop.
Class Gaia.Adjudicator Extends %AI.Agent
{

Parameter PROVIDER = "openai";

Parameter MODEL = "gpt-4o-mini";

Parameter APIKEY = "@{env.OPENAI_API_KEY}";

XData INSTRUCTIONS [ MimeType = text/markdown ]
{
# Adjudicating a disputed variable-star classification

A machine-learning classifier trained on Gaia DR3 labels disagrees with the
published Gaia DR3 classification for one star. You are given both claims and
the independent evidence available from SIMBAD.

## What you are given

- **Catalogue class**: the published Gaia DR3 `best_class_name`, with the
  catalogue's own confidence score. A low score means the catalogue was unsure.
- **Model class**: what the classifier predicted, with its confidence.
- **Feature evidence**: how this source compares to confident examples of both
  classes on the discriminating light-curve statistics.
- **SIMBAD evidence**: independent object types and published papers. Object
  types sourced from the Gaia variability catalogue itself have already been
  removed, because they are the catalogue's own claim arriving by a second route
  and are not independent.

## Class meanings

| Code | Meaning |
| --- | --- |
| `ECL` | eclipsing binary: two stars periodically hiding each other |
| `RS` | RS CVn type: rotating star with large starspots |
| `SOLAR_LIKE` | solar-type rotational modulation, small amplitude |
| `DSCT_GDOR_SXPHE` | short-period pulsators |
| `LPV` | long-period variable: red giant, slow large-amplitude pulsation |
| `RR` | RR Lyrae: regular short-period pulsator |
| `YSO` | young stellar object, often irregular |
| `AGN` | active galactic nucleus: not a star, aperiodic |
| `S` | other/unclassified periodic |

SIMBAD uses a different vocabulary. `EB*` corresponds to `ECL`, `RS*` and `BY*`
to `RS`, `LP*` and `Mi*` to `LPV`, `dS*` to the pulsator group, `Or*`, `TT*` and
`Y*O` to `YSO`. A trailing `?` means the classification is itself a candidate.

## How to weigh evidence

Not all published classifications are equal.

- Spectroscopy beats photometry. A radial-velocity or spectroscopic study
  settles a binary question that photometry alone leaves open.
- Targeted studies beat bulk survey catalogues. A paper about this star is
  stronger than a catalogue that included it among a million others.
- Machine-learned identifications from sparse data are the weakest evidence,
  particularly when the disagreement is with a later, better-sampled survey.
- Later usually beats earlier, but not always: a 1984 dedicated photometric
  campaign outranks a 2018 automated pipeline for questions about rotation.
- Repeated independent detection of the same behaviour is strong. One paper
  describing starspot modulation is suggestive; a dozen across four decades is
  not a coincidence.

A star can legitimately be more than one thing. A young star with large
starspots is both `YSO` and rotationally variable, and the two classifications
are not in conflict -- the catalogue simply had to pick one label. Say so when
that is what the evidence shows, rather than forcing a winner.

## Output

Respond in this exact structure, and nothing else:

**Verdict**: one of `catalogue`, `model`, `both defensible`, `insufficient evidence`

**Confidence**: `high`, `medium` or `low`

**Reasoning**: two to four sentences. Cite specific papers by bibcode when they
carry the argument. Name the strongest single piece of evidence.

**Recommended follow-up**: one sentence, or `none` if the evidence settles it.

Do not speculate beyond the evidence given. If SIMBAD returned nothing, the
answer is `insufficient evidence` regardless of how confident the model was --
an absence of literature is not support for either side.
}

/// Adjudicate one disputed source. `pEvidence` is the formatted evidence block
/// produced by gaia_simbad.format_evidence() plus the feature comparison.
///
/// Returns the verdict text. A provider failure returns a marker rather than
/// throwing: the classifier and its predictions are unaffected by whether the
/// adjudication layer can reach an LLM, and a run that dies here would lose the
/// deterministic results too.
ClassMethod Adjudicate(pEvidence As %String) As %String
{
    Set verdict = ""
    Try {
        Set agent = ..%New()
        $$$ThrowOnError(agent.%Init())
        Set session = agent.CreateSession()
        // Chat, not Run: the evidence is already gathered, so there is no
        // tool-calling loop and one round-trip is enough.
        Set response = agent.Chat(session, pEvidence)
        Set verdict = response.Content
    }
    Catch ex {
        Set verdict = "agent unavailable: "_ex.DisplayString()
    }
    Quit verdict
}

}
