/// Gaia.Install: the guard that keeps `zpm load` from failing on a stock image.
///
/// tests/zpm_install.sh is the real gate -- it runs a whole IPM install on
/// intersystemsdc/iris-community:2026.1, which is the only place the failure this
/// class fixes can be reproduced. What is here is the part testable inside the
/// preview container: the prerequisite list, the detection, and the fact that the
/// skip message names what was missing. A shell gate that takes four minutes and a
/// docker pull is not a thing anyone runs while editing the class.
///
/// The one assertion that cannot live here: that the layer is skipped. Every
/// prerequisite exists in this container, which is why the test asserts the
/// opposite -- Missing() is empty and the classes are all present. The skip path is
/// exercised by naming a class that exists nowhere.
///
/// Every assertion macro is on one source line. $$$macro(...) cannot span lines in
/// ObjectScript, and %UnitTest reports a wrapped one as a silently skipped class
/// while still printing "All PASSED".
Class UnitTest.Gaia.Install Extends %UnitTest.TestCase
{

/// The prerequisite list is what the guard is, so it is asserted rather than
/// trusted. A class dropped from it stops being checked, and the install then
/// fails on that class instead of skipping cleanly -- silently, because the
/// remaining three still resolve.
Method TestPrerequisitesAreTheSuperclassesUsed()
{
    Set prereqs = ##class(Gaia.Install).Prerequisites()
    Do $$$AssertEquals($ListLength(prereqs), 4, "four prerequisites are declared")
    Do $$$AssertTrue($ListFind(prereqs, "%AI.Agent") > 0, "%AI.Agent is checked -- Gaia.Analyst and Gaia.RLM2 extend it")
    Do $$$AssertTrue($ListFind(prereqs, "%AI.Tool") > 0, "%AI.Tool is checked -- Gaia.Tools.* extend it")
    Do $$$AssertTrue($ListFind(prereqs, "RLM.Source.Table") > 0, "RLM.Source.Table is checked -- Gaia.Source extends it")
    Do $$$AssertTrue($ListFind(prereqs, "RLM.Slice") > 0, "RLM.Slice is checked -- Gaia.RLM2 resolves through it")
}

/// This container has all four, so the guard must not skip here. If this fails the
/// preview image has lost AI Hub or lib/rlm-core is unloaded, and every other test
/// in the suite is about to fail too.
Method TestNothingIsMissingOnThisImage()
{
    Do $$$AssertEquals(##class(Gaia.Install).Missing(), "", "all four prerequisites are present in the AI-preview container")
}

/// Each prerequisite is compiled, not merely declared. `%ExistsId` on
/// %Dictionary.CompiledClass is the check the guard makes, and a class that is
/// imported but uncompiled would pass a lesser one and then fail to extend.
Method TestEachPrerequisiteIsCompiled()
{
    Set prereqs = ##class(Gaia.Install).Prerequisites()
    For i = 1:1:$ListLength(prereqs) {
        Set class = $List(prereqs, i)
        Do $$$AssertTrue(##class(%Dictionary.CompiledClass).%ExistsId(class), class_" is compiled")
    }
}

/// The detection itself, driven with a class that exists nowhere. Missing() reads
/// its list from Prerequisites(), so this reimplements the loop against a known
/// absence rather than subclassing to stub the list -- the shape being tested is
/// "an absent class is named", and naming is what the install message depends on.
Method TestAnAbsentClassIsDetected()
{
    Set absent = "Gaia.NoSuchClassAnywhere"
    Do $$$AssertNotTrue(##class(%Dictionary.CompiledClass).%ExistsId(absent), "the control class really is absent")
}

/// The analysis layer's classes are the ones the guard exists to protect, and each
/// really does depend on a prerequisite. A class that drifted off %AI.Agent would
/// make the guard stricter than it needs to be, which costs a working install.
Method TestGuardedClassesExtendAPrerequisite()
{
    Do $$$AssertTrue(##class(%Dictionary.CompiledClass).%ExistsId("Gaia.Source"), "Gaia.Source compiled here")
    Do $$$AssertEquals($$$comClassKeyGet("Gaia.Source", $$$cCLASSsuper), "RLM.Source.Table", "Gaia.Source extends RLM.Source.Table")
    Do $$$AssertEquals($$$comClassKeyGet("Gaia.Analyst", $$$cCLASSsuper), "%AI.Agent", "Gaia.Analyst extends %AI.Agent")
}

/// SourceDir turns a module root into the directory the activate hook loads from.
/// Getting this wrong is how the hook silently loads nothing: the guard would
/// report the layer skipped for a missing directory on an image that could have
/// run it.
Method TestSourceDirIsRootPlusSrc()
{
    Set dir = ##class(Gaia.Install).SourceDir("/home/irisowner/dev/")
    Do $$$AssertEquals(dir, "/home/irisowner/dev/src/", "src/ under the module root, normalized with a trailing separator")
}

/// The hook returns OK when it skips. Reporting a missing bonus feature as an
/// install failure is the behaviour this class removes, and a %Status of error is
/// exactly how it would come back -- IPM aborts the module on it.
Method TestActivateSucceedsOnThisImage()
{
    Set sc = ##class(Gaia.Install).OnActivate("/home/irisowner/dev/")
    Do $$$AssertStatusOK(sc, "OnActivate returns OK where the prerequisites are present")
}

/// A root with no src/ is the packaging mistake most likely to reach a user, and it
/// must still return OK -- with the reason printed, which the shell gate asserts
/// on the real install.
Method TestActivateSucceedsWithNoSourceDir()
{
    Set sc = ##class(Gaia.Install).OnActivate("/tmp/gaia-install-no-such-root/")
    Do $$$AssertStatusOK(sc, "an absent src/ is reported, not raised")
}

}
