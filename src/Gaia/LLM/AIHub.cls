/// RLM.LLM over AI Hub. The only class in this project that names %AI.*.
///
/// The engine holds an RLM.LLM and calls Complete(). Everything AI Hub-specific --
/// creating a provider, initialising an agent, opening a session, unwrapping a
/// response object -- happens between the braces below, which is what makes
/// SC-005 checkable by grep rather than by argument: the library has no reference
/// to %AI.*, so rlm-core installs on an IRIS with no AI Hub at all.
///
/// Nothing escapes as an exception. FR-009, and the reason it matters more than it
/// looks: `^RunScript` produces `result.csv`, the contest answer, and the report is
/// a bonus. A provider outage must cost the run its report and nothing else, so
/// every failure path here returns "" with a status and the caller decides.
///
/// One session per call, deliberately. A session accumulates turns, and an engine
/// whose calls shared one would be feeding each slice's evidence to the next --
/// which is exactly the context growth the RLM pattern exists to avoid, and it
/// would arrive silently as a slowly worsening cost per call rather than as an
/// error. Sessions are created locally, so a fresh one per call costs no round trip.
Class Gaia.LLM.AIHub Extends RLM.LLM
{

/// Environment variable holding the API key. Named rather than valued so the
/// secret is not a property that could be logged, and overridable so a test can
/// point at a variable that does not exist without disturbing the real key.
Property APIKeyVariable As %String [ InitialExpression = "OPENAI_API_KEY" ];

/// OpenAI-compatible base URL. Empty means the provider's own default.
///
/// Present so the unreachable-provider path is testable, and useful beyond that:
/// vLLM, Ollama and llama.cpp all speak this shape, so a locally served model is a
/// URL change.
Property Endpoint As %String;

/// The initialised agent, built on first use and kept for the run. Building it
/// creates a provider and expands settings, which is worth doing once; it opens no
/// connection, so a cached agent holds nothing that can go stale mid-run.
Property Agent As %AI.Agent [ Private ];

Method %OnNew() As %Status
{
    // The model comes from the agent class's parameter rather than being repeated
    // here: the declarative configuration is meant to be readable in one place.
    Set ..Model = ##class(Gaia.LLM.Agent).#MODEL
    Quit $$$OK
}

Method Complete(
	instructions As %String,
	prompt As %String,
	Output sc As %Status) As %String
{
    Set sc = $$$OK

    // Refused here rather than sent. A provider given an empty user turn answers
    // anyway, and that answer would be written into a report as a finding about
    // the survey -- a failure that reads as data.
    If $ZStrip(prompt, "<>W") = "" {
        Set sc = $$$ERROR($$$GeneralError, "refusing to call the model with an empty prompt")
        Quit ""
    }

    Set agent = ..GetAgent(.sc)
    If $$$ISERR(sc) { Quit "" }

    Try {
        // SystemPrompt, not a concatenation. The two arguments are different roles
        // to the provider, and folding them into one turn loses the distinction
        // that makes the instructions authoritative.
        Set agent.SystemPrompt = instructions
        Set session = agent.CreateSession()
        Set response = agent.Chat(session, prompt)
        Set out = response.Content
    } Catch e {
        // Everything the Rust provider layer raises -- connection refused, a 401,
        // a rate limit -- arrives here as <%AICore>ProviderError.
        Set sc = e.AsStatus()
    }
    If $$$ISERR(sc) { Quit "" }
    Quit $Get(out)
}

/// The agent, built once.
///
/// The provider is constructed here and assigned before %Init rather than left to
/// %AI.Agent's declarative path, because %Init only creates one when Provider is
/// empty. That is what lets Endpoint and APIKeyVariable mean anything: the
/// parameters on Gaia.LLM.Agent supply the defaults, and these two properties
/// override the parts a caller needs to vary.
Method GetAgent(Output sc As %Status) As %AI.Agent
{
    Set sc = $$$OK
    If $IsObject(..Agent) { Quit ..Agent }

    Set key = $System.Util.GetEnviron(..APIKeyVariable)
    If key = "" {
        // Named, so the remedy is in the message. "authentication failed" sends a
        // reader to the provider's dashboard; this sends them to their shell.
        Set msg = "no API key: environment variable "_..APIKeyVariable_" is not set"
        Set sc = $$$ERROR($$$GeneralError, msg)
        Quit $$$NULLOREF
    }

    Try {
        Set settings = {"api_key": (key)}
        If ..Endpoint '= "" { Do settings.%Set("base_url", ..Endpoint) }
        Set agent = ##class(Gaia.LLM.Agent).%New()
        Set agent.Provider = ##class(%AI.Provider).Create(##class(Gaia.LLM.Agent).#PROVIDER, settings)
        Set sc = agent.%Init()
        If $$$ISERR(sc) { Quit }
        Set agent.Model = ..Model
    } Catch e {
        Set sc = e.AsStatus()
    }
    If $$$ISERR(sc) { Quit $$$NULLOREF }
    Set ..Agent = agent
    Quit agent
}

}
