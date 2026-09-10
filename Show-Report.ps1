<#
Show-Report.ps1 -- print the A/B report from an existing results directory without re-running.

Reads results.jsonl (produced by Invoke-PerfHarness.ps1) and prints, per comparison, the median of
the primary frequency-invariant metric for each arm and the candidate-over-baseline delta.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Manifest,
    [string]$ResultsDir
)

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
foreach ($module in 'Common','Manifest','Results') { . (Join-Path $here "lib\$module.ps1") }

$m = Read-Manifest $Manifest $false
if (-not $ResultsDir) {
    $dir = if ($m.PSObject.Properties.Name -contains 'resultsDir') { $m.resultsDir } else { 'results' }
    $ResultsDir = if ([IO.Path]::IsPathRooted($dir)) { $dir } else { Join-Path $here $dir }
}

$report = Get-Report $ResultsDir $m
if (-not $report) { Write-Host "no results found in $ResultsDir"; return }

$report | ForEach-Object { [pscustomobject]$_ } |
    Format-Table comparison,workload,primaryMetric,basePrimary,candPrimary,primaryDeltaPct,baseWallNorm,candWallNorm,wallDeltaPct,oracle -AutoSize |
    Out-String | Write-Host
