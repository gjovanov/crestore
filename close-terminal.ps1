# End a VS Code terminal's shell with exit code 0, so the tab closes without an error toast.
# A normal kill exits non-zero and VS Code then shows "terminal process terminated" for each tab.
param([int]$ShellPid)
$sig = @'
using System; using System.Runtime.InteropServices;
public class TerminalCloser {
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint a, bool b, int p);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateProcess(IntPtr h, uint c);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
}
'@
Add-Type -TypeDefinition $sig
$p = Get-CimInstance Win32_Process -Filter "ProcessId=$ShellPid"
if (-not $p -or $p.Name -ne 'pwsh.exe') { "refused: $ShellPid is not a pwsh process"; exit 1 }
$h = [TerminalCloser]::OpenProcess(0x0001, $false, $ShellPid)
[void][TerminalCloser]::TerminateProcess($h, 0)
[void][TerminalCloser]::CloseHandle($h)
