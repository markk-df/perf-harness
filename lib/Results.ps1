<#
Results.ps1 -- persist every repetition, remember progress, and turn records into an A/B report.

Records are stored as JSON lines (one self-describing object per measured repetition) so any metric
the extractor produces is preserved without a fixed schema. A flat CSV mirror carries the core
columns for a quick glance. The journal lets an interrupted run resume without repeating work.
#>

function Format-MetricNumber($Value) {
    if ($null -eq $Value) { return '-' }
    $abs = [math]::Abs([double]$Value)
    if ($abs -ge 1e6) { ([double]$Value).ToString('0.00e0') }
    elseif ($abs -ge 1000) { ([double]$Value).ToString('N0') }
    elseif ($abs -eq [math]::Floor($abs)) { ([double]$Value).ToString('0') }
    else { [math]::Round([double]$Value, 2).ToString() }
}

function Test-DeltaWithheld([string]$Status) {
    # A delta is only trustworthy when the arms are comparable (no commit/setup conflict) AND every
    # pooled rep proved identical output (no oracle failure). Any of those poisons the improvement.
    ($Status -like 'CONFLICT*') -or ($Status -like 'INVALID*')
}

function Format-Transition($Base, $Cand) {
    # The concise "before -> after" cell for the human markdown view.
    '{0} {1} {2}' -f (Format-MetricNumber $Base), ([char]0x2192), (Format-MetricNumber $Cand)
}

function Format-DeltaArrow([string]$Status, $DeltaPct) {
    # Delta with a direction arrow for the human view: down = candidate did less, up = more.
    if (Test-DeltaWithheld $Status) { return 'withheld' }
    if ($null -eq $DeltaPct) { return '-' }
    $d = [double]$DeltaPct
    $arrow = if ($d -lt 0) { [char]0x2193 } elseif ($d -gt 0) { [char]0x2191 } else { '' }
    $sign  = if ($d -gt 0) { '+' } else { '' }
    ('{0} {1}{2}%' -f $arrow, $sign, $DeltaPct).Trim()
}

function Initialize-Results([string]$ResultsDir) {
    if (-not (Test-Path $ResultsDir)) { New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null }
    $csv = Join-Path $ResultsDir 'results.csv'
    if (-not (Test-Path $csv)) {
        'comparison,variant,workload,rep,wallSec,freqPct,wallSecNorm,exit,oracle,primaryMetric,primaryValue,traceKept,ts' |
            Set-Content -LiteralPath $csv
    }
}

function Read-Journal([string]$ResultsDir) {
    $done = New-Object System.Collections.Generic.HashSet[string]
    $path = Join-Path $ResultsDir 'progress.json'
    if (Test-Path $path) {
        (Get-Content $path -Raw | ConvertFrom-Json) | ForEach-Object { [void]$done.Add($_) }
    }
    $done
}

function Add-JournalEntry([string]$ResultsDir, $Done, [string]$Cell) {
    [void]$Done.Add($Cell)
    ($Done | Sort-Object) | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ResultsDir 'progress.json')
}

function Add-Result([string]$ResultsDir, [string]$Comparison, [int]$Rep, [string]$PrimaryMetric, [bool]$TraceKept, $Record) {
    $ts = Get-Date -Format 'yyyyMMddHHmmss'
    $primaryValue = if ($Record.metrics.Contains($PrimaryMetric)) { $Record.metrics[$PrimaryMetric] } else { $null }

    $line = [ordered]@{
        comparison   = $Comparison
        rep          = $Rep
        primaryMetric= $PrimaryMetric
        primaryValue = $primaryValue
        traceKept    = $TraceKept
        ts           = $ts
    }
    foreach ($k in $Record.Keys) { $line[$k] = $Record[$k] }
    ($line | ConvertTo-Json -Depth 6 -Compress) | Add-Content -LiteralPath (Join-Path $ResultsDir 'results.jsonl')

    $keptTrace = if ($TraceKept) { $Record.tracePath } else { '' }
    $row = @(
        $Comparison, $Record.variant, $Record.workload, $Rep, $Record.wallSec, $Record.freqPct,
        $Record.wallSecNorm, $Record.exit, $Record.oracle, $PrimaryMetric, $primaryValue, $TraceKept, $ts
    ) -join ','
    Add-Content -LiteralPath (Join-Path $ResultsDir 'results.csv') -Value $row
}

