<#
collect.ps1 -- a stand-in "profiler" for exercising the harness end to end without admin or PerfView.

It runs the workload (passed as one command line), captures its output, and writes that capture to
the trace path. A real collector would write an ETL here instead; the point is that the harness
treats the collector as an opaque command that leaves something at {trace} for the extractor to read.
#>
param(
    [Parameter(Mandatory)] [string]$Trace,
    [Parameter(Mandatory)] [string]$Command
)

$output = & cmd /c $Command 2>&1
Set-Content -LiteralPath $Trace -Value $output
exit 0
