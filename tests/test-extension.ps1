# The VS Code extension, run by node with a stand-in `vscode` module (test-extension.cjs). Nothing opens.
param()
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { 'skip  node is not on PATH'; 'failures: 0'; exit 0 }
& $node.Source (Join-Path $PSScriptRoot 'test-extension.cjs')
exit $LASTEXITCODE
