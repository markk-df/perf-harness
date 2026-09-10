<#
extract.ps1 -- a stand-in metric extractor, the counterpart to testkit/collect.ps1.

It reads the trace, pulls the deterministic "work done <sum>" value the demo workload prints, and
writes it as a JSON object of numbers. The harness flattens that object so any field (here workSum)
can be chosen as the primaryMetric. This mirrors the real extractor contract: {trace} in, {out} JSON
out, frequency-invariant numbers only.
#>
param(
    [Parameter(Mandatory)] [string]$Trace,
    [Parameter(Mandatory)] [string]$Out
)

$text = Get-Content -LiteralPath $Trace -Raw
if ($text -match 'work done\s+([0-9.eE+]+)') {
    $sum = [double]$Matches[1]
} else {
    $sum = 0
}

@{ workSum = $sum } | ConvertTo-Json | Set-Content -LiteralPath $Out
exit 0
