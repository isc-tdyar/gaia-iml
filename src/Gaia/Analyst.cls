/// AI Hub analyst for the Gaia variable-star pipeline.
///
/// This does NOT hand the LLM a SQL toolset and let it drive. That was tried
/// first and does not work here: %AI.Tools.SQL's ListTables returns ~50KB of
/// namespace metadata, the tool result is re-sent on every subsequent LLM call,
/// and gpt-4o-mini keeps re-attempting discovery until %AICore raises
/// LoopDetected. A single ^RunScript-scale report took over five minutes and
/// produced nothing.
///
/// Instead the ObjectScript side runs a fixed set of aggregate queries, which is
/// where the interesting work is anyway since these are the queries that call
/// PREDICT(GaiaVariability) inline, and the agent is asked once to interpret the
/// results. Deterministic evidence, bounded cost, one LLM round-trip.
Class Gaia.Analyst Extends %AI.Agent
{

Parameter PROVIDER = "openai";

Parameter MODEL = "gpt-4o-mini";

Parameter APIKEY = "@{env.OPENAI_API_KEY}";

XData INSTRUCTIONS [ MimeType = text/markdown ]
{
# Gaia Variable Star Analyst

You are an astronomer interpreting Gaia DR3 epoch photometry that has been loaded
into InterSystems IRIS and classified by an IntegratedML model.

## The data

Table `SQLUser.GaiaFluxStats`, one row per Gaia source:

| Column | Meaning |
| --- | --- |
| `source_id` | Gaia DR3 source identifier |
| `bp_min`, `bp_max` | min/max BP-band flux across all epochs |
| `rp_min`, `rp_max` | min/max RP-band flux across all epochs |
| `n_bp`, `n_rp` | number of usable epochs per band |
| `pct_change` | largest relative flux swing, in percent |
| `is_variable` | heuristic label (`pct_change` > 100) used to train the model |

`GaiaVariability` is a custom IntegratedML model (a scikit-learn
`GradientBoostingClassifier` supplied through the `IRISModel` contract) trained on
this table. `PREDICT(GaiaVariability)` returns 1 for a variable source and works
inline in both the SELECT list and WHERE.

## Your job

You will be given the results of several aggregate queries that have already been
run against this table. Interpret them as an astronomer would.

Pay particular attention to artifacts. Extreme `pct_change` is usually
instrumental rather than astrophysical, and two signatures matter most:

- `bp_min` or `rp_min` at or near zero, which makes the relative change explode
  and is physically meaningless
- very low `n_bp` / `n_rp`, where a single bad epoch drives the whole result

## Output

Return **only** GitHub-flavored Markdown, no preamble, starting with
`## Analysis`. Include:

- a short findings summary using the real numbers you were given
- a `### Likely artifacts` section quantifying the contamination
- a `### Method` section noting that the figures come from SQL aggregates in
  which `PREDICT(GaiaVariability)` was evaluated inline

Never invent a number. Use only the values provided. If a figure you would like
to cite is not among them, say so rather than estimating.
}

/// Aggregate queries whose results become the agent's evidence. Each is small by
/// construction, and several call PREDICT() inline, which is the point of the
/// entry: the model is invoked as an ordinary SQL function.
ClassMethod Queries() As %DynamicArray
{
    Quit [
        {"label":"Total sources ingested",
         "sql":"SELECT COUNT(*) AS total FROM SQLUser.GaiaFluxStats"},
        {"label":"Sources the model calls variable",
         "sql":"SELECT COUNT(*) AS predicted_variable FROM SQLUser.GaiaFluxStats WHERE PREDICT(GaiaVariability) = 1"},
        {"label":"Model vs heuristic agreement",
         "sql":"SELECT is_variable, PREDICT(GaiaVariability) AS predicted, COUNT(*) AS n FROM SQLUser.GaiaFluxStats GROUP BY is_variable, PREDICT(GaiaVariability)"},
        {"label":"Flux swing distribution among variables",
         "sql":"SELECT COUNT(*) AS n, MIN(pct_change) AS min_pct, AVG(pct_change) AS avg_pct, MAX(pct_change) AS max_pct FROM SQLUser.GaiaFluxStats WHERE pct_change > 100"},
        {"label":"Variables with a near-zero minimum flux (relative change explodes)",
         "sql":"SELECT COUNT(*) AS near_zero_min FROM SQLUser.GaiaFluxStats WHERE pct_change > 100 AND (bp_min < 1 OR rp_min < 1)"},
        {"label":"Variables resting on very few epochs",
         "sql":"SELECT COUNT(*) AS few_epochs FROM SQLUser.GaiaFluxStats WHERE pct_change > 100 AND (n_bp < 5 OR n_rp < 5)"},
        {"label":"Epoch counts across the variable population",
         "sql":"SELECT AVG(n_bp) AS avg_n_bp, AVG(n_rp) AS avg_n_rp, MIN(n_bp) AS min_n_bp, MAX(n_bp) AS max_n_bp FROM SQLUser.GaiaFluxStats WHERE pct_change > 100"}
    ]
}

/// Run the aggregate queries and render them as Markdown evidence for the agent.
ClassMethod Evidence() As %String
{
    Set out = "", queries = ..Queries()
    For i = 1:1:queries.%Size() {
        Set q = queries.%Get(i - 1)
        Set out = out_"### "_q.label_$Char(10,10)_"```sql"_$Char(10)_q.sql_$Char(10)_"```"_$Char(10,10)
        Set rs = ##class(%SQL.Statement).%ExecDirect(, q.sql)
        If rs.%SQLCODE < 0 {
            Set out = out_"Query failed: "_rs.%Message_$Char(10,10)
            Continue
        }
        Set cols = rs.%ResultColumnCount
        Set header = "", divider = ""
        For c = 1:1:cols {
            Set header = header_"| "_rs.%GetMetadata().columns.GetAt(c).colName_" "
            Set divider = divider_"| --- "
        }
        Set out = out_header_"|"_$Char(10)_divider_"|"_$Char(10)
        While rs.%Next() {
            Set row = ""
            For c = 1:1:cols { Set row = row_"| "_rs.%GetData(c)_" " }
            Set out = out_row_"|"_$Char(10)
        }
        Set out = out_$Char(10)
    }
    Quit out
}

/// Run the analyst and return the Markdown report, optionally writing it to disk.
/// Never throws: the report is a bonus deliverable, so a missing API key or an
/// LLM outage must not disturb the pipeline that produced result.csv.
ClassMethod Report(outPath As %String = "") As %String
{
    Set report = ""
    Try {
        Set evidence = ..Evidence()
        Set agent = ..%New()
        $$$ThrowOnError(agent.%Init())
        Set session = agent.CreateSession()
        Set prompt = "Here are the aggregate query results for the current run. "
            _"Write the Markdown report described in your instructions."
            _$Char(10,10)_evidence
        // Chat, not Run: the evidence is already gathered, so no tool-calling
        // loop is needed and one round-trip is enough.
        Set response = agent.Chat(session, prompt)
        Set report = response.Content
    }
    Catch ex {
        Set report = "## Analysis"_$Char(10,10)_"Agent unavailable: "_ex.DisplayString()
            _$Char(10,10)_"The IntegratedML pipeline and `result.csv` are unaffected."
            _$Char(10)
    }
    If outPath '= "" {
        Set file = ##class(%Stream.FileCharacter).%New()
        Do file.LinkToFile(outPath)
        Do file.Write(report)
        Do file.%Save()
    }
    Quit report
}

}