function Get-Report([string]$ResultsDir, $Manifest) {
    $path = Join-Path $ResultsDir 'results.jsonl'
    if (-not (Test-Path $path)) { return @() }
    $records = Get-Content $path | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }

    foreach ($comparison in $Manifest.comparisons) {
        $rows = $records | Where-Object { $_.comparison -eq $comparison.name }
        $baseline  = Measure-Arm ($rows | Where-Object { $_.variant -eq $comparison.baseline })
        $candidate = Measure-Arm ($rows | Where-Object { $_.variant -eq $comparison.candidate })

        [ordered]@{
            comparison     = $comparison.name
            workload       = $comparison.workload
            primaryMetric  = $rows | Select-Object -First 1 -ExpandProperty primaryMetric
            baseline       = $comparison.baseline
            candidate      = $comparison.candidate
            basePrimary    = $baseline.primary
            candPrimary    = $candidate.primary
            primaryDeltaPct= (Get-DeltaPercent $baseline.primary $candidate.primary)
            baseWallNorm   = $baseline.wallNorm
            candWallNorm   = $candidate.wallNorm
            wallDeltaPct   = (Get-DeltaPercent $baseline.wallNorm $candidate.wallNorm)
            oracle         = "$($baseline.oraclePass)/$($baseline.count) vs $($candidate.oraclePass)/$($candidate.count)"
        }
    }
}

function Measure-Arm($Rows) {
    $measured = @($Rows)
    [ordered]@{
        count      = $measured.Count
        primary    = Get-Median ($measured | ForEach-Object { [double]$_.primaryValue })
        wallNorm   = Get-Median ($measured | ForEach-Object { [double]$_.wallSecNorm })
        oraclePass = @($measured | Where-Object { $_.oracle -eq 'PASS' -or $_.oracle -eq 'SKIP' }).Count
    }
}

function Get-Median($Values) {
    $sorted = @($Values | Where-Object { $_ -ne $null } | Sort-Object)
    if ($sorted.Count -eq 0) { return $null }
    $mid = [int][math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2) { $sorted[$mid] } else { [math]::Round(($sorted[$mid - 1] + $sorted[$mid]) / 2, 2) }
}

function Get-DeltaPercent($Baseline, $Candidate) {
    if (-not $Baseline -or $Baseline -eq 0 -or $null -eq $Candidate) { return $null }
    $d = [math]::Round((($Candidate - $Baseline) / $Baseline) * 100, 1)
    if ($d -eq 0) { 0 } else { $d }
}

function Get-RowField($Row, [string]$Name) {
    $property = $Row.PSObject.Properties[$Name]
    if ($property) { $property.Value } else { $null }
}

function Get-MetricValue($Row, [string]$Metric) {
    $metrics = Get-RowField $Row 'metrics'
    if (-not $metrics) { return $null }
    $property = $metrics.PSObject.Properties[$Metric]
    if ($property -and $null -ne $property.Value) { [double]$property.Value } else { $null }
}

function Get-ResultRows([string[]]$Dirs) {
    $rows = foreach ($dir in $Dirs) {
        $path = Join-Path $dir 'results.jsonl'
        if (-not (Test-Path $path)) { Write-Log "aggregate: no results.jsonl in $dir (skipped)" 'WARN'; continue }
        Get-Content $path | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }
    }
    @($rows | Where-Object { $null -ne $_ })
}

function Measure-ArmMetric($Rows, [string]$Metric) {
    # Pool one metric across every rep of one arm, from however many runs. A rep contributes only if it
    # actually recorded this metric (missing / null is skipped, never counted as zero), so n reflects
    # the real number of comparable measurements and can legitimately differ metric to metric.
    $contributing = @($Rows | Where-Object { $null -ne (Get-MetricValue $_ $Metric) })
    $values = @($contributing | ForEach-Object { Get-MetricValue $_ $Metric })
    if ($values.Count -eq 0) { return [ordered]@{ n = 0; median = $null; min = $null; max = $null; mixedRegime = $false } }
    $regimes = @($contributing | ForEach-Object { Get-RowField $_ 'telemetryHash' } | Where-Object { $_ } | Sort-Object -Unique)
    [ordered]@{
        n           = $values.Count
        median      = Get-Median $values
        min         = ($values | Measure-Object -Minimum).Minimum
        max         = ($values | Measure-Object -Maximum).Maximum
        mixedRegime = $regimes.Count -gt 1
    }
}

function Get-SpreadPercent($Aggregate) {
    if (-not $Aggregate.median -or $Aggregate.median -eq 0) { return 0 }
    $s = [math]::Round((($Aggregate.max - $Aggregate.min) / $Aggregate.median) * 100, 1)
    if ($s -eq 0) { 0 } else { $s }
}

