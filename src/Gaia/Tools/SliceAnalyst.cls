/// A %AI.Agent.SubAgent: the analyst the root delegates one slice to.
///
/// %AI.Agent.SubAgent is a Tool that spawns a child agent. It advertises a single
/// `Execute(userRequest)` tool whose description is this class's system prompt, and
/// on invocation calls ParentAgent.CreateSubAgent(), configures the child, runs it
/// to completion and returns its final content. So delegation here is a tool call
/// the root's model decides to make, not a loop the ObjectScript runs.
///
/// The child gets the same narrow survey toolset as the root, which is what makes
/// the delegation useful: the child peeks at its own slice and any sub-slices it
/// wants, and only its one-paragraph conclusion comes back. The root's context
/// grows by a paragraph per slice rather than by every statistic the child looked
/// at, and that is the same context bound Gaia.RLM gets from its explicit
/// recursion, reached by a different route.
Class Gaia.Tools.SliceAnalyst Extends %AI.Agent.SubAgent
{

/// The model the children run on.
///
/// %AI.Agent.CreateSubAgent() copies the parent's Model into the child before
/// handing it to ConfigureSubAgent, so without this every child inherits the root's
/// model. The two jobs are not the same size: the root reads the menu, plans a
/// decomposition and synthesizes the final report, while each child summarizes one
/// slice of pre-computed aggregates in a paragraph. Most of a run's calls are the
/// children, so this is the parameter that decides what a run costs.
Parameter MODEL = "gpt-4.1-nano";

Method GetSystemPrompt() As %String
{
    Quit "You are an astronomer analyzing one slice of Gaia DR3 epoch photometry."
        _$Char(10,10)
        _"Call PeekSlice on the slice you were asked about. If its "
        _"ESA_reject_fraction spread (sd) is large, the slice mixes different "
        _"populations: peek at two or three sub-slices to find out which, using a "
        _"nested slice name. If the spread is small, one peek is enough."
        _$Char(10,10)
        _"Then reply with ONE paragraph, at most four sentences, about this slice."
        _$Char(10,10)
        _"Ground every claim in the numbers you were given. Distinguish "
        _"instrumental artifacts from real variability: a near-zero minimum flux "
        _"makes a relative change explode, and a low epoch count means one bad "
        _"measurement drives the whole result. If NGBoost_predicted_sigma is large, "
        _"say the model is uncertain here; if NGBoost_prediction_error is large, say "
        _"the model is wrong here. Those are different claims."_$Char(10,10)
        _"Quote only figures the tools returned, under the exact metric name they "
        _"were given under, and never compute a new one. Do not write SQL; the only "
        _"way to see data is PeekSlice."
}

Method ConfigureSubAgent(agent As %AI.Agent)
{
    Set agent.Model = ..#MODEL

    // The child gets the tools, not a SliceAnalyst of its own: a subagent that can
    // spawn subagents has no bounded depth, and the call budget in Gaia.RLM2 would
    // be the only thing standing between a bad plan and a very long run.
    Do agent.ToolManager.AddTool(##class(Gaia.Tools.Survey).%New())
}

}
