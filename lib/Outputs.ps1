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
  "run": { "maxDivergentFiles": 1, "divergePollSec": 10 }

maxDivergentFiles is the per-repo abort threshold (default 1 => any single divergent file fails the
sink); it is overridable per output. divergePollSec (default 10) is the during-run watcher cadence.
#>

function Test-HasOutputs($Manifest) {
    ($Manifest.PSObject.Properties.Name -contains 'outputs') -and $Manifest.outputs -and (@($Manifest.outputs).Count -gt 0)
}

function Get-OutputName($Output) {
    Split-Path -Leaf ([string]$Output.path)
}

function Get-OutputBudget($Manifest, $Output) {
    # The per-repo abort threshold: the count of divergent files at which the sink is declared failed
    # (and the during-run watcher kills the workload). Per-output override wins over the run default,
    # which defaults to 1.
    if ($Output.PSObject.Properties.Name -contains 'maxDivergentFiles') { return [int]$Output.maxDivergentFiles }
    if ($Manifest.run.PSObject.Properties.Name -contains 'maxDivergentFiles') { return [int]$Manifest.run.maxDivergentFiles }
    1
}

function Get-DivergePollSec($Manifest) {
    if ($Manifest.run.PSObject.Properties.Name -contains 'divergePollSec') { return [int]$Manifest.run.divergePollSec }
    10
}

function Reset-Outputs($Manifest) {
    # Restore every sink to its gold commit before a rep: hard-reset to goldRef then remove untracked
    # and ignored files, which also cleans up the half-written sink left by a mid-run kill.
    if (-not (Test-HasOutputs $Manifest)) { return }
    foreach ($o in $Manifest.outputs) {
        $cmd = "git -C `"$($o.path)`" reset -q --hard $($o.goldRef) && git -C `"$($o.path)`" clean -qfdx"
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
    # First sink that has crossed its abort threshold, or $null. Used by the during-run watcher.
    foreach ($o in $Manifest.outputs) {
        $budget = Get-OutputBudget $Manifest $o
        if (Test-OutputOverBudget $o.path $budget) { return @{ path = $o.path; budget = $budget } }
    }
    $null
}

function Test-OutputsOracle($Manifest) {
    # After-run gate: PASS only if every sink is within its budget. Records the breaching sinks so the
    # incident capture knows which repos to snapshot without recomputing.
    $script:OutputsLastBreaches = @()
    foreach ($o in $Manifest.outputs) {
        $budget = Get-OutputBudget $Manifest $o
        if (Test-OutputOverBudget $o.path $budget) { $script:OutputsLastBreaches += $o }
    }
    if ($script:OutputsLastBreaches.Count -gt 0) { 'FAIL' } else { 'PASS' }
}

function Get-IncidentMaxFiles($Manifest) {
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
    # snapshot -- the next rep's Reset-Outputs discards the dirty tree.
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
        @(
            "sink:                 $($o.path)"
            "goldRef:              $($o.goldRef)"
            "abort threshold:      $budget"
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
