<#
Outputs.ps1 -- multi-sink oracle for workloads that write into N git output repos instead of
mutating one workspace.

Some workloads (e.g. CSTool populate-data-source) read a workspace read-only and WRITE their result
into several committed git repos (the "sinks"). For these the correctness bar is idempotence: a sink
is correct when re-running the workload leaves it byte-identical to its committed gold, i.e. its
working tree stays clean against its own HEAD (which is the gold commit). That is a different oracle
from the single-workspace "whole tree equals a golden SHA" model, and it must stay cheap: a bug can
dirty thousands of files, so the harness never stages (`git add -A`), never diffs/patches the whole
tree, and never snapshots or branches the repo.

A manifest opts in with a top-level `outputs` array:

  "outputs": [
    { "path": "C:/data/repos/aida-dayforce-mining",      "goldRef": "b8b8588" },
    { "path": "C:/data/repos/aida-dayforce-mining-json", "goldRef": "97172dcd" },
    { "path": "C:/data/repos/aida-dayforce-mining-md",   "goldRef": "a3694f1f" }
  ],
  "run": { "maxDivergentFiles": 1, "watcherMaxDivergentFiles": 100, "divergePollSec": 10 }

maxDivergentFiles is the strict after-run ORACLE budget (default 1 => any single persistent divergent
file fails the sink). watcherMaxDivergentFiles is the SEPARATE during-run watcher threshold (default
100): an idempotent workload legitimately rewrites files in flight, so a few paths are transiently
dirty mid-run even when the final tree is byte-clean against gold -- the watcher must ignore that
churn and fire only on a genuine runaway (a bug diverging hundreds to thousands of files), while the
after-run oracle still fails the rep on a SINGLE persistent divergent file. Both are overridable per
output. divergePollSec (default 10) is the during-run watcher cadence.

A workload may additionally carry `seedDepth` (default 0), which selects the oracle:
  seedDepth 0  -- IDEMPOTENCE (above): the sink is reset to goldRef and must stay byte-clean against
                  it; the workload is expected to write nothing. Cheap, status-based, watched.
  seedDepth K  -- DRIFT: the sink is reset to goldRef~K (K commits of real prior output) and the
                  workload must regenerate goldRef exactly. The after-run gate compares the WHOLE tree
                  to goldRef -- content, additions, and deletions -- via a bounded `add -A;
                  diff --cached goldRef`. Drift is the only mode that exercises the WRITE path
                  (idempotence exercises only skips); the during-run watcher is disabled for drift
                  because the tree legitimately diverges from HEAD until the workload finishes.
K lives in the manifest as data; `git` resolves goldRef~K, so changing K never touches any script.
#>

function Test-HasOutputs($Manifest) {
    ($Manifest.PSObject.Properties.Name -contains 'outputs') -and $Manifest.outputs -and (@($Manifest.outputs).Count -gt 0)
}

function Get-OutputName($Output) {
    Split-Path -Leaf ([string]$Output.path)
}

function Get-SeedDepth($Workload) {
    # Depth of the drift seed: reset each sink to goldRef~seedDepth. 0 (default) => seed AT gold
    # (idempotence oracle); K > 0 => seed K commits back and require the workload to reproduce gold.
    if ($Workload -and ($Workload.PSObject.Properties.Name -contains 'seedDepth')) { [int]$Workload.seedDepth } else { 0 }
}

function Get-OutputBudget($Manifest, $Output) {
    # The strict after-run ORACLE budget: the count of divergent files at which a sink's final tree is
    # declared failed against gold. Default 1 => any single persistent divergent file fails the rep.
    # This is NOT the during-run watcher threshold (see Get-OutputWatchBudget): the watcher tolerates
    # an idempotent workload's in-flight write churn, but this final gate stays byte-strict. Per-output
    # override wins over the run default.
    if ($Output.PSObject.Properties.Name -contains 'maxDivergentFiles') { return [int]$Output.maxDivergentFiles }
    if ($Manifest.run.PSObject.Properties.Name -contains 'maxDivergentFiles') { return [int]$Manifest.run.maxDivergentFiles }
    1
}

