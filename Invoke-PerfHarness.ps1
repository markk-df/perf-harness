<#
Invoke-PerfHarness.ps1 -- run a commit-to-commit performance benchmark described by a manifest.

It warms up each (variant, workload) pair once, then runs the measured repetitions round-robin:
every comparison advances one rep before any advances to the next, and within a rep a comparison's
two variants run back-to-back so residual drift hits both equally. An optional run.budgetHours caps
the wall clock, stopping between cells so the run lands near a target duration with every comparison
measured a comparable number of times. Every repetition is gated on output correctness and reduced
to frequency-invariant metrics. Progress is journalled, so -Resume continues an interrupted run.
Power settings are always restored on the way out. In the default (worktree) build model per-variant
worktrees are kept for reuse unless -CleanWorktrees is given; in the switch build model all variants
share one checkout that is branch-switched and rebuilt per cell.

Usage:
  .\Invoke-PerfHarness.ps1 -Manifest examples\demo.manifest.json
  .\Invoke-PerfHarness.ps1 -Manifest ... -Only speedup -Resume
  .\Invoke-PerfHarness.ps1 -Manifest ... -SkipBuild -NoStabilize
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Manifest,
    [string[]]$Only,
    [switch]$Resume,
    [switch]$SkipBuild,
    [switch]$NoStabilize,
    [switch]$CleanWorktrees,
    [switch]$ReportOnly,
    [string[]]$Aggregate,
    [switch]$AllMetrics,
    [string]$Markdown,
    [string]$Json
)

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
foreach ($module in 'Common','Manifest','Repo','Environment','Run','Results') {
    . (Join-Path $here "lib\$module.ps1")
}