function Get-ArmCommits($Rows) {
    @($Rows | ForEach-Object { Get-RowField $_ 'variantCommit' } | Where-Object { $_ } | Sort-Object -Unique)
}

function Format-ShortCommit($Commits) {
    $list = @($Commits)
    if ($list.Count -eq 0) { '-' }
    elseif ($list.Count -eq 1) { $list[0].Substring(0, [Math]::Min(7, $list[0].Length)) }
    else { 'CONFLICT' }
}

function Measure-OraclePass($Rows) {
    @($Rows | Where-Object { (Get-RowField $_ 'oracle') -in 'PASS', 'SKIP' }).Count
}

function Get-OracleIncidents($Rows) {
    # Every repetition whose output did NOT match the oracle. A byte-divergence means the candidate is
    # not proven to do identical work, so it invalidates the whole comparison's improvement. Each
    # incident is reported with enough provenance to find and re-examine the offending run.
    @($Rows | Where-Object { (Get-RowField $_ 'oracle') -eq 'FAIL' } | ForEach-Object {
        [ordered]@{
            variant = Get-RowField $_ 'variant'
            rep     = Get-RowField $_ 'rep'
            runId   = Get-RowField $_ 'runId'
            commit  = Format-ShortCommit @(Get-RowField $_ 'variantCommit')
            ts      = Get-RowField $_ 'ts'
            exit    = Get-RowField $_ 'exit'
        }
    })
}

function Get-AggregateReport([string[]]$Dirs, $Manifest) {
    # Pool the results of several runs (e.g. a week of nightly runs) into one A/B report. Cells are
    # grouped by (comparison, variant) across all runs and aggregated per metric. Two provenance guards
    # keep the pooling honest: every rep of a given arm must have been built from the SAME commit, and
    # every rep of the comparison must share the SAME setup fingerprint (workloads/build). A conflict
    # is reported and the delta withheld rather than silently averaging incomparable measurements.
    $rows = @(Get-ResultRows $Dirs)
    if ($rows.Count -eq 0) { return @() }

    foreach ($comparison in $Manifest.comparisons) {
        $primary   = if ($comparison.PSObject.Properties.Name -contains 'primaryMetric') { $comparison.primaryMetric } else { $Manifest.telemetry.primaryMetric }
        $baseRows  = @($rows | Where-Object { $_.comparison -eq $comparison.name -and $_.variant -eq $comparison.baseline })
        $candRows  = @($rows | Where-Object { $_.comparison -eq $comparison.name -and $_.variant -eq $comparison.candidate })
        if ($baseRows.Count -eq 0 -and $candRows.Count -eq 0) { continue }

        $baseCommits = @(Get-ArmCommits $baseRows)
        $candCommits = @(Get-ArmCommits $candRows)
        $setupHashes = @(($baseRows + $candRows) | ForEach-Object { Get-RowField $_ 'setupHash' } | Where-Object { $_ } | Sort-Object -Unique)
        $missing     = @(($baseRows + $candRows) | Where-Object { -not (Get-RowField $_ 'variantCommit') }).Count
        $incidents   = @(Get-OracleIncidents ($baseRows + $candRows))

        # An oracle failure is a correctness violation, so it outranks every provenance concern: the
        # improvement is invalidated outright rather than merely flagged as pooled-on-trust.
        $status = if ($incidents.Count -gt 0) { 'INVALID:oracle' }
                  elseif ($baseCommits.Count -gt 1 -or $candCommits.Count -gt 1) { 'CONFLICT:code' }
                  elseif ($setupHashes.Count -gt 1) { 'CONFLICT:setup' }
                  elseif ($missing -gt 0) { 'unverified' }
                  else { 'verified' }

        $metricNames = @($rows | ForEach-Object { $m = Get-RowField $_ 'metrics'; if ($m) { $m.PSObject.Properties.Name } } | Sort-Object -Unique)
        $perMetric = foreach ($metric in $metricNames) {
            $b = Measure-ArmMetric $baseRows $metric
            $c = Measure-ArmMetric $candRows $metric
            [ordered]@{
                metric        = $metric
                baseN         = $b.n; candN = $c.n
                baseMedian    = $b.median; candMedian = $c.median
                deltaPct      = Get-DeltaPercent $b.median $c.median
                baseSpreadPct = Get-SpreadPercent $b
                candSpreadPct = Get-SpreadPercent $c
                mixedRegime   = $b.mixedRegime -or $c.mixedRegime
            }
        }

        $head = @($perMetric | Where-Object { $_.metric -eq $primary }) | Select-Object -First 1
        $wall = @($perMetric | Where-Object { $_.metric -eq 'wallSecNorm' }) | Select-Object -First 1
        [ordered]@{
            comparison    = $comparison.name
            workload      = $comparison.workload
            primaryMetric = $primary
            status        = $status
            baseCommit    = Format-ShortCommit $baseCommits
            candCommit    = Format-ShortCommit $candCommits
            baseN         = if ($head) { $head.baseN } else { 0 }
            candN         = if ($head) { $head.candN } else { 0 }
            baseMedian    = if ($head) { $head.baseMedian } else { $null }
            candMedian    = if ($head) { $head.candMedian } else { $null }
            deltaPct      = if ((Test-DeltaWithheld $status) -or -not $head) { $null } else { $head.deltaPct }
            wallBase      = if ($wall) { $wall.baseMedian } else { $null }
            wallCand      = if ($wall) { $wall.candMedian } else { $null }
            wallDeltaPct  = if ((Test-DeltaWithheld $status) -or -not $wall) { $null } else { $wall.deltaPct }
            spread        = if ($head) { "+/-$($head.baseSpreadPct)% / +/-$($head.candSpreadPct)%" } else { '' }
            regimes       = if ($head -and $head.mixedRegime) { 'mixed' } else { 'single' }
            oracle        = "$(Measure-OraclePass $baseRows)/$($baseRows.Count) vs $(Measure-OraclePass $candRows)/$($candRows.Count)"
            incidents     = $incidents
            detail        = $perMetric
        }
    }
}