function Get-OutputWatchBudget($Manifest, $Output) {
    # The during-run watcher's runaway-abort threshold: the count of in-flight divergent files at which
    # the watcher kills the workload mid-run. Deliberately DECOUPLED from the strict oracle budget
    # (Get-OutputBudget): an idempotent populate legitimately rewrites files in flight, so a handful of
    # paths are transiently dirty mid-run even when the final tree is byte-clean against gold. The
    # watcher must ignore that churn and fire only on a genuine runaway (a bug diverging hundreds to
    # thousands of files); correctness is still enforced by the after-run oracle at budget 1. Per-output
    # override wins over the run default, which defaults to 100.
    if ($Output.PSObject.Properties.Name -contains 'watcherMaxDivergentFiles') { return [int]$Output.watcherMaxDivergentFiles }
    if ($Manifest.run.PSObject.Properties.Name -contains 'watcherMaxDivergentFiles') { return [int]$Manifest.run.watcherMaxDivergentFiles }
    100
}

function Get-DivergePollSec($Manifest) {
    if ($Manifest.run.PSObject.Properties.Name -contains 'divergePollSec') { return [int]$Manifest.run.divergePollSec }
    10
}

function Reset-Outputs($Manifest, $Workload) {
    # Restore every sink to its seed before a rep. For idempotence (seedDepth 0) the seed IS goldRef;
    # for drift (seedDepth K) it is goldRef~K. Hard-reset to the seed then remove untracked and ignored
    # files, which also cleans up the half-written sink left by a mid-run kill.
    if (-not (Test-HasOutputs $Manifest)) { return }
    $depth = Get-SeedDepth $Workload
    foreach ($o in $Manifest.outputs) {
        $ref = if ($depth -gt 0) { "$($o.goldRef)~$depth" } else { "$($o.goldRef)" }
        $cmd = "git -C `"$($o.path)`" reset -q --hard $ref && git -C `"$($o.path)`" clean -qfdx"
        Invoke-Shell $cmd $null | Out-Null
    }
}

function Test-OutputOverBudget([string]$Path, [int]$Budget) {
    # True when the sink has at least $Budget divergent paths. `Select-Object -First` stops the git
    # pipeline early (broken-pipe), so git itself stops enumerating once the threshold is reached --
    # thousands of changed files are never listed. git status is content-based, so an identical rewrite
    # (same bytes) never shows, and it never hashes blobs the way `git add -A` would.
    $hit = @(& git -C $Path status --porcelain --untracked-files=all 2>$null | Select-Object -First $Budget)
    $hit.Count -ge $Budget
}

function Get-OutputsBreach($Manifest) {
    # First sink whose in-flight divergence has crossed the runaway watcher threshold, or $null. Used
    # only by the during-run watcher, so it reads Get-OutputWatchBudget (runaway-scale), NOT the strict
    # oracle budget -- an idempotent workload's transient write churn therefore never trips it.
    foreach ($o in $Manifest.outputs) {
        $budget = Get-OutputWatchBudget $Manifest $o
        if (Test-OutputOverBudget $o.path $budget) { return @{ path = $o.path; budget = $budget } }
    }
    $null
}

