# Stand-ins for wt.exe and claude.exe, for the tests in this folder. Each one appends its arguments, its working
# folder, the CRESTORE_WAKE variables and the names of the CLAUDE* and HUB_* variables it was started with to the
# file named by FAKE_EXE_LOG, and starts nothing. A stand-in claude answers --help with one line that names --effort,
# which is all Restore-ClaudeSessions.ps1 asks of it.
# Built once per work folder, by Windows PowerShell's in-box C# compiler, and again when this source changes.
param([Parameter(Mandatory = $true)][string]$Dir)
$src = @'
using System;
using System.IO;
using System.Collections;
using System.Collections.Generic;
public static class FakeExe {
    public static int Main(string[] a) {
        string name = Path.GetFileNameWithoutExtension(System.Reflection.Assembly.GetExecutingAssembly().Location);
        if (name == "claude" && a.Length == 1 && a[0] == "--help") { Console.WriteLine("  --effort <level>   Effort level for the current session"); return 0; }
        string log = Environment.GetEnvironmentVariable("FAKE_EXE_LOG");
        if (!String.IsNullOrEmpty(log)) {
            var seen = new List<string>();
            foreach (DictionaryEntry e in Environment.GetEnvironmentVariables()) {
                string k = ((string)e.Key).ToUpperInvariant();
                if (k.StartsWith("CLAUDE") || k.StartsWith("HUB_")) seen.Add(k);
            }
            seen.Sort(StringComparer.Ordinal);
            var sw = new StringWriter();
            sw.WriteLine("### " + name + "\u001f" + Environment.CurrentDirectory + "\u001f" + Environment.GetEnvironmentVariable("CRESTORE_WAKE") + "\u001f" + Environment.GetEnvironmentVariable("CRESTORE_WAKE_AT") + "\u001f" + String.Join(",", seen.ToArray()));
            for (int i = 0; i < a.Length; i++) sw.WriteLine(a[i]);
            sw.WriteLine("###end");
            File.AppendAllText(log, sw.ToString(), new System.Text.UTF8Encoding(false));
        }
        return 0;
    }
}
'@
$srcFile = Join-Path $Dir 'FakeExe.cs'
$built = if (Test-Path -LiteralPath $srcFile) { (Get-Content -Raw -LiteralPath $srcFile).TrimEnd() } else { '' }
if (-not (Test-Path "$Dir\wt.exe") -or $built -ne $src.TrimEnd()) {
    New-Item -ItemType Directory $Dir -Force | Out-Null
    Remove-Item "$Dir\wt.exe", "$Dir\claude.exe" -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $srcFile -Value $src -Encoding utf8
    $build = "Add-Type -TypeDefinition (Get-Content -Raw -LiteralPath '$srcFile') -OutputAssembly '$Dir\wt.exe' -OutputType ConsoleApplication"
    powershell.exe -NoProfile -Command $build
    if (-not (Test-Path "$Dir\wt.exe")) { throw 'could not build the stand-in exe' }
    Copy-Item "$Dir\wt.exe" "$Dir\claude.exe"
}
