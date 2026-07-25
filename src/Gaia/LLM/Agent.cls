/// The AI Hub agent this project's model calls go through.
///
/// Declarative on purpose: provider, model and key are parameters rather than
/// runtime arguments, so the configuration of a run is readable in the source and
/// is the same on every machine that compiles this class. The key itself is not --
/// `@{env.OPENAI_API_KEY}` is expanded by %AI.Utils.SettingStore at %Init, so the
/// secret lives in the environment and never in the repository.
///
/// It carries no tools and no toolsets. The RLM engine's whole point is that the
/// model chooses from an enumerated action space the engine owns; a tool would give
/// it a second, unenumerated one. It also avoids the failure the prototype
/// documented: a tool loop on gpt-4o-mini re-attempts discovery until %AICore
/// raises LoopDetected, and each attempt re-sends every prior result.
///
/// Nothing outside Gaia.LLM.AIHub should reference this class. The engine holds an
/// RLM.LLM and must not learn which provider answered.
Class Gaia.LLM.Agent Extends %AI.Agent
{

Parameter PROVIDER = "openai";

/// gpt-4o-mini, and the choice is a cost one. A decomposition run is up to 18
/// calls of a few hundred characters each; the report is a bonus deliverable and
/// is not worth a frontier model's per-call price. Gaia.LLM.AIHub can override it
/// per instance, so comparing models is a property change rather than an edit here.
Parameter MODEL = "gpt-4o-mini";

/// Expanded at %Init from the environment. A literal key here would be committed.
Parameter APIKEY = "@{env.OPENAI_API_KEY}";

/// Deterministic. Two runs of the same decomposition over the same table should
/// produce the same report, and at a non-zero temperature they do not -- which
/// makes a change in the report unattributable to the change that caused it.
Property Temperature As %Float [ InitialExpression = 0 ];

}
