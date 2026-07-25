/// Installer hook: load the optional analysis layer only where it can compile.
///
/// The contest entry is `^RunScript` and the two IntegratedML models. Everything
/// else in this repository -- Gaia.Analyst, Gaia.RLM, Gaia.RLM2, Gaia.Source and
/// the tool classes -- is an optional deliverable that extends `%AI.Agent`,
/// `%AI.Tool` or `RLM.Source.Table`. None of those three exist on a public
/// community image: AI Hub ships only in the 2026.3 AI preview, and rlm-core
/// arrives as a git submodule that an IPM install does not carry.
///
/// So a manifest that lists `Gaia.PKG` cannot install anywhere except the author's
/// own container. It fails with `Class '%AI.Agent' ... does not exist` on six
/// classes at once, and IPM reports the whole module as failed -- including
/// `^RunScript`, which had nothing wrong with it. The judge's entry point is lost
/// to a bonus feature's dependency.
///
/// This class is what the manifest lists instead. It has no superclass and no
/// dependency, so it compiles everywhere, and at Activate it decides. Where the
/// dependencies are present the analysis layer is loaded and the install is what
/// it always was; where they are absent the layer is skipped and the reason is
/// printed. Skipping quietly would be worse than failing: a user who never sees
/// the line has no way to tell a deliberate omission from a broken package.
///
/// Docker remains the supported route for a full run -- `^RunScript` shells out to
/// `irispython` against a fixed path under /home/irisowner/dev, which an IPM
/// install does not create. What this makes true is that `zpm load` succeeds and
/// the routine is callable, which is what an OpenExchange review checks.
Class Gaia.Install Extends %RegisteredObject
{

/// Classes the analysis layer needs before any of it will compile.
///
/// Checked as a set rather than one at a time because they arrive as a set: an
/// image either has the AI preview and the submodule or it has neither, and a
/// partial load would leave classes referring to each other across the gap.
ClassMethod Prerequisites() As %List
{
    Quit $ListBuild("%AI.Agent", "%AI.Tool", "RLM.Source.Table", "RLM.Slice")
}

/// Which prerequisites are absent. Empty means the layer can be loaded.
ClassMethod Missing() As %String
{
    Set missing = "", prereqs = ..Prerequisites()
    For i = 1:1:$ListLength(prereqs) {
        Set class = $List(prereqs, i)
        Continue:##class(%Dictionary.CompiledClass).%ExistsId(class)
        Set missing = missing_$Select(missing = "":"", 1:", ")_class
    }
    Quit missing
}

/// IPM Activate hook. `root` is the module's source directory, passed as
/// ${root} by module.xml, because an installed module is compiled from wherever
/// the user cloned or downloaded it rather than from a fixed path.
///
/// Returns OK even when it skips. A missing bonus feature is not an install
/// failure, and reporting it as one is exactly the behaviour being fixed.
ClassMethod OnActivate(root As %String = "") As %Status
{
    Set missing = ..Missing()
    If missing '= "" {
        Write "[gaia-iml] analysis layer skipped: ", missing, " not present on this ",
            "instance.", !
        Write "[gaia-iml] ^RunScript and the IntegratedML models are installed and ",
            "unaffected.", !
        Write "[gaia-iml] The AI Hub and RLM reports need the 2026.3 AI preview image; ",
            "see README.", !
        Quit $$$OK
    }

    // Load order is not cosmetic: Gaia.Source extends RLM.Source.Table, so the
    // library has to be compiled already. On the AI preview image iris.script has
    // done that before this runs; here it is only the project's own classes.
    Set dir = ##class(%File).NormalizeDirectory("Gaia", ..SourceDir(root))
    If '##class(%File).DirectoryExists(dir) {
        Write "[gaia-iml] analysis layer skipped: ", dir, " is absent from the package.", !
        Quit $$$OK
    }
    Set sc = $System.OBJ.LoadDir(dir, "ck", , 1)
    If $$$ISERR(sc) { Quit sc }
    Write "[gaia-iml] analysis layer loaded: ^Analyze, ^RLMAudit, ^RLMTriage, ",
        "^RLM2Audit are available.", !
    Quit $$$OK
}

/// Where this module's .cls files are, given the module root.
///
/// Separate from OnActivate so a test can assert the path without an install, and
/// because `SourcesRoot` is `src` in module.xml -- two statements of one layout is
/// how they come to disagree.
ClassMethod SourceDir(root As %String) As %String
{
    Quit ##class(%File).NormalizeDirectory("src", root)
}

}