function Publish-Legend([string]$HarnessDir, [string]$OutDir) {
    # Copy the metrics legend next to the generated report so the results server serves it alongside,
    # and return the relative URL the report links to. Returns $null when the source legend isn't found
    # (the report then falls back to plain code-formatted metric names). The server (Serve-Results.ps1)
    # renders markdown with marked.js, which preserves the <a id="metric-*"> anchors that GitHub's
    # markdown sanitizer strips -- so these in-page fragment links resolve there but would not on GitHub.
    $src = Join-Path $HarnessDir 'docs/metrics-reference.md'
    if (-not (Test-Path -LiteralPath $src)) { return $null }
    $name = 'metrics-reference.md'
    Copy-Item -LiteralPath $src -Destination (Join-Path $OutDir $name) -Force
    $name
}

function Format-MetricRef([string]$Metric, [string]$LegendBaseUrl) {
    # A metric name as a link to its legend entry (anchor id "metric-<root>"), or code-formatted
    # when no legend base is available. For a nested metric (e.g. PmcEstimatedTotals.InstructionRetired)
    # the anchor is the root token, where the legend documents the whole family.
    if ([string]::IsNullOrEmpty($LegendBaseUrl)) { return "``$Metric``" }
    $root = $Metric.Split('.')[0]
    "[$Metric]($LegendBaseUrl#metric-$root)"
}

