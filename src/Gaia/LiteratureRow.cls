/// One published paper about one Gaia source.
///
/// Populated from SIMBAD by gaia_simbad.py before an RLM run, and decomposed by
/// Gaia.Literature. A persistent class rather than a DDL table because
/// RLM.Source.Table reads the class dictionary to translate property names into
/// column names, and validates every declared dimension against
/// %Dictionary.CompiledProperty -- a DDL table would still work, but the property
/// and column names would differ (`pub_year` the column, `pubyear` the property)
/// for no benefit.
///
/// ClaimType and StudyType are derived at insert time rather than by the model.
/// A model asked to categorise its own evidence can categorise it into whatever
/// supports the answer it already has, and the categories are what the
/// decomposition is built on.
Class Gaia.LiteratureRow Extends %Persistent [ SqlTableName = GaiaLiterature ]
{

/// Gaia DR3 source this paper is about.
Property SourceId As %Integer;

/// SIMBAD/ADS bibcode, the citable identifier the agent is told to quote.
Property Bibcode As %String(MAXLEN = 40);

Property PubYear As %Integer;

Property Journal As %String(MAXLEN = 30);

Property Title As %String(MAXLEN = 500);

/// What the paper claims about why the star varies: rotation, eclipse,
/// pulsation, youth, other. Derived from the title.
Property ClaimType As %String(MAXLEN = 20);

/// targeted (the star is the subject) or survey (one row in a catalogue).
Property StudyType As %String(MAXLEN = 20);

Index BySource On SourceId;

}
