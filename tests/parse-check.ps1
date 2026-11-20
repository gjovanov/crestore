# Parse the session-restore scripts with the PowerShell parser and report syntax errors; run PSScriptAnalyzer if present.
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Files)
$bad = 0
foreach ($f in $Files) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { $bad += $errors.Count; foreach ($e in $errors) { "PARSE  $(Split-Path $f -Leaf):$($e.Extent.StartLineNumber): $($e.Message)" } }
    else { "parse ok  $(Split-Path $f -Leaf)" }
}
if (Get-Module -ListAvailable PSScriptAnalyzer) {
    foreach ($f in $Files) {
        $r = Invoke-ScriptAnalyzer -Path $f -Severity Error, Warning -ExcludeRule PSAvoidUsingWriteHost, PSUseShouldProcessForStateChangingFunctions, PSUseApprovedVerbs, PSUseSingularNouns, PSReviewUnusedParameter, PSAvoidUsingEmptyCatchBlock, PSUseBOMForUnicodeEncodedFile, PSAvoidOverwritingBuiltInCmdlets
        foreach ($x in $r) { "LINT   $(Split-Path $f -Leaf):$($x.Line) [$($x.RuleName)] $($x.Message)" }
        if (-not $r) { "lint ok   $(Split-Path $f -Leaf)" }
    }
}
exit $bad