function ConvertTo-MarkdownReport($Report, [string[]]$Dirs, [switch]$AllMetrics, [string]$LegendBaseUrl) {
    # Render the pooled A/B report as a self-contained GitHub-flavoured markdown document: a headline
    # table (one primary metric per comparison) plus, with -AllMetrics, a per-comparison breakdown of
    # every metric. Purely a formatter over the objects Get-AggregateReport returns.
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Performance A/B report')
    $lines.Add('')
    $lines.Add("_Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm')._")
    if ($Dirs) {
        $lines.Add('')
        $lines.Add("Pooled from $($Dirs.Count) results director$(if ($Dirs.Count -eq 1) { 'y' } else { 'ies' }):")
        foreach ($dir in $Dirs) { $lines.Add("- ``$dir``") }
    }
    if (-not $Report) { $lines.Add(''); $lines.Add('_No results to report._'); return ($lines -join "`r`n") }

    $incidents = foreach ($c in $Report) {
        foreach ($i in @($c.incidents)) {
            [pscustomobject]@{ comparison = $c.comparison; variant = $i.variant; rep = $i.rep; runId = $i.runId; commit = $i.commit; ts = $i.ts; exit = $i.exit }
        }
    }
    if ($incidents) {
        $lines.Add('')
        $lines.Add('## Oracle incidents — improvements invalidated')
        $lines.Add('')
        $lines.Add('One or more repetitions produced output that did **not** match the oracle. A byte-divergence means the candidate is not proven to do identical work, so every affected comparison is marked `INVALID:oracle` and its delta is withheld — the speed claim cannot be trusted until the divergence is explained. This is recorded here rather than silently dropped because a failed oracle casts a shadow on the improvement''s correctness.')
        $lines.Add('')
        $lines.Add('When the workspace is a git repo and `run.keepOracleIncidents` is not disabled, each failing rep''s divergence is preserved under `results/incidents/<comparison|variant|workload|rep>/`: `stat.txt` and `numstat.txt` (which files changed and by how much), a readable `incident.diff`, and a reconstructable `incident.patch` (apply it onto the oracle reference commit with `git apply` to recreate the diverged tree offline). Start there to tell a harness bug from a real output change: if the **base** variant (the oracle''s own code) diverges, the tool is non-deterministic, not the candidate.')
        $lines.Add('')
        $lines.Add('| Comparison | Variant | Rep | Run | Commit | Timestamp | Exit |')
        $lines.Add('|---|---|---:|---|---|---|---:|')
        foreach ($i in $incidents) {
            $lines.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f $i.comparison, $i.variant, $i.rep, $i.runId, $i.commit, $i.ts, $i.exit))
        }
    }

    $lines.Add('')
    $lines.Add('## Headline')
    $lines.Add('')
    $lines.Add('One row per comparison, using that comparison''s primary invariant metric. The metric column reads _baseline value_ → _candidate value_; Δ is the candidate-over-baseline change (↓ = candidate did less). **Wall** is the end-to-end process wall time in seconds, frequency-normalized (`wallSecNorm`) — the bottom line, though noisier than the invariant metric. `n` is the pooled repetition count per arm.')
    $lines.Add('')
    $lines.Add('| Comparison | Workload | Metric | Base → Cand | Δ | Wall s (base → cand) | Wall Δ | n | Spread (base / cand) | Status | Oracle |')
    $lines.Add('|---|---|---|---|---:|---|---:|---:|---|---|---|')
    foreach ($c in $Report) {
        $n = if ($c.baseN -eq $c.candN) { "$($c.baseN)" } else { "$($c.baseN)/$($c.candN)" }
        $lines.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} | {10} |' -f `
            $c.comparison, $c.workload, (Format-MetricRef $c.primaryMetric $LegendBaseUrl), `
            (Format-Transition $c.baseMedian $c.candMedian), (Format-DeltaArrow $c.status $c.deltaPct), `
            (Format-Transition $c.wallBase $c.wallCand), (Format-DeltaArrow $c.status $c.wallDeltaPct), `
            $n, $c.spread, $c.status, $c.oracle))
    }

    $lines.Add('')
    $lines.Add('**Status** — `verified`: every pooled rep of each arm shares one commit and setup. ' +
               '`unverified`: some reps predate provenance stamping (pooled on trust). ' +
               '`CONFLICT:code` / `CONFLICT:setup`: arms mix commits or setups, so the delta is withheld. ' +
               '`INVALID:oracle`: at least one rep failed the oracle (output diverged), so the whole improvement is invalidated and the delta withheld — see the Oracle incidents section. ' +
               '**Oracle** shows passing reps per arm (`base vs cand`). Commits, per-metric detail, and telemetry regime live in the JSON report and the `-AllMetrics` breakdown below.')

    if ($AllMetrics) {
        $lines.Add('')
        $lines.Add('## Every metric')
        foreach ($c in $Report) {
            $lines.Add('')
            $lines.Add("### $($c.comparison) ($($c.workload)) — $($c.baseCommit) vs $($c.candCommit)")
            $lines.Add('')
            $lines.Add('| Metric | Base → Cand | Δ | n | Spread (base / cand) | Regime |')
            $lines.Add('|---|---|---:|---:|---|---|')
            foreach ($d in $c.detail) {
                $n = if ($d.baseN -eq $d.candN) { "$($d.baseN)" } else { "$($d.baseN)/$($d.candN)" }
                $lines.Add(('| {0} | {1} | {2} | {3} | +/-{4}% / +/-{5}% | {6} |' -f `
                    (Format-MetricRef $d.metric $LegendBaseUrl), (Format-Transition $d.baseMedian $d.candMedian), (Format-DeltaArrow $c.status $d.deltaPct), `
                    $n, $d.baseSpreadPct, $d.candSpreadPct, `
                    $(if ($d.mixedRegime) { 'mixed' } else { 'single' })))
            }
        }
    }

    ($lines -join "`r`n") + "`r`n"
}