function Test-OutputsOracle($Manifest, $Workload) {
    # After-run gate: PASS only if every sink is within its budget. For drift (seedDepth K) each sink
    # is first repointed to goldRef with `reset --mixed` -- this moves index+HEAD to gold WITHOUT
    # touching the working tree (it loads gold's tree into the index; it does not scan or hash the
    # working files), so the SAME cheap, bounded `git status` budget check below now measures
    # divergence from GOLD instead of from the seed. For idempotence (seedDepth 0) HEAD already IS
    # goldRef, so the mixed reset is skipped and the check is unchanged. Records the breaching sinks so
    # the incident capture knows which repos to snapshot without recomputing.
    $depth = Get-SeedDepth $Workload
    $script:OutputsLastBreaches = @()
    foreach ($o in $Manifest.outputs) {
        if ($depth -gt 0) { Invoke-Shell "git -C `"$($o.path)`" reset -q --mixed $($o.goldRef)" $null | Out-Null }
        $budget = Get-OutputBudget $Manifest $o
        if (Test-OutputOverBudget $o.path $budget) { $script:OutputsLastBreaches += $o }
    }
    if ($script:OutputsLastBreaches.Count -gt 0) { 'FAIL' } else { 'PASS' }
}function Get-IncidentMaxFiles($Manifest) {
    if ($Manifest.run.PSObject.Properties.Name -contains 'incidentMaxFiles') { [int]$Manifest.run.incidentMaxFiles } else { 20 }
}

function Get-PorcelainPath([string]$Line) {
    # 'XY path' (3-char status prefix); a rename is 'old -> new', keep the destination.
    $p = $Line.Substring(3)
    if ($p -match ' -> ') { $p = ($p -split ' -> ')[-1] }
    $p.Trim('"')
}

function Save-OutputsIncident($Manifest, [string]$Cell, [string]$ResultsDir) {
    # Bounded, per-repo capture of a divergence. For each breaching sink we record the TRUE total
    # divergent-file count plus only the first K paths (K = run.incidentMaxFiles); each captured path
    # is captured in full -- its complete diff (tracked change) or complete file (untracked). The bound
    # is the file COUNT, not file size. No `git add -A`, no whole-tree patch, no capture branch, no
    # snapshot -- the next rep's Reset-Outputs discards the dirty tree. Seed-agnostic: under drift the
    # oracle has already repointed each sink's HEAD to goldRef, so `status`/`diff HEAD` here capture
    # divergence from gold exactly as they capture divergence from the idempotent gold.
    if ($Manifest.run.PSObject.Properties.Name -contains 'keepOracleIncidents' -and -not $Manifest.run.keepOracleIncidents) { return }
    $breaches = if ($script:OutputsLastBreaches) { $script:OutputsLastBreaches } else { $Manifest.outputs }
    $maxFiles = Get-IncidentMaxFiles $Manifest
    $safe     = ($Cell -replace '[^0-9A-Za-z._-]', '_')
    $root     = Join-Path (Join-Path $ResultsDir 'incidents') $safe

    foreach ($o in $breaches) {
        $all   = @(& git -C $o.path status --porcelain --untracked-files=all 2>$null)
        $total = $all.Count
        if ($total -eq 0) { continue }
        $out = Join-Path $root (Get-OutputName $o)
        New-Item -ItemType Directory -Force -Path $out | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $out 'diffs') | Out-Null

        $take = [Math]::Min($total, $maxFiles)
        $budget = Get-OutputBudget $Manifest $o
        $watchBudget = Get-OutputWatchBudget $Manifest $o
        @(
            "sink:                 $($o.path)"
            "goldRef:              $($o.goldRef)"
            "oracle budget:        $budget"
            "watcher budget:       $watchBudget"
            "divergent files:      $total   (true total)"
            "captured below:       $take"
        ) | Set-Content -LiteralPath (Join-Path $out 'summary.txt')
        $all | Select-Object -First $take | Set-Content -LiteralPath (Join-Path $out 'paths.txt')

        $i = 0
        foreach ($line in ($all | Select-Object -First $take)) {
            $i++
            $rel  = Get-PorcelainPath $line
            $dest = Join-Path (Join-Path $out 'diffs') ('{0:000}.txt' -f $i)
            $body = if ($line.StartsWith('??')) {
                $full = Join-Path $o.path $rel
                if (Test-Path -LiteralPath $full) { Get-Content -LiteralPath $full -Raw } else { '' }
            } else {
                (& git -C $o.path diff HEAD -- $rel 2>$null) -join "`n"
            }
            Set-Content -LiteralPath $dest -Value "# $line`n$body"
        }
        Write-Log "oracle incident: sink '$(Get-OutputName $o)' had $total divergent file(s); captured first $take -> $out" 'WARN'
    }
}

function Invoke-TimeCollectorWatched($Manifest, [string]$Exe, [string[]]$CommandArgs, [string]$LogPath) {
    # Wall-clock collector with a during-run divergence watcher. The workload runs as a child process
    # while the main thread polls the sinks every divergePollSec; if any sink crosses its threshold the
    # child is killed mid-run so a diverging rep never writes thousands of files. The measured wall is
    # the child's own ExitTime-StartTime, so the poll sleeps never inflate the timing.
    $errPath = "$LogPath.err"
    $proc = Start-Process -FilePath $Exe -ArgumentList $CommandArgs -NoNewWindow -PassThru `
        -RedirectStandardOutput $LogPath -RedirectStandardError $errPath
    $pollSec = Get-DivergePollSec $Manifest
    $aborted = $false
    while (-not $proc.HasExited) {
        Start-Sleep -Seconds $pollSec
        if ($proc.HasExited) { break }
        $breach = Get-OutputsBreach $Manifest
        if ($breach) {
            Write-Log "divergence watcher: sink '$($breach.path)' reached threshold $($breach.budget) -- killing workload mid-run" 'WARN'
            Get-Process -Id $proc.Id -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            $aborted = $true
            break
        }
    }
    if (-not $proc.HasExited) { $proc.WaitForExit() }
    $wallSec = try { ($proc.ExitTime - $proc.StartTime).TotalSeconds } catch { $null }
    $exit = if ($aborted) { 198 } else { $proc.ExitCode }
    @{ ExitCode = $exit; TracePath = $null; Aborted = $aborted; WallSec = $wallSec }
}
