<#
Setup-Demo.ps1 -- create a throwaway git repo so the harness can be exercised end to end in seconds.

The repo has two branches that stand in for "before" and "after" an optimization: demo/base does
more work per run than demo/faster. Paired with examples/demo.manifest.json (which uses the 'time'
collector, so no profiler or admin rights are needed) this proves the build -> run -> measure ->
report loop on an arbitrary project. The workload is a Node.js CPU loop, so it starts
quickly and its wall time scales cleanly with both work and CPU frequency.

The repo is created next to this script (examples/demo/repo), so the demo is self-contained and
runs identically on Windows, Linux, and macOS -- including a GitHub Codespace.
#>

$repo = Join-Path $PSScriptRoot 'repo'

if (Test-Path $repo) { Remove-Item -Recurse -Force $repo }
New-Item -ItemType Directory -Force -Path $repo | Out-Null

git -C $repo init -q
git -C $repo config user.email 'demo@example.com'
git -C $repo config user.name  'demo'

function Add-WorkBranch([string]$Branch, [long]$Iterations) {
    $work = "const n = $Iterations;`nlet sum = 0;`nfor (let i = 0; i < n; i++) sum += Math.sqrt(i);`nconsole.log('work done', sum);`n"
    Set-Content -LiteralPath (Join-Path $repo 'work.js') -Value $work
    git -C $repo add work.js
    git -C $repo commit -q -m "work at $Iterations iterations ($Branch)"
    git -C $repo branch -f $Branch
}

Add-WorkBranch 'demo/base'   400000000
Add-WorkBranch 'demo/faster' 120000000
git -C $repo checkout -q demo/base

Write-Host "demo repo ready: $repo"
Write-Host "branches: demo/base (slow), demo/faster (fast)"
Write-Host "run: pwsh -File ./Invoke-PerfHarness.ps1 -Manifest ./examples/demo.manifest.json -NoStabilize"