function Invoke-WarmupPhase($Manifest, $Comparisons, $Artifacts, [string]$ResultsDir, $Deadline) {
    # Warm-ups prime the JIT and filesystem cache once per (variant, workload) pair. Because the
    # measured phase is round-robin -- every comparison advances one rep before any advances two --
    # warming here (rather than per comparison, per round) primes each pair a single time and never
    # repeats that cost on later rounds. A pair shared by two comparisons (e.g. base on 'consts') is
    # warmed once.
    $warmups = $Manifest.run.warmups
    if ($warmups -le 0) { return }
    $warmed = New-Object System.Collections.Generic.HashSet[string]
    foreach ($comparison in $Comparisons) {
        $workload = $comparison.workload
        foreach ($arm in @($comparison.baseline, $comparison.candidate)) {
            if (-not $warmed.Add("$arm|$workload")) { continue }
            if ($Deadline -and (Get-Date) -ge $Deadline) { Write-Log 'time budget reached -- skipping remaining warm-ups' 'WARN'; return }
            $variant  = Get-Variant $Manifest $arm
            $artifact = Resolve-CellArtifact $Manifest $variant $Artifacts
            for ($w = 1; $w -le $warmups; $w++) {
                Write-Log "warmup $arm/$workload #$w (discarded)"
                Invoke-Warmup $Manifest $variant $workload $artifact `
                    (Join-Path $ResultsDir "warmup_${arm}_${workload}.log")
            }
        }
    }
}

function Invoke-MeasuredCell($Manifest, $Comparison, [string]$Arm, [int]$Rep, $Artifacts, [string]$ResultsDir, [string]$TraceDir, [string]$PrimaryMetric, $Provenance, $Done) {
    $workload = $Comparison.workload
    $cell = "$($Comparison.name)|$Arm|$workload|$Rep"
    if ($Done.Contains($cell)) { Write-Log "skip $cell (done)"; return }
    Assert-DiskSpace $Manifest

    $stem  = '{0}_{1}_{2}_r{3}' -f $Comparison.name, $Arm, $workload, $Rep
    $trace = Join-Path $TraceDir "$stem.etl"
    $log   = Join-Path $ResultsDir "$stem.collector.log"

    Write-Log "run $cell  freq=$(Get-FrequencyPercent)%"
    $variant  = Get-Variant $Manifest $Arm
    $artifact = Resolve-CellArtifact $Manifest $variant $Artifacts
    $record = Invoke-MeasuredRep $Manifest $variant $workload $artifact $trace $log
    $record.runId         = $Provenance.runId
    $record.variantCommit = $Provenance.commits[$Arm]
    $record.setupHash     = $Provenance.setupHash
    $record.telemetryHash = $Provenance.telemetryHash

    $keepTrace = (Get-KeepTrace $Manifest) -and ($Rep -eq 1)
    Add-Result $ResultsDir $Comparison.name $Rep $PrimaryMetric $keepTrace $record
    if (-not $keepTrace) { Remove-TraceSet $record.tracePath }

    $flag = if ($record.oracle -eq 'FAIL' -or $record.exit -ne 0) { 'REVIEW' } else { 'ok' }
    Write-Log ("done $cell  wall=$($record.wallSec)s freq=$($record.freqPct)% norm=$($record.wallSecNorm)s exit=$($record.exit) oracle=$($record.oracle) [$flag]") `
              $(if ($flag -eq 'REVIEW') { 'ERROR' } else { 'INFO' })

    if ($record.oracle -eq 'FAIL') { Save-OracleIncident $Manifest $workload $cell $ResultsDir }

    Add-JournalEntry $ResultsDir $Done $cell
}

function New-Provenance($Manifest, $Variants) {
    # Stamp every cell with what makes runs comparable: the commit each variant was built from (proves
    # "same code" when pooling), and fingerprints of the setup (workloads/build) and telemetry
    # (collection regime). The aggregator uses these to refuse incomparable pooling and to know when a
    # metric spans collection regimes.
    $commits = @{}
    foreach ($variant in $Variants) { $commits[$variant.label] = Get-VariantCommit $Manifest $variant }
    @{
        runId         = '{0}_{1:x}' -f (Get-Date -Format 'yyyyMMddTHHmmss'), (Get-Random)
        setupHash     = Get-TextHash (($Manifest.build | ConvertTo-Json -Depth 6 -Compress) + ($Manifest.workloads | ConvertTo-Json -Depth 6 -Compress))
        telemetryHash = Get-TextHash ($Manifest.telemetry | ConvertTo-Json -Depth 8 -Compress)
        commits       = $commits
    }
}

function Get-Variant($Manifest, [string]$Label) { $Manifest.variants | Where-Object { $_.label -eq $Label } }

function Resolve-CellArtifact($Manifest, $Variant, $Artifacts) {
    # In the switch build model all variants share one checkout, so the artifact is produced on demand
    # by checking out and building the variant's branch. In the worktree model it was already built up
    # front and is looked up by label.
    if (Test-SwitchMode $Manifest) { Use-Variant $Manifest $Variant }
    else { $Artifacts[$Variant.label] }
}

function Get-SelectedVariants($Manifest, $Comparisons) {
    $labels = $Comparisons | ForEach-Object { $_.baseline; $_.candidate } | Sort-Object -Unique
    $labels | ForEach-Object { Get-Variant $Manifest $_ }
}

function Resolve-ResultsDir($Manifest, [string]$Here) {
    $dir = if ($Manifest.PSObject.Properties.Name -contains 'resultsDir') { $Manifest.resultsDir } else { 'results' }
    if ([IO.Path]::IsPathRooted($dir)) { $dir } else { Join-Path $Here $dir }
}

function Get-PrimaryMetric($Manifest, $Comparison) {
    # A comparison may override the global metric so each headline reflects the invariant that actually
    # moves for that change (e.g. instructions retired for an algorithmic change, % time in GC for a
    # GC-mode change) rather than one metric that is meaningful for only some comparisons.
    if ($Comparison.PSObject.Properties.Name -contains 'primaryMetric') { $Comparison.primaryMetric }
    else { $Manifest.telemetry.primaryMetric }
}

function Resolve-WorktreeRoot($Manifest) {
    if ($Manifest.PSObject.Properties.Name -contains 'worktreeRoot') { $Manifest.worktreeRoot }
    else { Join-Path ([IO.Path]::GetTempPath()) 'perf-harness-worktrees' }
}

function Resolve-TraceDir($Manifest, [string]$ResultsDir) {
    if ($Manifest.telemetry.PSObject.Properties.Name -contains 'traceDir') { $Manifest.telemetry.traceDir }
    else { Join-Path $ResultsDir 'traces' }
}

function Get-KeepTrace($Manifest) {
    if ($Manifest.run.PSObject.Properties.Name -contains 'keepTrace') { $Manifest.run.keepTrace -ne 'none' }
    else { $true }
}

function Assert-DiskSpace($Manifest) {
    if ($Manifest.run.PSObject.Properties.Name -notcontains 'minFreeGB') { return }
    $free = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
    if ($free -lt $Manifest.run.minFreeGB) { throw "disk guard: ${free}GB free < required $($Manifest.run.minFreeGB)GB" }
}

function Wait-Cooldown($Manifest) {
    $seconds = if ($Manifest.run.PSObject.Properties.Name -contains 'cooldownSec') { $Manifest.run.cooldownSec } else { 0 }
    if ($seconds -gt 0) { Write-Log "cooldown ${seconds}s"; Start-Sleep -Seconds $seconds }
}

function Get-Deadline($Manifest) {
    # Optional wall-clock cap for the whole run. When run.budgetHours is set, the round-robin loop
    # stops launching new cells once the deadline passes, so an overnight run lands near a target
    # duration and -- because rounds are round-robin -- every comparison ends with the same rep count
    # give or take the final partial round. The clock starts when the manifest is read, so it covers
    # setup, build, warm-up, and measurement (the whole time the machine is occupied).
    if ($Manifest.run.PSObject.Properties.Name -notcontains 'budgetHours') { return $null }
    $hours = [double]$Manifest.run.budgetHours
    if ($hours -le 0) { return $null }
    (Get-Date).AddHours($hours)
}

function Show-ReportTable($Report) {
    if (-not $Report) { Write-Log 'no results to report'; return }
    $Report | ForEach-Object { [pscustomobject]$_ } |
        Format-Table comparison,workload,primaryMetric,basePrimary,candPrimary,primaryDeltaPct,wallDeltaPct,oracle -AutoSize |
        Out-String | Write-Host
}

function Show-AggregateReport($Report, [switch]$AllMetrics) {
    if (-not $Report) { Write-Log 'no results to aggregate'; return }
    $Report | ForEach-Object { [pscustomobject]$_ } |
        Format-Table comparison,primaryMetric,status,baseCommit,candCommit,baseN,candN,baseMedian,candMedian,deltaPct,wallBase,wallCand,wallDeltaPct,spread,regimes,oracle -AutoSize |
        Out-String | Write-Host

    foreach ($comparison in $Report) {
        if ($comparison.status -eq 'INVALID:oracle') {
            $detail = @($comparison.incidents | ForEach-Object { "$($_.variant) rep$($_.rep)@$($_.runId)" }) -join ', '
            Write-Log "comparison '$($comparison.comparison)': INVALID:oracle -- output diverged in $(@($comparison.incidents).Count) rep(s) [$detail]; improvement invalidated, delta withheld -- investigate before trusting any speed claim" 'ERROR'
        } elseif ($comparison.status -like 'CONFLICT*') {
            Write-Log "comparison '$($comparison.comparison)': $($comparison.status) -- refusing to pool (base commit '$($comparison.baseCommit)', candidate '$($comparison.candCommit)'); delta withheld" 'ERROR'
        } elseif ($comparison.status -eq 'unverified') {
            Write-Log "comparison '$($comparison.comparison)': some rows predate provenance stamping -- pooled without a same-code guarantee" 'WARN'
        }
    }

    if ($AllMetrics) {
        foreach ($comparison in $Report) {
            Write-Host "`n== $($comparison.comparison): every metric =="
            $comparison.detail | ForEach-Object { [pscustomobject]$_ } |
                Format-Table metric,baseN,candN,baseMedian,candMedian,deltaPct,baseSpreadPct,candSpreadPct,mixedRegime -AutoSize |
                Out-String | Write-Host
        }
    }
}

function Invoke-Setup($Manifest) {
    # A one-time cleanup/preparation phase before any build or measurement: kill stray processes,
    # reclaim disk, reset scratch checkouts, etc. Commands run through cmd (so taskkill, git, and shell
    # operators work) and are best-effort -- a non-zero exit (e.g. taskkill finding no such process) is
    # logged but does not stop the run, because cleanup steps routinely "fail" harmlessly.
    if ($Manifest.PSObject.Properties.Name -notcontains 'setup') { return }
    $commands = @($Manifest.setup.commands)
    if ($commands.Count -eq 0) { return }
    Write-Log "setup phase: $($commands.Count) command(s)"
    foreach ($command in $commands) {
        $exit = Invoke-Shell $command $null
        Write-Log "setup exit=$exit  $command"
    }
}

function Invoke-Harness {
    $m            = Read-Manifest $Manifest (-not ($Aggregate -or $ReportOnly)) ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Manifest)))
    if (-not ($Aggregate -or $ReportOnly) -and (Test-CloneMode $m)) {
        # Build inside a private clone seeded from the local repo, then proceed exactly as switch mode:
        # one shared, path-stable checkout that the user's working repo never participates in.
        $cloneDir = [IO.Path]::GetFullPath((Resolve-CloneDir $m))
        Initialize-Clone $m $cloneDir
        $m.repo = $cloneDir
        $m.buildMode = 'switch'
    }
    $deadline     = Get-Deadline $m
    $resultsDir   = Resolve-ResultsDir $m $here
    $switchMode   = Test-SwitchMode $m
    $worktreeRoot = if ($switchMode) { $null } else { Resolve-WorktreeRoot $m }
    $traceDir     = Resolve-TraceDir $m $resultsDir

    if ($Aggregate) {
        # Pool several runs' results into one provenance-guarded report. Purely a reader over existing
        # results.jsonl files -- runs nothing, so it needs no elevation, build, or workspace. Each
        # element may itself be a comma-separated list so 'pwsh -File ... -Aggregate a,b' also works.
        $dirs = @($Aggregate | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
        $report = Get-AggregateReport $dirs $m
        Show-AggregateReport $report -AllMetrics:$AllMetrics
        if ($Markdown) {
            $legendBase = Publish-Legend $here (Split-Path -Parent $Markdown)
            ConvertTo-MarkdownReport $report $dirs -AllMetrics:$AllMetrics -LegendBaseUrl $legendBase | Set-Content -LiteralPath $Markdown -Encoding utf8
            Write-Log "wrote markdown report to $Markdown"
        }
        if ($Json) {
            # The machine-readable contract: the full aggregated report (every comparison, every metric,
            # provenance, incidents) as JSON for tooling. Markdown is only the concise human view.
            ConvertTo-Json @($report) -Depth 10 | Set-Content -LiteralPath $Json -Encoding utf8
            Write-Log "wrote json report to $Json"
        }
        return
    }

    if ($ReportOnly) {
        # Regenerate the A/B table from whatever results.jsonl already holds. A hard external kill of
        # the host shell skips the finally block and the normal end-of-run report, so this is how the
        # user reads a partial round-robin run's numbers without re-running anything.
        Show-ReportTable (Get-Report $resultsDir $m)
        return
    }

    Initialize-Results $resultsDir
    Set-LogFile (Join-Path $resultsDir 'harness.log')
    New-Item -ItemType Directory -Force -Path $traceDir | Out-Null

    $selected = @($m.comparisons | Where-Object { -not $Only -or $_.name -in $Only })
    if ($selected.Count -eq 0) { throw 'no comparisons selected (check -Only against manifest names)' }

    Assert-Elevation $m.telemetry.collector (-not $NoStabilize)
    Invoke-Setup $m

    $script:ActiveVariantLabel = $null
    $script:HarnessSkipBuild   = [bool]$SkipBuild

    $artifacts = @{}
    if (-not $switchMode) {
        foreach ($variant in Get-SelectedVariants $m $selected) {
            $artifacts[$variant.label] = if ($SkipBuild) {
                Join-Path (Join-Path $worktreeRoot $variant.label) $m.build.artifact
            } else {
                Build-Variant $m $variant $worktreeRoot
            }
        }
    }

    $done = if ($Resume) { Read-Journal $resultsDir } else { New-Object System.Collections.Generic.HashSet[string] }
    if ($NoStabilize) { Write-Log 'frequency stabilization disabled (-NoStabilize)' 'WARN' } else { Set-FrequencyStable $resultsDir }

    $provenance = New-Provenance $m (Get-SelectedVariants $m $selected)

    try {
        Invoke-WarmupPhase $m $selected $artifacts $resultsDir $deadline

        # Round-robin: advance every comparison one repetition before any comparison takes its next, so
        # an interrupted run (manual abort or the time budget) leaves all comparisons measured a
        # comparable number of times rather than the first few complete and the rest untouched. Within
        # a rep a comparison's baseline and candidate still run back-to-back, which is what keeps each
        # A/B delta drift-free. Cooldown precedes every cell but the first, so the loop never ends on a
        # trailing idle wait.
        $firstCell = $true
        $stop = $false
        for ($rep = 1; $rep -le $m.run.reps -and -not $stop; $rep++) {
            foreach ($comparison in $selected) {
                $primary = Get-PrimaryMetric $m $comparison
                foreach ($arm in @($comparison.baseline, $comparison.candidate)) {
                    if ($deadline -and (Get-Date) -ge $deadline) {
                        Write-Log "time budget ($($m.run.budgetHours)h) reached -- stopping after $($rep - 1) full round(s)" 'WARN'
                        $stop = $true; break
                    }
                    if (-not $firstCell) { Wait-Cooldown $m }
                    $firstCell = $false
                    Invoke-MeasuredCell $m $comparison $arm $rep $artifacts $resultsDir $traceDir $primary $provenance $done
                }
                if ($stop) { break }
            }
        }
    }
    finally {
        if (-not $NoStabilize) { Restore-Frequency }
        if ($CleanWorktrees -and -not $switchMode) { Remove-Worktrees $m.repo $worktreeRoot }
    }

    Write-Log "run complete -> $resultsDir"
    Show-ReportTable (Get-Report $resultsDir $m)
}

Invoke-Harness
