/// Slice grammar shared by the two RLM implementations.
///
/// Gaia.RLM never lets a model name a slice at all: the ObjectScript walks the
/// whitelist itself and the model only picks a dimension key. Gaia.RLM2 delegates
/// the walk to the model, so the model does have to name slices, and this class
/// is what keeps that from becoming a SQL injection surface.
///
/// A slice is a path of whitelisted tokens:
///
///     reject_level:severe
///     reject_level:severe/epoch_count:few
///
/// Each component is dimension:child, both looked up in Gaia.RLM.Dimensions().
/// Resolve() returns the predicate for the path or fails; it never passes any
/// part of the input string through into SQL. The model's string is a lookup key,
/// not a fragment, so "reject_level:severe' OR 1=1 --" fails to match a token and
/// is refused rather than escaped.
Class Gaia.Slice Extends %RegisteredObject
{

/// Maximum path depth. Matches Gaia.RLM's MAXDEPTH so the two implementations
/// explore the same space.
Parameter MAXDEPTH = 3;

/// The token the model uses to name a child slice.
///
/// Stored on each child in Gaia.RLM.Dimensions() rather than derived from the
/// label. Deriving it (first word, lowercased) collided: model_confidence's four
/// children all start with "model", and two of variability's start with
/// "variable,". A collision means Resolve() silently returns whichever child
/// matched first, so the model asks for one slice and analyzes another.
///
/// UnitTest.Gaia.RLM2 checks the tokens stay unique within each dimension.
ClassMethod ChildToken(child As %DynamicObject) As %String
{
    Quit $ZConvert(child.token, "L")
}

/// Resolve a slice path into a SQL predicate and a human label.
///
/// Fails closed: on any failure `where` is set to "" so a caller that ignores the
/// status cannot accidentally query with a partial predicate.
ClassMethod Resolve(path As %String, Output where As %String, Output label As %String) As %Status
{
    Set where = "", label = ""
    Set path = $ZStrip(path, "<>WC")
    If path = "" { Quit $$$ERROR($$$GeneralError, "empty slice") }

    Set depth = $Length(path, "/")
    If depth > ..#MAXDEPTH {
        Quit $$$ERROR($$$GeneralError, "slice is "_depth_" levels deep, the maximum is "_..#MAXDEPTH)
    }

    Set dims = ##class(Gaia.RLM).Dimensions()
    Set parts = "", labels = "", used = "", resolved = 0
    For i = 1:1:depth {
        Set comp = $ZStrip($Piece(path, "/", i), "<>WC")
        // Exactly two colon-separated tokens. Anything else (a bare predicate, a
        // trailing colon, an injected clause) has the wrong shape and stops here.
        If $Length(comp, ":") '= 2 {
            Quit
        }
        Set dim = $ZConvert($ZStrip($Piece(comp, ":", 1), "<>WC"), "L")
        Set tok = $ZConvert($ZStrip($Piece(comp, ":", 2), "<>WC"), "L")
        If (dim = "") || (tok = "") { Quit }
        If 'dims.%IsDefined(dim) { Quit }
        // One dimension per path. Slicing twice by the same key yields either the
        // same rows or none, and either way the model has stopped making progress.
        If (","_used_",")[(","_dim_",") { Quit }

        Set spec = dims.%Get(dim), match = ""
        For c = 1:1:spec.children.%Size() {
            Set child = spec.children.%Get(c - 1)
            Continue:..ChildToken(child)'=tok
            Set match = child
            Quit
        }
        If '$IsObject(match) { Quit }

        Set parts = parts_$Select(parts="":"",1:" AND ")_"("_match.where_")"
        Set labels = labels_$Select(labels="":"",1:" / ")_match.label
        Set used = used_$Select(used="":"",1:",")_dim
        Set resolved = resolved + 1
    }

    // Every component had to resolve. A partially resolved path is a refusal, not
    // a narrower query. Counted explicitly rather than by $Length(used, ","),
    // which is 1 for the empty string and so would pass when nothing resolved.
    If resolved '= depth {
        Quit $$$ERROR($$$GeneralError, "'"_path_"' is not a valid slice. "_..MenuBrief())
    }

    Set where = parts, label = labels
    Quit $$$OK
}

/// One-line reminder of the grammar, appended to every refusal so an agent can
/// correct itself on the next call instead of guessing.
ClassMethod MenuBrief() As %String
{
    Set dims = ##class(Gaia.RLM).Dimensions()
    Set keys = "", it = dims.%GetIterator()
    While it.%GetNext(.key, .spec) {
        Set keys = keys_$Select(keys="":"",1:", ")_key
    }
    Quit "Use dimension:child, optionally nested with '/'. Dimensions: "_keys
        _". Call ListDimensions for the child tokens."
}

/// The full menu the delegating agent is shown: every dimension, what it means,
/// and the exact child tokens the grammar accepts.
ClassMethod Menu() As %String
{
    Set dims = ##class(Gaia.RLM).Dimensions()
    Set out = "", it = dims.%GetIterator()
    While it.%GetNext(.key, .spec) {
        Set out = out_"- `"_key_"`: "_spec.describe_$Char(10)
        For c = 1:1:spec.children.%Size() {
            Set child = spec.children.%Get(c - 1)
            Set out = out_"    - `"_key_":"_..ChildToken(child)_"` = "_child.label_$Char(10)
        }
    }
    Quit out
}

}
